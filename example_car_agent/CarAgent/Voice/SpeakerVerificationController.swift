import Foundation
import os

/// Speaker verification: records the owner's voice signature from the microphone (5 sentences) and saves it. The signature then goes to
/// the wake word (fires only for that voice) and to STT (reports who spoke). The same steps and limits as the React Native car agent's
/// onboarding (src/speaker_verification/onboarding.ts), on the framework-neutral DVSpeakerVerificationCore (Bridges/).
final class SpeakerVerificationController {
    private let core = DVSpeakerVerificationCore()
    private let controllerId = "svMic1"
    private let log = Logger(subsystem: "io.davoice.caragent", category: "SV")
    private let events = EventQueue()

    /// How long one voice sample may take (the user reads a sentence; 2026-11-22: 30 s was too short on the phone).
    private let sampleTimeout: TimeInterval = 60
    /// After the last sample, how long the speaker profile may take to build.
    private let finalizeTimeout: TimeInterval = 30

    init() {
        core.eventSink = { [weak self] e in
            guard let self, (e["controllerId"] as? String) == self.controllerId else { return }
            self.events.push(e as? [String: Any] ?? [:])
        }
    }

    var enrollmentFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(VoiceConfig.svEnrollmentFile)
    }

    func loadSavedEnrollment() -> String? {
        guard let s = try? String(contentsOf: enrollmentFile, encoding: .utf8), s.count >= 10 else { return nil }
        return s
    }

    func saveEnrollment(_ json: String) { try? json.write(to: enrollmentFile, atomically: true, encoding: .utf8) }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func action(_ name: String, _ options: [String: Any] = [:]) throws {
        var o = options
        o["controllerId"] = controllerId
        _ = try core.executeAction(name, options: o)
    }

    /// Records samples voice samples and returns the enrollment JSON. onProgress gets (collected, target) after each sample.
    func enroll(samples: Int, onProgress: @escaping (Int, Int) -> Void) async throws -> String {
        let config: [String: Any] = [
            "modelPath": VoiceConfig.svModel,
            "options": [
                "decisionThreshold": VoiceConfig.svDecisionThreshold,
                "tailSeconds": 2.0, "frameSize": 1280, "maxTailSeconds": 3.0, "cmn": true, "expectedLayoutBDT": false,
            ] as [String: Any],
        ]
        events.clear()
        try action("createSpeakerVerificationMicController", ["config": config])
        defer {
            // success or failure: the mic controller is closed (it would fight the wake word and STT for the microphone)
            try? action("destroySpeakerVerificationMicController")
        }
        try action("svBeginOnboarding", ["enrollmentId": "davoice", "targetEmbeddingCount": samples, "reset": true])
        var collected = 0
        var enrollmentJson: String?
        var done = false
        for i in 1...samples where !done {
            log.info("requesting sample \(i)/\(samples)")
            let before = collected
            try action("svGetNextEmbeddingFromMic")
            // wait for this sample (or the profile)
            while true {
                let e = try await events.next(timeout: sampleTimeout)
                let name = e["eventName"] as? String
                if name == "speakerVerificationError" { throw Failure(message: "Speaker verification error: \(e)") }
                if name == "speakerVerificationOnboardingDone" {
                    enrollmentJson = Self.json(e)
                    done = true
                    break
                }
                if name == "speakerVerificationOnboardingProgress" {
                    collected = (e["collected"] as? NSNumber)?.intValue ?? collected
                    onProgress(collected, (e["target"] as? NSNumber)?.intValue ?? samples)
                    if collected > before { break }
                }
            }
        }
        while !done {
            let e = try await events.next(timeout: finalizeTimeout)
            let name = e["eventName"] as? String
            if name == "speakerVerificationError" { throw Failure(message: "Speaker verification error: \(e)") }
            if name == "speakerVerificationOnboardingDone" {
                enrollmentJson = Self.json(e)
                done = true
            }
        }
        guard let json = enrollmentJson, json.count >= 10 else { throw Failure(message: "Onboarding finished without a valid enrollment") }
        onProgress(samples, samples)
        return json
    }

    private static func json(_ e: [String: Any]) -> String? {
        (e["enrollmentJson"] as? String) ?? (e["enrollment"] as? String) ?? (e["json"] as? String)
    }
}

/// Events from a native callback thread, awaited one at a time.
private final class EventQueue {
    private let lock = NSLock()
    private var items: [[String: Any]] = []
    private var waiter: CheckedContinuation<[String: Any], Error>?

    struct Timeout: Error, LocalizedError {
        var errorDescription: String? { "timed out waiting for the next voice sample" }
    }

    func clear() {
        lock.lock()
        items.removeAll()
        lock.unlock()
    }

    func push(_ e: [String: Any]) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: e)
            return
        }
        items.append(e)
        lock.unlock()
    }

    private var waitId = 0

    func next(timeout: TimeInterval) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if !items.isEmpty {
                let e = items.removeFirst()
                lock.unlock()
                c.resume(returning: e)
                return
            }
            waitId += 1
            let mine = waitId
            waiter = c
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                // only this wait's own timeout (a later wait has its own)
                guard self.waitId == mine, let w = self.waiter else { self.lock.unlock(); return }
                self.waiter = nil
                self.lock.unlock()
                w.resume(throwing: Timeout())
            }
        }
    }
}
