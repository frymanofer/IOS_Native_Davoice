import DavoiceLLM
import Foundation
import os

// The agent side of the car app (port of the other apps' local LLM service): downloads and loads the DaVoice Automotive Agent ahead of
// time, configures the shared native agent core for it (the same settings as the other apps), and runs turns. History is the chat in
// the agent's shape: role user / model, text, and a model reply's toolMessages.

/// e.g. "Saturday, October 17, 2026". Changes once a day, so the system prompt (and the engine's cache of it) stays the same.
func currentDateText(_ now: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEEE, MMMM d, yyyy"
    return f.string(from: now)
}

/// One async lock (the model loads once; the agent is made once per language).
actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    nonisolated func with<T>(_ f: () async throws -> T) async rethrows -> T {
        await lock()
        do {
            let v = try await f()
            await unlock()
            return v
        } catch {
            await unlock()
            throw error
        }
    }
}

final class CarLlm {
    private let licenseKey: String
    private let engine = LocalLLMEngine()
    private let layer2 = LocalLLMEngine()
    let store = ModelStore()
    private let agentLock = AsyncLock()
    private var agent: AgentClient?
    private var agentLanguage: String?
    private var configuredFor: AgentClient?
    private var confidenceKey: String?
    private var steeringSent: String?
    var confidence = ConfidenceSettings.defaults
    private var nativeLoads = 0
    private var stateRestoredFor: String?

    // The engine holds one model; racing callers join one load.
    private let loadLock = AsyncLock()
    private(set) var isModelReady = false

    private let log = Logger(subsystem: "io.davoice.caragent", category: "LocalLLM")
    private let agentLog = Logger(subsystem: "io.davoice.caragent", category: "DavoiceAgent")
    private static let embeddingModelURL = "https://pub-27f94b1602c647ab95a601086cf52820.r2.dev/agent-llm/router/all-MiniLM-L6-v2-Q8_0.gguf"

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(licenseKey: String) { self.licenseKey = licenseKey }

    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// The app's one agent, for the current language (a new agent after a language change).
    private func currentAgent() async throws -> AgentClient {
        try await agentLock.with {
            let lang = AppLanguage.current
            if let a = agent, agentLanguage == lang { return a }
            agent?.close()
            let db = "\(lang == "en" ? "davoice_agent" : "davoice_agent_\(lang.replacingOccurrences(of: "-", with: "_").lowercased())")_car"
            let created = try AgentClient.create(
                engine: engine, layer2: layer2,
                config: [
                    "pack": ["agent": .obj(AgentPack.withReplyLanguage(AgentPack.of(lang), lang)), "skills": []],
                    "databasePath": JSON(docs.appendingPathComponent("\(db).db").path),
                    // The whole chat (user, model outputs, tools, replies), readable off the phone (Files app / Xcode container).
                    "chatLogPath": JSON(docs.appendingPathComponent("davoice_chat.log").path),
                    "webSearch": ["engine": "wikipedia", "wikipediaLanguage": JSON(lang.lowercased().hasPrefix("pt") ? "pt" : "en")],
                ],
                onEvent: { [agentLog] e in
                    if e.type == "log" { agentLog.info("\(str(e.json["level"]), privacy: .public): \(str(e.json["message"]), privacy: .public)") }
                },
                onRequest: { [weak self] request in try self?.answerRequest(request) ?? .null })
            let carNames = CarTools.names
            try await created.setTools(CarTools.tools(wording: CarModel.toolWording)) { !carNames.contains($0.name) }
            agent = created
            agentLanguage = lang
            configuredFor = nil
            setUpRouterEmbeddings(created)
            return created
        }
    }

    /// The agent's requests to the app: the remote assistant (none in this demo) and owner-only tools.
    private func answerRequest(_ request: JObj) throws -> JSON {
        let language = AppLanguage.current
        switch str(request["type"]) {
        case "remote":
            // The model said it can't do this: not available in this demo, unless it is a fragment of speech the model declined
            if request["reason"] == "cannot" {
                if isTooShortForDecline(str(request["userText"] ?? request["query"] ?? "")) {
                    return ["text": JSON(didNotCatchTexts[language] ?? BasicLanguage.message(language, "didNotCatch") ?? didNotCatchTexts["en"]!)]
                }
                return ["text": JSON(notInDemoTexts[language] ?? BasicLanguage.message(language, "notInDemo") ?? notInDemoTexts["en"]!)]
            }
            // Local confidence held a car action back and no remote model is set up
            if request["reason"] == "low-confidence" {
                return ["text": JSON(lowConfidenceTexts[language] ?? BasicLanguage.message(language, "lowNoRemote") ?? lowConfidenceTexts["en"]!)]
            }
            // No remote assistant in this demo: say so instead of answering
            return ["text": JSON(generalQuestionsMessage[language] ?? BasicLanguage.message(language, "noRemote") ?? generalQuestionsMessage["en"] ?? noRemoteTexts["en"]!)]
        case "authorizeTool":
            // Doors (unlock_car, open_door): only the enrolled owner's voice, when speaker verification is on.
            var ok = false
            if request["scope"] == "door_locks" {
                let (allowed, why) = CurrentSpeaker.ownerMayAct()
                agentLog.info("authorize \(str(request["name"]), privacy: .public) (door_locks): \(allowed ? "yes" : "no", privacy: .public) - \(why, privacy: .public)")
                ok = allowed
            }
            return ["authorized": JSON(ok)]
        default:
            throw Failure(message: "The app does not answer \"\(str(request["type"]))\" requests.")
        }
    }

    /// The router's sentence-embedding model (25 MB), downloaded once in the background; until then the router compares words.
    private func setUpRouterEmbeddings(_ a: AgentClient) {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("models/all-MiniLM-L6-v2-Q8_0.gguf")
        Task.detached { [agentLog] in
            do {
                if !FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let (tmp, response) = try await URLSession.shared.download(from: URL(string: Self.embeddingModelURL)!)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "HTTP error") }
                    try FileManager.default.moveItem(at: tmp, to: file)
                }
                try await a.configure(["router": ["embeddingModel": JSON(file.path)]])
                agentLog.info("router embedding model set")
            } catch {
                agentLog.info("router embedding model not available (word overlap is used): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The core's call guards ('correct' fixes / blocks; the split-tool opposite check can only block: 'enforce').
    private func callGuards(_ mode: String, basic: Bool = false) -> JObj {
        var m: JObj = [
            "polarity": JSON(mode), "direction": JSON(mode), "absRel": JSON(mode), "zone": JSON(mode), "capability": JSON(mode),
            "numberGround": JSON(mode), "opposite": JSON(mode == "correct" ? "enforce" : mode),
            "followUp": JSON(CarModel.historyAsRun ? mode : "off"), "dualZone": JSON(mode), "enumWords": JSON(mode),
        ]
        if basic {
            m["capability"] = "off"
            m["polarity"] = "off"
        }
        return m
    }

    /// The agent, set up for the model (chat template, remote, router, guards, scope, undo, confidence, safety, vehicle).
    private func agentForModel() async throws -> AgentClient {
        let a = try await currentAgent()
        if configuredFor !== a {
            configuredFor = a
            confidenceKey = nil
            steeringSent = nil
            try await a.configure([
                "chatTemplate": .obj(CarModel.chatTemplate),
                // the remote assistant: the "no remote model" message (answerRequest)
                "remote": ["enabled": true, "timeoutMs": 15000],
                // false: the model decides every turn with every tool (no router, no skill rules)
                "intentRouter": false,
                "webSearchTool": true,
                "timeTool": true,
                "memory": ["profile": "small", "relevantMax": 0],
                "sampling": ["temperature": 0],
                "guards": .obj(callGuards(CarModel.callGuards)),
                "historyAsRun": JSON(CarModel.historyAsRun),
                "guidedToolCalls": JSON(CarModel.guidedToolCalls),
                "promptOrder": JSON(CarModel.promptOrder),
                "guardRetry": JSON(CarModel.guardRetry),
                "maxOperations": JSON(CarModel.maxOperations),
                "historyTurns": JSON(CarModel.historyTurns),
                "compactToolResults": JSON(CarModel.compactToolResults),
                "scope": .obj(CarModel.scope),
                "undo": JSON(CarModel.undo),
            ])
        }
        // the car's results carry their undo only when the agent uses it
        CarTools.undoResults = CarModel.undo
        let language = AppLanguage.current
        let key = "\(Json.stringify(confidence.json))|\(language)"
        if confidenceKey != key {
            confidenceKey = key
            let pt = language.lowercased().hasPrefix("pt")
            let basic = BasicLanguage.isBasic(language)
            try await a.configure([
                "confidence": .obj(toCoreConfidence(confidence, language)),
                "safety": [
                    "neverAct": true,
                    "seatAsk": true,
                    "messages": [
                        "whichSeat": JSON(BasicLanguage.message(language, "whichSeat") ?? (pt ? "Qual banco: o seu, o do carona ou os dois?" : "Which seat: yours, the passenger's, or both?")),
                        "unsupported": JSON(notInDemoTexts[language] ?? BasicLanguage.message(language, "notInDemo") ?? notInDemoTexts["en"]!),
                    ],
                ],
                // Basic language: the command scope and the checks that look for English / Portuguese words would drop or block nearly
                // every request, so they are off; every car action is asked first and runs only after a yes instead.
                "scope": basic ? ["enabled": false] : .obj(CarModel.scope),
                "guards": .obj(callGuards(CarModel.callGuards, basic: basic)),
            ])
        }
        // The car's steering-wheel side: "o banco da direita" is the passenger in a left-hand-drive car.
        let steering = await MainActor.run { Car.state.steering }
        if steeringSent != steering {
            steeringSent = steering
            try await a.configure(["vehicle": ["steering": JSON(steering)]])
        }
        return a
    }

    /// Downloads (if needed) and loads the model, then restores or processes the system prompt, so the first turn pays for none of it.
    /// Call when the conversation opens and after a language change, never mid-turn.
    func warmUp(_ history: [JObj], onDownloadProgress: @escaping (Double) -> Void, onWarming: @escaping () -> Void) async throws {
        let language = AppLanguage.current
        let prebuilt = CarModel.prebuiltStates[language]
        let modelBytes = Double(CarModel.sizeBytes)
        let stateBytes = Double(prebuilt?.sizeBytes ?? 0)
        let progress = Progress2()
        func report() { onDownloadProgress((progress.model * modelBytes + progress.state * stateBytes) / (modelBytes + stateBytes)) }
        async let prebuiltDownload = store.downloadPrebuiltState(language) { progress.state = $0; report() }
        try await ensureLoaded { progress.model = $0; report() }
        let prebuiltPath = await prebuiltDownload
        onWarming()
        do {
            let a = try await agentForModel()
            let date = currentDateText()
            let prompt = str(try await a.call("prompt", ["text": "Hello", "history": JSON(history), "date": JSON(date)]))
            let statePath = store.kvStatePath("\(language)-\(stablePromptKey(prompt, date))")
            let stateExists = FileManager.default.fileExists(atPath: statePath)
            let restorePath = stateExists ? statePath : prebuiltPath
            var restoredPrebuilt = false
            let load = "\(CarModel.id)#\(nativeLoads)"
            if stateRestoredFor != load, let restorePath {
                let t0 = Date()
                do {
                    let n = try engine.loadState(path: restorePath)
                    restoredPrebuilt = !stateExists
                    log.info("KV state restored\(restoredPrebuilt ? " (pre-warmed)" : ""): \(n) tokens in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                } catch {
                    log.warning("KV state not usable, deleted: \(error.localizedDescription, privacy: .public)")
                    try? FileManager.default.removeItem(atPath: restorePath)
                }
            }
            stateRestoredFor = load
            // Answer once, briefly, on the agent's real prompt: the system prompt is in the cache and the first decode has run.
            let started = Date()
            let tokens = try await generateBriefly(prompt)
            let warmMs = Int(Date().timeIntervalSince(started) * 1000)
            log.info("warm-up answered (\(tokens) tokens) in \(warmMs) ms")
            if (!stateExists && !(restoredPrebuilt && warmMs <= 5000)) || warmMs > 5000 {
                let t0 = Date()
                let n = try engine.saveState(path: statePath)
                log.info("KV state saved: \(n) tokens in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                store.deleteOldStates()
            }
        } catch {
            // Only a speed-up: a failure here must not block the chat.
            log.warning("warm-up state step skipped: \(error.localizedDescription, privacy: .public)")
            await prefill(history, "")
        }
    }

    private final class Progress2 {
        var model = 0.0
        var state = 0.0
    }

    private func generateBriefly(_ prompt: String) async throws -> Int {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
            var tokens = 0
            var finished = false
            let lock = NSLock()
            engine.generateStream(prompt: prompt, onToken: { [engine] _, done in
                lock.lock()
                defer { lock.unlock() }
                if finished { return }
                if done {
                    finished = true
                    c.resume(returning: tokens)
                } else {
                    tokens += 1
                    if tokens == 4 { engine.cancel() }
                }
            }, onError: { error in
                lock.lock()
                defer { lock.unlock() }
                if finished { return }
                finished = true
                c.resume(throwing: error)
            })
        }
    }

    private func ensureLoaded(_ onDownloadProgress: @escaping (Double) -> Void) async throws {
        try await loadLock.with {
            if isModelReady { return }
            if !store.isDownloaded() { try await store.download(onDownloadProgress) }
            guard engine.setLicense(licenseKey: licenseKey) else { throw Failure(message: "The license was rejected for \(CarModel.displayName)") }
            let options = LocalLLMLoadOptions()
            options.contextSize = NSNumber(value: CarModel.contextSize)
            // always explicit (the React Native bridge's default): mmap keeps the 382 MB model out of the app's dirty memory
            options.useMmap = true
            try await Task.detached { [engine, store] in try engine.loadModel(path: store.modelFile.path, options: options) }.value
            nativeLoads += 1
            isModelReady = true
        }
    }

    /// Processes the conversation plus the user's words so far into the model's cache. No-op until the model is loaded.
    func prefill(_ history: [JObj], _ partialUserText: String) async {
        if !isModelReady { return }
        if let a = try? await agentForModel() { a.prefill(history, partialUserText) }
    }

    /// One turn. Reply text streams to onDelta; onEvent gets everything else (filler, status, ...). On the agent's event queue.
    func turn(_ history: [JObj], _ userText: String, onDelta: @escaping (String) -> Void, onEvent: @escaping (AgentEvent) -> Void) async throws -> TurnResult {
        try await ensureLoaded { _ in }
        let a = try await agentForModel()
        // The next request starts with nobody heard (door authorization).
        defer { CurrentSpeaker.clearHeard() }
        return try await a.turn(["text": JSON(userText), "history": JSON(history), "date": JSON(currentDateText())]) { e in
            if e.type == "text" { onDelta(e.text) } else { onEvent(e) }
        }
    }

    /// A new agent for the language (call after a language change).
    func languageChanged() async {
        await agentLock.with {
            agent?.close()
            agent = nil
            agentLanguage = nil
        }
    }

    func cancel() async { await agent?.cancel() }
}
