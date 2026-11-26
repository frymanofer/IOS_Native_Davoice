import Foundation
import os

// Who spoke the user's current request, for actions only the car's owner may do (unlock_car, open_door: tool authorization scope
// "door_locks"). The speech library reports the verified speakers of a sentence in its results when speaker verification is on; the app
// records them per request and clears them after each turn. With speaker verification on, the enrolled owner's voice must be in the
// request. With it skipped there is no way to tell voices apart: the demo allows it (logged), so the doors work without enrollment.

enum CurrentSpeaker {
    private static let lock = NSLock()
    private static var gateOn = false
    private static var ownerId: String?
    private static var heard = Set<String>()
    private static let log = Logger(subsystem: "io.davoice.caragent", category: "SVGate")

    /// Called when speaker verification is applied (enrolled or skipped).
    static func setGate(_ enabled: Bool, _ enrolledOwnerId: String?) {
        lock.lock()
        gateOn = enabled && enrolledOwnerId != nil
        ownerId = enrolledOwnerId
        heard.removeAll()
        let on = gateOn
        lock.unlock()
        log.info("\(on ? "on: owner \"\(enrolledOwnerId ?? "")\"" : "off: speaker verification skipped", privacy: .public)")
    }

    /// Every STT partial and final result.
    static func noteResult(_ speakerIds: [String], _ speakerId: String?) {
        lock.lock()
        heard.formUnion(speakerIds)
        if let s = speakerId { heard.insert(s) }
        lock.unlock()
    }

    /// After a turn: the next request starts with nobody heard.
    static func clearHeard() {
        lock.lock()
        heard.removeAll()
        lock.unlock()
    }

    /// May the current request do an owner-only action? (allowed, why)
    static func ownerMayAct() -> (Bool, String) {
        lock.lock()
        defer { lock.unlock() }
        if !gateOn { return (true, "speaker verification is off (demo allows it)") }
        if let owner = ownerId, heard.contains(owner) { return (true, "owner \"\(owner)\" verified") }
        return (false, heard.isEmpty ? "no verified speaker in this request" : "heard \(heard.sorted().joined(separator: ", ")), not the owner")
    }
}
