import Foundation
import os

/// Always-listening wake word: the iOS twin of the React Native `KeyWordRNBridgeInstance` (react-native-wakeword), on the framework-
/// neutral DVWakeWordCore that the Cordova and Capacitor plugins use (Bridges/). Method names and defaults match the React Native API
/// (startKeywordDetection(threshold, true): no external audio-session activation, no ducking, mix with others, default to speaker).
final class WakewordController {
    private let core = DVWakeWordCore()
    private let instanceId = "multi_model_instance"
    private var created = false
    private var threshold: Float = 0.999
    private let log = Logger(subsystem: "io.davoice.caragent", category: "Wakeword")

    /// Called with the detected model's name and, when speaker verification is on, the enrolled speaker that opened the gate
    /// (React Native `onKeywordDetectionEvent` with `phrase` / `speakerId`). On a library thread.
    var onDetection: ((_ modelName: String, _ speakerId: String?) -> Void)?

    init() {
        core.eventSink = { [weak self] event in
            guard let self, (event["eventName"] as? String) == "keywordDetected" else { return }
            let name = (event["modelName"] as? String) ?? (event["phrase"] as? String) ?? ""
            self.log.info("detected \(name, privacy: .public)")
            self.onDetection?(name, event["speakerId"] as? String)
        }
    }

    @discardableResult
    private func action(_ name: String, _ options: [String: Any] = [:]) throws -> [String: Any] {
        var o = options
        o["instanceId"] = instanceId
        do {
            return (try core.executeAction(name, options: o) as? [String: Any]) ?? [:]
        } catch {
            log.error("\(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// The routing JSON shared by wake word, STT and TTS (React Native `setWakewordAudioRoutingConfig`). Set it before create; later
    /// calls apply to the running session.
    func setAudioRoutingConfig(_ json: String) throws {
        _ = try core.executeAction("setAudioRoutingConfig", options: ["config": json])
    }

    /// Loads the models (bundle file names): React Native `createInstanceMulti`.
    func create(_ models: [VoiceConfig.WakeWordModel]) throws {
        threshold = models.first?.threshold ?? 0.999
        try action("createMulti", [
            "modelNames": models.map(\.fileName),
            "thresholds": models.map { NSNumber(value: $0.threshold) },
            "bufferCounts": models.map { NSNumber(value: $0.bufferCount) },
            "millisecondsBetweenCallbacks": models.map { NSNumber(value: $0.msBetweenCallbacks) },
        ])
        created = true
    }

    func setLicense(_ key: String) throws -> Bool { (try action("setLicense", ["license": key])["licensed"] as? Bool) == true }

    /// React Native startKeywordDetection(threshold, true) (or with the enrollment JSON / path: the wake word fires only for that voice).
    func startKeywordDetection(speakerEnrollmentJsonOrPath: String? = nil) throws {
        var o: [String: Any] = ["threshold": NSNumber(value: threshold), "noExternalActivation": true]
        if let e = speakerEnrollmentJsonOrPath, !e.isEmpty { o["speakerVerificationEnrollmentJsonOrPath"] = e }
        try action("start", o)
    }

    func stopKeywordDetection() { _ = try? action("stop") }

    /// Pauses detection; with stopMic false the microphone stays open (faster resume).
    func pauseDetection(stopMic: Bool = false) {
        guard created else { return }
        _ = try? action("pause", ["stopMicrophone": stopMic])
    }

    func unPauseDetection() {
        guard created else { return }
        _ = try? action("resume")
    }

    /// Adds (or replaces) one speaker while listening. Returns the enrolled ids.
    func addSpeaker(_ speakerId: String, _ jsonOrPath: String) throws -> [String] {
        (try action("addSpeaker", ["speakerId": speakerId, "jsonOrPath": jsonOrPath])["speakerIds"] as? [String]) ?? []
    }

    func removeSpeaker(_ speakerId: String) { _ = try? action("removeSpeaker", ["speakerId": speakerId]) }

    /// Tells the detector TTS audio is playing (it then uses the routing config's wakeWordDuringTTS settings).
    func setTTSActive(_ active: Bool) { _ = try? action("setTtsActive", ["active": active]) }

    func destroy() {
        _ = try? action("destroy")
        created = false
    }
}
