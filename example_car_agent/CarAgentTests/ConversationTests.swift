import XCTest
@testable import CarAgent

// Conversation modes: the settings, the interrupt rule, the wake phrase and the controller's scripted flows, on the fixtures shared with
// the React Native, Flutter and Android apps (conversation_*.json).
final class ConversationTests: XCTestCase {
    override func setUpWithError() throws { try TestSupport.load() }

    private func merge(_ base: JSON?, _ patch: JSON?) -> JSON? {
        guard case .obj(let p)? = patch else { return patch ?? base }
        var out = asObj(base)
        for (k, v) in p { out[k] = v.object != nil ? merge(out[k], v) : v }
        return .obj(out)
    }

    private final class FakeClock {
        var now = 0
        private var timers: [(at: Int, fn: () -> Void, alive: Box)] = []
        final class Box { var alive = true }

        func make(_ ms: Int, _ fn: @escaping () -> Void) -> Cancellable {
            let box = Box()
            timers.append((now + ms, fn, box))
            return Cancellable { box.alive = false }
        }

        func advance(_ ms: Int) {
            let end = now + ms
            while let next = timers.filter({ $0.alive.alive && $0.at <= end }).min(by: { $0.at < $1.at }) {
                next.alive.alive = false
                now = next.at
                next.fn()
            }
            now = end
        }
    }

    func testDefaultsKeepTodaysBehaviour() throws {
        XCTAssertEqual(
            try Json.parse("{\"interrupt\":false,\"wakeWord\":false,\"wakeWordMode\":{\"endOfSpeechMs\":1500,\"listenMs\":8000,\"followUpMs\":8000,\"preFetchMs\":2000,\"stopWord\":false},\"freeMode\":{\"endOfSpeechMs\":1500,\"idleMs\":0}}"),
            .obj(defaultConversationSettings.json))
        XCTAssertEqual("Just talk · take turns", defaultConversationSettings.description)
    }

    func testNormalizeFillsClampsAndDropsWhatItDoesNotKnow() throws {
        XCTAssertEqual(defaultConversationSettings, normalizeConversationSettings(nil))
        let s = normalizeConversationSettings(try Json.parse("{\"interrupt\":true,\"wakeWord\":\"yes\",\"extra\":1,\"wakeWordMode\":{\"endOfSpeechMs\":50,\"followUpMs\":-5,\"preFetchMs\":99999,\"listenMs\":7000.4,\"stopWord\":false},\"freeMode\":{\"idleMs\":\"x\"}}"))
        XCTAssertEqual(
            try Json.parse("{\"interrupt\":true,\"wakeWord\":false,\"wakeWordMode\":{\"endOfSpeechMs\":500,\"listenMs\":7000,\"followUpMs\":0,\"preFetchMs\":3000,\"stopWord\":false},\"freeMode\":{\"endOfSpeechMs\":1500,\"idleMs\":0}}"),
            .obj(s.json))
    }

    func testInterruptingTurnsEchoCancellationOn() {
        let base: JObj = ["default": ["mode": "default"], "WakewordAEC": ["regular": false, "duringTTS": false]]
        XCTAssertEqual(base, routingConfigForConversation(base, defaultConversationSettings))
        var interrupt = defaultConversationSettings
        interrupt.interrupt = true
        let on = routingConfigForConversation(base, interrupt)
        XCTAssertEqual(["mode": "always"], on["AEC"])
        XCTAssertEqual(["regular": true, "duringTTS": true], on["WakewordAEC"])
    }

    func testInterruptRule() throws {
        for c in asList(try TestSupport.fixture("conversation_barge_in.json")).map({ asObj($0) }) {
            XCTAssertEqual(str(c["decision"]), resolveBargeIn(str(c["heard"]), str(c["agent"])).rawValue, "\"\(str(c["heard"]))\"")
        }
        XCTAssertEqual(.empty, resolveBargeIn("", "x"))
    }

    func testWakePhrase() throws {
        for c in asList(try TestSupport.fixture("conversation_wake_phrase.json")).map({ asObj($0) }) {
            XCTAssertEqual(str(c["out"]), dropWakePhrase(str(c["text"]), str(c["phrase"])), "\"\(str(c["text"]))\"")
        }
    }

    func testMicrophoneLine() {
        XCTAssertEqual("Say “Hey Coach” before each request", conversationHint(.asleep, "Hey Coach", true))
        XCTAssertEqual("Say “Hey Coach” or tap to talk", conversationHint(.asleep, "Hey Coach", false))
        XCTAssertEqual("Listening… just talk", conversationHint(.listening, "Hey Coach", false))
    }

    func testControllerFlows() throws {
        for flow in asList(try TestSupport.fixture("conversation_flow.json")).map({ asObj($0) }) {
            let name = str(flow["name"])
            let clock = FakeClock()
            var log: [String] = []
            var settings = normalizeConversationSettings(merge(.obj(defaultConversationSettings.json), flow["settings"]))
            let c = ConversationController(
                ConversationCommands(
                    openMic: { ms, _ in log.append("openMic:\(ms)") },
                    closeMic: { _ in log.append("closeMic") },
                    armWakeWord: { _ in log.append("armWakeWord") },
                    disarmWakeWord: { _ in log.append("disarmWakeWord") },
                    stopReply: { _ in log.append("stopReply") },
                    timer: { ms, fn in clock.make(ms, fn) },
                    queue: nil),
                settings)
            for (i, step) in asList(flow["steps"]).map({ asObj($0) }).enumerated() {
                let at = "\(name) / step \(i) (\(str(step["do"])))"
                let before = log.count
                var returned: Bool?
                switch str(step["do"]) {
                case "enter": c.enter()
                case "leave": c.leave(rearmWakeWord: step["rearm"]?.bool ?? true)
                case "turnStarted": c.turnStarted()
                case "replySpeaking": c.replySpeaking()
                case "replyFinished": c.replyFinished(step["reply"].map { str($0) } ?? "")
                case "userSpeech": c.userSpeech()
                case "tapToTalk": c.tapToTalk()
                case "wakeWord": returned = c.wakeWord()
                case "heard": returned = c.heardWhileBusy(str(step["text"]), str(step["agent"]))
                case "wait": clock.advance(Int(step["ms"]?.double ?? 0))
                case "update":
                    settings = normalizeConversationSettings(merge(.obj(settings.json), step["settings"]))
                    c.update(settings)
                default: XCTFail("unknown step \(str(step["do"]))")
                }
                if step.has("returns") { XCTAssertEqual(step["returns"]?.bool, returned, at) }
                if step.has("log") { XCTAssertEqual(asList(step["log"]).map { str($0) }, Array(log[before...]), at) }
                if step.has("phase") { XCTAssertEqual(str(step["phase"]), c.phase.id, at) }
            }
        }
    }

    func testAReplyThatAsksAQuestionIsAnsweredWithoutTheWakeWord() {
        XCTAssertTrue(isQuestion("Should I open the passenger window too?"))
        XCTAssertTrue(isQuestion("Quer que eu abra o vidro do carona? "))
        XCTAssertTrue(isQuestion("Did you say “the trunk?”"))
        XCTAssertFalse(isQuestion("I opened the driver window."))
        XCTAssertFalse(isQuestion("Why? Because it was cold."))
        XCTAssertFalse(isQuestion(""))
    }
}
