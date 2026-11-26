import Foundation
import DavoiceTTS
import os

/// Speech-to-text + text-to-speech: the iOS twin of the React Native `Speech` object (react-native-davoice/speech), on the same native
/// SpeechBridge the React Native and Cordova packages use (Bridges/, copied unchanged). Method names, arguments and the JS layer's
/// behaviour are kept, so code ports over line by line:
///  - initAll starts the recognizer and loads a TTS model. TTS and STT coordinate on their own: the recognizer is paused while TTS
///    plays, so the app never hears itself.
///  - speak queues text right away and returns when everything queued so far has been spoken, so call it for each sentence as soon as
///    you have it.
///  - Events (the React Native onSpeech* / onFinishedSpeaking callbacks) arrive on onEvent.
/// SpeechBridge's methods run on the main queue (its methodQueue); this class calls them there.
@MainActor
final class SpeechController {
    enum Event {
        /// Live text. speakerIds / speakerId are set only when speaker verification is on.
        case partial(text: String, speakerIds: [String], speakerId: String?)
        /// The recognizer's current best text (on iOS sent on every update, before the partials).
        case final(text: String, speakerIds: [String], speakerId: String?)
        case error(String)
        case start
        case end
        /// The speech queue is empty (React Native onFinishedSpeaking).
        case finishedSpeaking
    }

    /// Called on the main queue.
    var onEvent: ((Event) -> Void)?

    private let bridge = SpeechBridge()
    private let log = Logger(subsystem: "io.davoice.caragent", category: "Speech")
    // speak(): each caller waits for the queue-empty event; stopSpeaking() bumps the epoch, which drops unsent texts.
    private var speakWaiters: [CheckedContinuation<Void, Never>] = []
    private var ttsEpoch = 0

    static let defaultSpeaker = "default"

    init() {
        bridge.dvEventSink = { [weak self] name, body in
            DispatchQueue.main.async { self?.handle(name, body as? [String: Any] ?? [:]) }
        }
        // React Native's NativeEventEmitter does this when the app adds a listener: SpeechBridge only forwards events after it.
        bridge.startObserving()
    }

    private func handle(_ name: String, _ body: [String: Any]) {
        let values = (body["value"] as? [String]) ?? []
        let ids = (body["speakerIds"] as? [String]) ?? []
        let id = body["speakerId"] as? String
        switch name {
        case "onSpeechPartialResults": if let t = values.first { onEvent?(.partial(text: t, speakerIds: ids, speakerId: id)) }
        case "onSpeechResults": if let t = values.first { onEvent?(.final(text: t, speakerIds: ids, speakerId: id)) }
        case "onSpeechError": onEvent?(.error("\(body["error"] ?? body)"))
        case "onSpeechStart": onEvent?(.start)
        case "onSpeechEnd": onEvent?(.end)
        case "onFinishedSpeaking":
            releaseSpeakWaiters()
            onEvent?(.finishedSpeaking)
        default: break
        }
    }

    // ---- promise helpers (the bridge resolves / rejects like a React Native module) ------------------------------------------

    struct BridgeError: Error, LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { "\(message) (\(code))" }
    }

    private func call(_ f: (@escaping RCTPromiseResolveBlock, @escaping RCTPromiseRejectBlock) -> Void) async throws -> Any? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any?, Error>) in
            var done = false
            let lock = NSLock()
            func once(_ r: Result<Any?, Error>) {
                lock.lock()
                defer { lock.unlock() }
                if done { return }
                done = true
                c.resume(with: r)
            }
            f({ value in once(.success(value)) }, { code, message, error in
                once(.failure(error ?? BridgeError(code: code ?? "ERROR", message: message ?? "failed")))
            })
        }
    }

    // ---- license / routing ---------------------------------------------------------------------------------------------------

    /// STT and TTS share one license.
    func setLicense(_ key: String) async -> Bool {
        let r = try? await call { bridge.setLicense(key, resolver: $0, rejecter: $1) }
        return (r as? Bool) ?? ((r as? NSNumber)?.boolValue ?? false)
    }

    // ---- init / destroy ------------------------------------------------------------------------------------------------------

    /// Starts recognition in locale and loads model (a .dm file path) for TTS. onboardingJsonPath (enrollment JSON or a path) adds one
    /// speaker under speakerId: STT then transcribes only the enrolled speakers.
    func initAll(locale: String, model: String, onboardingJsonPath: String? = nil, speakerId: String = SpeechController.defaultSpeaker) async throws {
        cancelSpeakWaits()
        var opts: [String: Any] = ["locale": locale, "model": model]
        if let p = onboardingJsonPath, !p.isEmpty {
            opts["onboardingJsonPath"] = p
            opts["speakerId"] = speakerId
        }
        _ = try await call { bridge.initAll(opts, resolver: $0, rejecter: $1) }
    }

    /// Releases TTS and STT; initAll again to use speech after this.
    func destroyAll() async {
        cancelSpeakWaits()
        if let t = ttsOnly {
            t.stopSpeaking()
            t.destroy()
            ttsOnly = nil
            return
        }
        _ = try? await call { bridge.destroyAll($0, rejecter: $1) }
    }

    // ---- TTS only (React Native Speech.initTTS on iOS: DaVoiceTTS without the recognizer, as DaVoiceTTSBridge does) -------------

    private var ttsOnly: DaVoiceTTS?

    /// TTS only: loads model (a .dm file path), no speech recognition (a phone or simulator without a microphone).
    func initTTS(model: String, licenseKey: String) throws {
        cancelSpeakWaits()
        _ = DaVoiceTTS.activateLicense(licenseKey: licenseKey)
        let tts = try DaVoiceTTS(model: URL(fileURLWithPath: model))
        _ = tts.setLicense(licenseKey: licenseKey)
        tts.onLastUtteranceFinished = { [weak self] in
            DispatchQueue.main.async { self?.handle("onFinishedSpeaking", [:]) }
        }
        ttsOnly = tts
    }

    var isTTSOnly: Bool { ttsOnly != nil }

    // ---- speech to text ------------------------------------------------------------------------------------------------------

    /// Pauses recognition ("lite" pause: the microphone stays open). Bounded in the library (~500 ms).
    func pauseSpeechRecognition() async {
        let r = try? await call { bridge.pauseSpeechRecognitionLiteAsync(500, resolver: $0, rejecter: $1) }
        if let d = r as? [String: Any], (d["ok"] as? Bool) == false { log.notice("pauseSpeechRecognitionLiteAsync reached its timeout (not a bug)") }
    }

    /// Releases times pauses (-1 releases every outstanding pause). preFetchMs (0-2000) keeps that much audio from before the unpause.
    /// ok is false when the recognizer did not confirm it restarted within timeoutMs.
    @discardableResult
    func unPauseSpeechRecognition(_ times: Int, _ preFetchMs: Int = 0, timeoutMs: Int = 500) async -> (ok: Bool, reason: String) {
        do {
            let r = try await call {
                bridge.unPauseSpeechRecognitionLiteAsync(NSNumber(value: times), preFetchMs: NSNumber(value: preFetchMs),
                                                         timeoutMs: NSNumber(value: timeoutMs), resolver: $0, rejecter: $1)
            }
            let d = r as? [String: Any]
            return ((d?["ok"] as? Bool) != false, "\(d?["reason"] ?? "")")
        } catch {
            return (false, "native_exception")
        }
    }

    /// Adds (or replaces) one speaker. Returns the enrolled ids.
    @discardableResult
    func addSpeaker(_ speakerId: String, _ jsonOrPath: String) async throws -> [String] {
        (try await call { bridge.addSpeaker(speakerId, jsonOrPath: jsonOrPath, resolver: $0, rejecter: $1) } as? [String]) ?? []
    }

    func removeSpeaker(_ speakerId: String) async {
        _ = try? await call { bridge.removeSpeaker(speakerId, resolver: $0, rejecter: $1) }
    }

    /// Echo cancellation for the interrupt mode (the routing JSON's AEC normally decides).
    func setAECEnabled(_ enabled: Bool) async {
        _ = try? await call { bridge.setAECEnabled(enabled, resolver: $0, rejecter: $1) }
    }

    // ---- text to speech ------------------------------------------------------------------------------------------------------

    /// Voices in the loaded .dm (the names changeVoice accepts; the first is the default).
    func getAllVoices() async -> [String] {
        if let t = ttsOnly { return t.getAllVoices() }
        return ((try? await call { bridge.getAllVoices($0, rejecter: $1) }) as? [String]) ?? []
    }

    /// 0 if name matched (case-insensitive), -1 otherwise. Audio already generated keeps its voice.
    @discardableResult
    func changeVoice(_ name: String) async -> Int {
        if let t = ttsOnly { return await withCheckedContinuation { c in t.changeVoice(name) { c.resume(returning: $0) } } }
        let r = try? await call { bridge.changeVoice(name, resolver: $0, rejecter: $1) }
        return (r as? NSNumber)?.intValue ?? -1
    }

    // Only the sends are serialized (in call order, as the JS layer's ttsChain); none waits for the previous text to be spoken.
    private var sendChain: Task<Void, Never>?

    /// Queues text now (in call order) and returns a task that ends when everything queued so far has been spoken. speed: 1.0 = normal.
    @discardableResult
    func speakInOrder(_ text: String, speakerId: Int = 0, speed: Double = 1.0) -> Task<Void, Never> {
        // as the JS layer: the native side gets the length scale (1 / speed)
        let s = speed.isFinite && speed != 0 ? 1.0 / speed : 1.0
        let epoch = ttsEpoch
        let previous = sendChain
        let send = Task { () -> Bool in
            await previous?.value
            if epoch != ttsEpoch { return false }
            if let t = ttsOnly {
                t.speak(text, sid: Int32(speakerId), speed: Float(s))
                return epoch == ttsEpoch
            }
            do {
                _ = try await call { bridge.speak(text, speakerId: NSNumber(value: speakerId), speed: NSNumber(value: s), resolver: $0, rejecter: $1) }
            } catch {
                log.error("speak failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
            return epoch == ttsEpoch
        }
        sendChain = Task { _ = await send.value }
        return Task {
            guard await send.value else { return }
            // Waits from now: a queue-empty event sent before native had this text has already arrived.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in speakWaiters.append(c) }
        }
    }

    /// Queues text and returns when everything queued so far has been spoken (React Native Speech.speak).
    func speak(_ text: String, speakerId: Int = 0, speed: Double = 1.0) async {
        await speakInOrder(text, speakerId: speakerId, speed: speed).value
    }

    /// Stops playback now and drops what is queued; pending speak calls return right away.
    func stopSpeaking() async {
        cancelSpeakWaits()
        if let t = ttsOnly {
            t.stopSpeaking()
            return
        }
        _ = try? await call { bridge.stopSpeaking($0, rejecter: $1) }
    }

    private func releaseSpeakWaiters() {
        let waiters = speakWaiters
        speakWaiters = []
        for w in waiters { w.resume() }
    }

    private func cancelSpeakWaits() {
        ttsEpoch += 1
        sendChain = nil
        releaseSpeakWaiters()
    }
}
