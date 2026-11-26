import AVFoundation
import Foundation
import os
import Speech

// The whole app flow (the Swift counterpart of the React Native / Flutter / Android example_car_agent's App / main / CarAgentApp):
// language -> voice -> speaker verification -> the wake word -> the car agent. Screens read this object's state and call its methods.

enum Stage {
    case language, download, preparing, voice, speaker, enroll, wake, car
}

/// Shown on the speaker screen after a failed recording (the same text as the other apps).
let svEnrollmentFailedNotice = "I couldn't hear the samples clearly. Try again in a quiet place, or skip this step."

@MainActor
final class CarAgentApp: ObservableObject {
    private let log = Logger(subsystem: "io.davoice.caragent", category: "CarAgent")
    let packs: LanguagePacks
    let speech = SpeechController()
    private let wakeword = WakewordController()
    private let sv = SpeakerVerificationController()
    let llm = CarLlm(licenseKey: VoiceConfig.davoiceLicenseKey)

    // ---- screen state --------------------------------------------------------------------------------------------------------
    @Published var stage = Stage.language
    @Published var message = ""
    @Published var busy = false
    @Published var language = "en"
    @Published var downloadDone: Int64 = 0
    @Published var downloadTotal: Int64 = 0
    @Published var voices: [String] = []
    @Published var voice = "Rich"
    @Published var svHasSaved = false
    @Published var svCollected = 0
    @Published var svSentences: [String] = []
    @Published var driverOnly = false
    @Published var modelStatus = ""
    @Published var modelProgress = 0.0
    @Published var heard = ""
    @Published var reply = ""
    @Published var working = false
    @Published var ignored = false
    @Published var lastTurn = TurnInfo()
    @Published var conversationPhase = ConversationPhase.off
    @Published var conversationSettings = defaultConversationSettings
    @Published var confidence = ConfidenceSettings.defaults
    @Published var carVersion = 0
    /// No audio input on this device: voice output only, requests are typed (debug text box).
    @Published var noMicrophone = false

    // ---- conversation --------------------------------------------------------------------------------------------------------
    private(set) var conversation: ConversationController!

    // ---- the current request -------------------------------------------------------------------------------------------------
    private var chat: [JObj] = []
    private var inFlight = false
    private var speechEpoch = 0
    private var lastTranscript = ""
    private var spokenThisTurn = ""
    private var wakePrefixPending = false
    private var silenceTask: Task<Void, Never>?
    private var warmUpTask: Task<Void, Never>?
    private var wakewordCreated = false
    private let defaults = UserDefaults.standard
    private var conversationFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("conversation_settings.json")
    }

    private static let carAckAfter: UInt64 = 1_200_000_000

    init() {
        func read(_ path: String) throws -> String { try String(contentsOf: Bundle.main.bundleURL.appendingPathComponent(path), encoding: .utf8) }
        do {
            try CarTools.load(read)
            try AgentPack.load(read)
            packs = try LanguagePacks(try read("language_packs.json"))
        } catch {
            fatalError("The app's resources are missing: \(error)")
        }
        conversation = ConversationController(ConversationCommands(
            openMic: { [weak self] preFetchMs, why in self?.blocking { await self?.openMic(preFetchMs, why) } },
            closeMic: { [weak self] _ in self?.blocking { await self?.closeMic() } },
            armWakeWord: { [weak self] _ in self?.blocking { self?.wakeword.unPauseDetection() } },
            disarmWakeWord: { [weak self] _ in self?.blocking { self?.wakeword.pauseDetection(stopMic: false) } },
            stopReply: { [weak self] why in
                self?.blocking {
                    self?.endReplyNow(why)
                    await self?.speech.stopSpeaking()
                }
            },
            onPhase: { [weak self] p in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.conversationPhase = p
                    if p == .asleep {
                        self.message = self.conversationSettings.wakeWord ? "Say “\(VoiceConfig.wakePhrase)” before each request."
                            : "Say “\(VoiceConfig.wakePhrase)” to continue."
                    }
                }
            },
            log: { [log] in log.info("\($0, privacy: .public)") },
            timer: { ms, fn in
                let item = DispatchWorkItem(block: fn)
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms), execute: item)
                return Cancellable { item.cancel() }
            }), defaultConversationSettings)
        Car.listen { [weak self] in DispatchQueue.main.async { self?.carVersion += 1 } }
        confidence = ConfidenceSettings.parse(defaults.string(forKey: "confidence").flatMap { parseJSON($0) })
        llm.confidence = confidence
        if let text = try? String(contentsOf: conversationFile, encoding: .utf8) {
            conversationSettings = normalizeConversationSettings(parseJSON(text))
        }
        conversation.update(conversationSettings)
        language = defaults.string(forKey: "language") ?? "en"
        speech.onEvent = { [weak self] e in self?.onSpeechEvent(e) }
        wakeword.onDetection = { [weak self] _, _ in DispatchQueue.main.async { Task { await self?.onWakeWord() } } }
    }

    /// A conversation command runs to the end before the next one (the commands queue waits; the work runs on the main actor).
    nonisolated private func blocking(_ work: @escaping @MainActor () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await work()
            done.signal()
        }
        done.wait()
    }

    private var speakerSpeed: Double { AppLanguage.current != "en" ? 1.0 : (voice == "Rich" ? 0.95 : 1.0) }

    // ---- 1. language ---------------------------------------------------------------------------------------------------------
    func chooseLanguage(_ id: String) {
        if busy { return }
        language = id
        AppLanguage.set(id)
        defaults.set(id, forKey: "language")
        if packs.isReady(id) {
            prepare()
            return
        }
        stage = .download
        Task {
            do {
                try await packs.download(id) { done, total in
                    DispatchQueue.main.async {
                        self.downloadDone = done
                        self.downloadTotal = total
                    }
                }
                prepare()
            } catch {
                message = "The voice could not be downloaded: \(error.localizedDescription)"
                stage = .language
            }
        }
    }

    // ---- 2. wake word + speech -----------------------------------------------------------------------------------------------
    private func requestMicPermission() async -> Bool {
        let mic = await withCheckedContinuation { c in AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) } }
        if !mic { return false }
        // asked now so the prompt comes up front; not awaited (the speech library checks it itself when the recognizer starts)
        SFSpeechRecognizer.requestAuthorization { _ in }
        return true
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func prepare() {
        stage = .preparing
        message = "Preparing the voice…"
        Task {
            do {
                guard await requestMicPermission() else { throw Failure(message: "The microphone permission is needed.") }
                if !AVAudioSession.sharedInstance().isInputAvailable || ProcessInfo.processInfo.arguments.contains("-noMicrophone") {
                    try await startWithoutMicrophone()
                    return
                }
                noMicrophone = false
                if !wakewordCreated {
                    try wakeword.setAudioRoutingConfig(VoiceConfig.audioRoutingJson(routingConfigForConversation(VoiceConfig.audioRouting, conversationSettings)))
                    try wakeword.create(VoiceConfig.wakeWords)
                    let licensed = try wakeword.setLicense(VoiceConfig.davoiceLicenseKey)
                    let speechLicensed = await speech.setLicense(VoiceConfig.davoiceLicenseKey)
                    guard licensed && speechLicensed else { throw Failure(message: "License not valid: Please contact info@davoice.io for a new license") }
                    do {
                        try wakeword.startKeywordDetection()
                    } catch {
                        // the microphone did not open (e.g. a simulator on a Mac without one): voice output only
                        log.warning("wake word did not start: \(error.localizedDescription, privacy: .public)")
                        wakeword.destroy()
                        try await startWithoutMicrophone()
                        return
                    }
                    wakewordCreated = true
                } else {
                    await speech.destroyAll()
                }
                wakeword.pauseDetection(stopMic: false)
                try await Task.sleep(nanoseconds: 100_000_000)
                try await initSpeech(nil)
                wakeword.unPauseDetection()
                // a new language: a new agent (its pack and reply language)
                await llm.languageChanged()
                stage = .voice
                message = ""
            } catch {
                log.error("voice setup failed: \(error.localizedDescription, privacy: .public)")
                message = "Voice setup failed: \(error.localizedDescription)"
                stage = .language
            }
        }
    }

    /// No microphone (none on the device, or it did not open): the wake word and speech recognition cannot run, so the car agent works
    /// from typed text with its voice only (the React Native API's TTS-only mode).
    private func startWithoutMicrophone() async throws {
        log.warning("no audio input: voice output only (wake word and speech recognition off)")
        await speech.destroyAll()
        try speech.initTTS(model: packs.modelPath(language), licenseKey: VoiceConfig.davoiceLicenseKey)
        await loadVoices()
        await llm.languageChanged()
        noMicrophone = true
        stage = .voice
        message = ""
    }

    private func initSpeech(_ enrollmentJson: String?) async throws {
        try await speech.initAll(locale: appLanguageInfo(language).sttLocale, model: packs.modelPath(language), onboardingJsonPath: enrollmentJson,
                                 speakerId: VoiceConfig.svSpeakerId)
        // as the React Native app on iOS: let the recognizer settle before the first pause
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await speech.pauseSpeechRecognition()
        await loadVoices()
    }

    /// The loaded model's voices; keeps the chosen one when the model has it.
    private func loadVoices() async {
        let all = await speech.getAllVoices()
        voices = all.isEmpty ? ["Rich"] : all
        if !voices.contains(voice) {
            let preferred = originalTtsVoices[language] ?? "Rich"
            voice = voices.contains(preferred) ? preferred : voices.contains("Rich") ? "Rich" : voices[0]
        }
        await speech.changeVoice(voice)
    }

    // ---- 3. voice ------------------------------------------------------------------------------------------------------------
    func chooseVoice(_ v: String) {
        voice = v
        Task {
            await speech.stopSpeaking()
            await speech.changeVoice(v)
            await speech.speak(AppLanguage.isPortuguese ? "Olá! Eu sou a voz do seu carro." : "Hi! I'll be the voice of your car.", speed: speakerSpeed)
        }
    }

    func continueFromVoice() {
        svHasSaved = sv.loadSavedEnrollment() != nil
        stage = .speaker
    }

    // ---- 4. speaker verification ---------------------------------------------------------------------------------------------
    func skipSpeaker() {
        CurrentSpeaker.setGate(false, nil)
        driverOnly = false
        toWakeWord()
    }

    func useSavedSpeaker() {
        guard let json = sv.loadSavedEnrollment() else { return }
        Task { await applySpeaker(json) }
    }

    func createSpeaker() {
        svSentences = enrollmentSentences(language, VoiceConfig.wakePhrase, VoiceConfig.svOnboardingSampleCount)
        svCollected = 0
        stage = .enroll
        Task {
            // The wake word releases the microphone while the samples are recorded.
            wakeword.pauseDetection(stopMic: true)
            defer { wakeword.unPauseDetection() }
            do {
                let json = try await sv.enroll(samples: VoiceConfig.svOnboardingSampleCount) { collected, _ in
                    DispatchQueue.main.async { self.svCollected = collected }
                }
                sv.saveEnrollment(json)
                await applySpeaker(json)
            } catch {
                log.warning("voice signature not recorded: \(error.localizedDescription, privacy: .public)")
                message = svEnrollmentFailedNotice
                stage = .speaker
            }
        }
    }

    private func applySpeaker(_ json: String) async {
        do {
            _ = try wakeword.addSpeaker(VoiceConfig.svSpeakerId, json)
            try await speech.addSpeaker(VoiceConfig.svSpeakerId, json)
            CurrentSpeaker.setGate(true, VoiceConfig.svSpeakerId)
            driverOnly = true
        } catch {
            log.warning("speaker verification not applied: \(error.localizedDescription, privacy: .public)")
            CurrentSpeaker.setGate(false, nil)
            driverOnly = false
        }
        toWakeWord()
    }

    private func toWakeWord() {
        stage = .wake
        message = noMicrophone ? "No microphone on this device: tap Start and type your requests." : "Say “\(VoiceConfig.wakePhrase)” to start."
        startWarmUp()
    }

    /// The model downloads and warms up in the background while the driver gets to the car screen.
    private func startWarmUp() {
        if warmUpTask != nil || llm.isModelReady { return }
        warmUpTask = Task {
            defer { warmUpTask = nil }
            do {
                modelStatus = llm.store.isDownloaded() ? "Loading" : "Downloading 0%"
                try await llm.warmUp(chat, onDownloadProgress: { f in
                    DispatchQueue.main.async {
                        self.modelProgress = f
                        self.modelStatus = "Downloading \(Int(f * 100))%"
                    }
                }, onWarming: { DispatchQueue.main.async { self.modelStatus = "Warming up" } })
                modelStatus = "Ready"
            } catch {
                log.error("model warm-up failed: \(error.localizedDescription, privacy: .public)")
                modelStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }

    // ---- 5. the wake word and the car screen ---------------------------------------------------------------------------------
    private func onWakeWord() async {
        if conversation.active {
            // in the conversation: wakes it from sleep or stops the agent
            wakePrefixPending = true
            _ = conversation.wakeWord()
        } else if stage == .wake {
            enterCar()
        }
    }

    /// The first wake word (or the screen's button): the car screen, listening.
    func enterCar() {
        if stage == .car { return }
        stage = .car
        heard = ""
        reply = ""
        resetTranscript()
        wakePrefixPending = false
        Task {
            if conversationSettings.wakeWord {
                // wake word before each request: recognition stays paused and the conversation starts asleep (conversation.enter arms
                // the wake word); the wake word that opened this screen is not a request
                message = "Say “\(VoiceConfig.wakePhrase)” before each request."
            } else {
                message = "Listening…"
                wakeword.pauseDetection(stopMic: false)
                await speech.unPauseSpeechRecognition(-1, 0)
            }
            conversation.enter()
            startWarmUp()
        }
    }

    /// Back: the wake-word screen, listening for the wake word again.
    func leaveCar() {
        speechEpoch += 1
        inFlight = false
        working = false
        conversation.leave(rearmWakeWord: true)
        silenceTask?.cancel()
        Task {
            await speech.stopSpeaking()
            await speech.pauseSpeechRecognition()
        }
        stage = .wake
        message = "Say “\(VoiceConfig.wakePhrase)” to talk to the car agent."
    }

    func resetChat() {
        chat.removeAll()
        heard = ""
        reply = ""
        lastTurn = TurnInfo()
        FollowUp.reset()
    }

    func tapToTalk() { conversation.tapToTalk() }

    // ---- settings ------------------------------------------------------------------------------------------------------------
    func changeConfidence(_ next: ConfidenceSettings) {
        confidence = next
        llm.confidence = next
        defaults.set(Json.stringify(next.json), forKey: "confidence")
    }

    func changeConversation(_ next: ConversationSettings) {
        let previous = conversationSettings
        conversationSettings = next
        conversation.update(next)
        try? Json.stringify(next.json).write(to: conversationFile, atomically: true, encoding: .utf8)
        log.info("[Conversation] settings \(Json.stringify(next.json), privacy: .public)")
        // interrupt on / off: echo cancellation in the routing JSON the wake word, STT and TTS share
        if previous.interrupt != next.interrupt {
            try? wakeword.setAudioRoutingConfig(VoiceConfig.audioRoutingJson(routingConfigForConversation(VoiceConfig.audioRouting, next)))
        }
    }

    // ---- speech recognition --------------------------------------------------------------------------------------------------
    private func onSpeechEvent(_ e: SpeechController.Event) {
        switch e {
        case .partial(let text, let ids, let id): onSpeech(text, ids, id, final: false)
        case .final(let text, let ids, let id): onSpeech(text, ids, id, final: true)
        case .error(let m): log.info("speech error: \(m, privacy: .public)")
        default: break
        }
    }

    /// The iOS rule of the React Native car agent (src/stt/index.ts): every update sends the recognizer's whole current text, first as
    /// a result, then as partials. A new text replaces the transcript (no merging), and only a result restarts the end-of-speech timer.
    private func onSpeech(_ text: String, _ speakerIds: [String], _ speakerId: String?, final: Bool) {
        CurrentSpeaker.noteResult(speakerIds, speakerId)
        let current = text.trimmed
        if stage != .car || current.isEmpty { return }
        // asleep (waiting for the wake word or a tap): nothing heard counts, even if the recognizer was still open
        if conversation.phase == .asleep { return }
        // a request is being answered: dropped, unless the user interrupted the reply (interrupt mode)
        if inFlight && !heardWhileBusy(current) { return }
        conversation.userSpeech()
        if current == lastTranscript { return }
        lastTranscript = current
        // shown without the wake phrase after the wake word (as the agent gets it); the pre-fetched wake phrase never reaches the model
        let forModel = wakePrefixPending && conversationSettings.wakeWord ? dropWakePhrase(lastTranscript, VoiceConfig.wakePhrase) : lastTranscript
        heard = forModel
        // the words so far into the model's cache while the driver still speaks
        if !forModel.isEmpty {
            let history = chat
            Task { await llm.prefill(history, forModel) }
        }
        if !final { return }
        silenceTask?.cancel()
        // words that cannot end a request ("Set the", "Please") wait longer (Flow/EndOfSpeech.swift)
        let wait = silenceFor(forModel, conversationSettings.endOfSpeechMs, AppLanguage.current)
        if wait != conversationSettings.endOfSpeechMs { log.info("[AIChat] sounds unfinished, waiting \(wait) ms: \"\(forModel, privacy: .public)\"") }
        silenceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
            if Task.isCancelled { return }
            let t = lastTranscript.trimmed
            if !t.isEmpty && !inFlight { await answer(t) }
        }
    }

    private func heardWhileBusy(_ text: String) -> Bool {
        if !conversation.heardWhileBusy(text, spokenThisTurn) { return false }
        endReplyNow("the user interrupted")
        return true
    }

    private func resetTranscript() {
        silenceTask?.cancel()
        lastTranscript = ""
    }

    private func openMic(_ preFetchMs: Int, _ why: String) async {
        log.info("[Conversation] open the microphone (\(why, privacy: .public))")
        resetTranscript()
        await speech.unPauseSpeechRecognition(-1, preFetchMs)
        if !conversation.duplexOpen && !inFlight { message = "Listening…" }
    }

    private func closeMic() async {
        resetTranscript()
        await speech.pauseSpeechRecognition()
    }

    /// Interrupt mode, the stop word or a tap: the reply ends now (a new speech epoch drops the rest of the request).
    private func endReplyNow(_ why: String) {
        if !inFlight { return }
        log.info("[Conversation] reply stopped: \(why, privacy: .public)")
        speechEpoch += 1
        inFlight = false
        working = false
        message = "Stopped. Listening…"
    }

    // ---- one request (the other apps' local-model turn) ----------------------------------------------------------------------
    func sendText(_ text: String) { Task { await answer(text) } }

    /// What one request has said and shown so far (the agent's callbacks reach it on the main queue).
    private final class TurnState {
        var shown = ""
        var spoken: Task<Void, Never>?
        var replyText = ""
        var pending = ""
        var held = ""
        var acked = false
        var ackSaid = ""
        var spoke = false
    }

    private func answer(_ rawText: String) async {
        let language = AppLanguage.current
        var userText = rawText.trimmed
        if wakePrefixPending && conversationSettings.wakeWord {
            userText = dropWakePhrase(rawText, VoiceConfig.wakePhrase)
            if !userText.isEmpty { wakePrefixPending = false }
        }
        if userText.isEmpty || inFlight { return } // only the wake phrase so far: the next words complete the request
        wakePrefixPending = false
        inFlight = true
        speechEpoch += 1
        let epoch = speechEpoch
        spokenThisTurn = ""
        conversation.turnStarted()
        silenceTask?.cancel()
        lastTranscript = ""
        working = true
        ignored = false
        heard = userText
        reply = ""
        let history = chat
        chat.append(["role": "user", "text": JSON(userText)])
        let st = TurnState()
        defer {
            if epoch == speechEpoch {
                inFlight = false
                working = false
                // the request ended: the conversation mode decides what's next (listen again, or back to the wake word)
                if conversation.phase == .busy { conversation.replyFinished(spokenThisTurn) }
            }
        }
        await speech.pauseSpeechRecognition()
        if epoch != speechEpoch { return }
        // speech noise ("The.", "But.", "Alma Alma."): not sent to the model
        if isNoiseFragment(userText) && BasicLanguage.normalizeYesNo(userText, language) == nil {
            await sayWhole(didNotCatch(language), st, epoch, language)
            return
        }
        // what goes to the agent for these words (an answer to the agent's question goes with its request, a yes to a pending offer), or
        // the app's own short reply ("never mind" -> "Okay.")
        let s = Car.state
        let input = FollowUp.carTurnInput(userText, language, SpeechComposer.pendingOfferCalls(),
                                          musicOn: (s.media != nil || s.radio != nil) && !s.muted, state: s,
                                          lastActed: !SpeechComposer.carTurnActions().isEmpty)
        if let r = input.reply {
            FollowUp.noteCarSpoken(r)
            await sayWhole(r, st, epoch, language)
            return
        }
        let agentText = input.text ?? userText
        if !llm.isModelReady {
            let status = modelStatus
            if status.hasPrefix("Failed") {
                startWarmUp()
                await sayWhole("The on-device model, \(CarModel.displayName), failed to load, so I am trying again. Please ask me again in a moment.", st, epoch, language)
            } else if status.hasPrefix("Downloading") {
                await sayWhole("The on-device model, \(CarModel.displayName), is still downloading. It is \(Int(modelProgress * 100)) percent done. Please ask me again when it is ready.", st, epoch, language)
            } else {
                // no warm-up running (e.g. it was cancelled): start it again (startWarmUp does nothing while one runs)
                startWarmUp()
                await sayWhole("The on-device model, \(CarModel.displayName), is still loading. Please ask me again in a moment.", st, epoch, language)
            }
            return
        }
        message = "Thinking…"
        if agentText != userText { log.info("[CAR] \"\(userText, privacy: .public)\" -> agent: \"\(agentText, privacy: .public)\"") }
        CarTools.noteUserText(agentText)
        SpeechComposer.beginCarTurn()
        // a request that takes a moment gets a short "Got it." so the driver is not left in silence
        let ack = Task {
            try? await Task.sleep(nanoseconds: Self.carAckAfter)
            if Task.isCancelled || epoch != speechEpoch || st.spoke || !st.held.trimmed.isEmpty { return }
            guard let a = SpeechComposer.carAck(language) else { return }
            st.acked = true
            st.ackSaid = a
            speakSentence(a, st, epoch, language)
        }
        do {
            let turn = try await llm.turn(history, agentText, onDelta: { [weak self] delta in
                DispatchQueue.main.async {
                    guard let self, epoch == self.speechEpoch else { return }
                    st.replyText += delta
                    // once a car action ran in this request, its sentences are held and said together at the end
                    if !SpeechComposer.carTurnActions().isEmpty {
                        st.held += delta
                    } else {
                        let (done, rest) = splitCompletedSentences(st.pending + delta)
                        st.pending = rest
                        if !done.isEmpty { st.spoke = true }
                        for sentence in done { self.speakSentence(sentence, st, epoch, language) }
                    }
                }
            }, onEvent: { [weak self] e in
                DispatchQueue.main.async {
                    guard let self, epoch == self.speechEpoch, e.type == "filler" else { return }
                    st.spoke = true
                    self.speakSentence(e.text, st, epoch, language)
                }
            })
            ack.cancel()
            // the text events were queued to the main queue before the turn's result: let them run first
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            if epoch != speechEpoch { return }
            lastTurn = TurnInfo.read(turn.json)
            if turn.json["scope"]?.object?["outcome"] == "ignore" && st.replyText.trimmed.isEmpty {
                // background talk, not for the assistant: nothing said, the heard text stays on screen (marked)
                chat.removeLast()
                ignored = true
                message = "Not for me: ignored."
                return
            }
            if !st.pending.trimmed.isEmpty { speakSentence(st.pending.trimmed, st, epoch, language) }
            if !st.held.trimmed.isEmpty {
                let composed = SpeechComposer.composeCarSpeech(st.held, SpeechComposer.carTurnActions(), language, acked: st.acked, driving: Car.state.driving)
                if composed != st.held.trimmed { log.info("[SPEECH] \"\(st.held.trimmed, privacy: .public)\" -> \"\(composed, privacy: .public)\"") }
                let heldSet = Set(splitCompletedSentences("\(st.held.trimmed) ").completed)
                for sentence in splitCompletedSentences("\(composed) ").completed {
                    speakSentence(sentence, st, epoch, language, composed: !heldSet.contains(sentence))
                }
            }
            let r = st.replyText.trimmed
            // a question in the reply: the next short answer goes with this request
            FollowUp.noteCarReply(agentText, r, language)
            let said = !st.ackSaid.isEmpty && st.shown.hasPrefix(st.ackSaid) ? String(st.shown.dropFirst(st.ackSaid.count)).trimmed : st.shown.trimmed
            FollowUp.noteCarSpoken(said.isEmpty ? r : said)
            log.info("[LOCAL_LLM] \"\(userText, privacy: .public)\" -> \(r, privacy: .public)")
            var modelTurn: JObj = ["role": "model", "text": JSON(r)]
            if !turn.toolMessages.isEmpty { modelTurn["toolMessages"] = JSON(turn.toolMessages) }
            chat.append(modelTurn)
            message = "Speaking…"
            conversation.replySpeaking()
            await st.spoken?.value
            if epoch == speechEpoch { reply = st.shown.isEmpty ? r : st.shown }
        } catch {
            ack.cancel()
            if epoch != speechEpoch { return }
            log.error("turn failed: \(error.localizedDescription, privacy: .public)")
            let text = "Local AI chat error: \(error.localizedDescription)"
            reply = text
            await sayWhole(text, st, epoch, language)
        }
    }

    /// One sentence of the reply, queued now (in order). The model's bare "Done." is never a confirmation (the app says what it did)
    /// -> "didn't catch that"; a Basic language's Portuguese sentence -> "say it again?" in the user's language.
    private func speakSentence(_ raw: String, _ st: TurnState, _ epoch: Int, _ language: String, composed: Bool = false) {
        if epoch != speechEpoch { return }
        let sentence = composed ? raw : (isBareDone(raw) ? didNotCatch(language) : (BasicLanguage.replyFix(raw, language) ?? raw))
        spokenThisTurn += " \(sentence)"
        st.spoken = speech.speakInOrder(normalizeTextForSpeech(sentence), speed: speakerSpeed)
        st.shown = st.shown.isEmpty ? sentence : "\(st.shown) \(sentence)"
        reply = st.shown
    }

    /// The app's own reply (said whole, kept in the chat).
    private func sayWhole(_ text: String, _ st: TurnState, _ epoch: Int, _ language: String) async {
        chat.append(["role": "model", "text": JSON(text)])
        conversation.replySpeaking()
        speakSentence(text, st, epoch, language, composed: true)
        await st.spoken?.value
    }

    private func didNotCatch(_ language: String) -> String {
        didNotCatchTexts[language] ?? BasicLanguage.message(language, "didNotCatch") ?? didNotCatchTexts["en"]!
    }
}
