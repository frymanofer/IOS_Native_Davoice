import XCTest
@testable import CarAgent

// Every case of the fixtures shared with the React Native, Flutter and Android car apps: all four apps must decide and say the same thing.
final class SharedFixturesTests: XCTestCase {
    override func setUpWithError() throws { try TestSupport.load() }

    func testFixturesAreTheReactNativeAppsCopies() throws {
        for name in ["follow_up.json", "state_answers.json", "car_dialogs.json", "media_query.json", "spoken_say.json", "basic_hints.json",
                     "conversation_flow.json", "conversation_barge_in.json", "conversation_wake_phrase.json"] {
            guard let rn = TestSupport.rnFixture(name) else { continue }
            XCTAssertEqual(rn, try TestSupport.fixtureText(name), name)
        }
    }

    func testFollowUps() throws {
        var diffs: [String] = []
        for c in asList(try TestSupport.fixture("follow_up.json")).map({ asObj($0) }) {
            FollowUp.reset()
            BasicLanguage.clearPending()
            let lang = str(c["lang"])
            if let before = c["before"]?.object { FollowUp.noteCarReply(str(before["sent"]), str(before["reply"]), lang) }
            let offer = c["offer"]?.array?.map { str($0) }
            let got = FollowUp.carTurnInput(str(c["user"]), lang, offer, musicOn: asObj(c["car"])["musicOn"] == true)
            let want = asObj(c["expect"])
            if !turnMatches(got, want) { diffs.append("\(lang) \"\(str(c["user"]))\": got \(got.text ?? got.reply ?? "nil"), want \(str(want["text"] ?? want["reply"]))") }
        }
        XCTAssertEqual([], diffs)
    }

    func testQuestionsAboutTheCar() throws {
        var diffs: [String] = []
        for c in asList(try TestSupport.fixture("state_answers.json")).map({ asObj($0) }) {
            let got = StateAnswers.answer(str(c["user"]), str(c["lang"]), TestSupport.carWith(asObj(c["state"])))
            let want = c["expect"]?.object
            let ok = want == nil ? got == nil : got != nil && got!.reply == want!["reply"]?.string && got!.offer == want!["offer"]?.string
            if !ok { diffs.append("\(str(c["lang"])) \"\(str(c["user"]))\": got \(got?.reply ?? "nil") / \(got?.offer ?? "nil"), want \(str(want?["reply"])) / \(str(want?["offer"]))") }
        }
        XCTAssertEqual([], diffs)
    }

    func testConversationsAboutTheCar() throws {
        var diffs: [String] = []
        for d in asList(try TestSupport.fixture("car_dialogs.json")).map({ asObj($0) }) {
            FollowUp.reset()
            BasicLanguage.clearPending()
            let lang = str(d["lang"])
            let state = TestSupport.carWith(asObj(d["state"]))
            let flags = asObj(d["car"])
            for s in asList(d["steps"]).map({ asObj($0) }) {
                let got = FollowUp.carTurnInput(str(s["user"]), lang, nil, musicOn: flags["musicOn"] == true, state: state, lastActed: flags["lastActed"]?.bool)
                let want = asObj(s["expect"])
                if !turnMatches(got, want) { diffs.append("\(lang) \"\(str(s["user"]))\": got \(got.text ?? got.reply ?? "nil"), want \(str(want["text"] ?? want["reply"]))") }
                FollowUp.noteCarSpoken(got.reply ?? str(s["heard"] ?? ""))
            }
        }
        XCTAssertEqual([], diffs)
    }

    func testMediaTitles() throws {
        let diffs = asList(try TestSupport.fixture("media_query.json")).map { asObj($0) }.compactMap { c -> String? in
            let got = groundMediaQuery(str(c["query"]), str(c["user"]))
            return got != c["expect"]?.string ? "\"\(str(c["user"]))\" + \"\(str(c["query"]))\": got \(got), want \(str(c["expect"]))" : nil
        }
        XCTAssertEqual([], diffs)
    }

    func testHowAToolSentenceIsSaid() throws {
        let diffs = asList(try TestSupport.fixture("spoken_say.json")).map { asList($0) }.compactMap { c -> String? in
            let got = SpeechComposer.spokenSay(CarTurnAction(tool: str(c[1]), say: str(c[2]), merge: true, args: asObj(c[3])), str(c[0]))
            return got != c[4].string ? "\(str(c[0])) \(str(c[2])) -> \(got) (want \(str(c[4])))" : nil
        }
        XCTAssertEqual([], diffs)
    }

    func testEnglishHintsForTheBasicLanguages() throws {
        let diffs = asList(try TestSupport.fixture("basic_hints.json")).map { asList($0) }.compactMap { f -> String? in
            let got = BasicLanguage.withCarHints(str(f[1]), str(f[0]))
            return got != f[2].string ? "\(str(f[0])) \"\(str(f[1]))\": got \(got), want \(str(f[2]))" : nil
        }
        XCTAssertEqual([], diffs)
    }
}

// Words that cannot end a request wait longer (Flow/EndOfSpeech.swift), and "Lock the sunroof" is offered as closing it
// (Car/FollowUp.swift). The same cases as the React Native app's endOfSpeech.test.ts and followUp.test.ts.
final class EndOfSpeechTests: XCTestCase {
    override func setUpWithError() throws { try TestSupport.load() }

    func testUnfinishedFragmentsThatWereSentTooEarly() {
        for t in ["Look at", "Please", "Yeah, it's", "Set the", "Can you", "Open", "Set the heat of the", "Turn on", "Open all the doors and"] {
            XCTAssertTrue(looksUnfinished(t, "en"), t)
        }
        for t in ["Fecha a", "Você pode", "Abre", "Coloca o volume em", "Por favor"] { XCTAssertTrue(looksUnfinished(t, "pt-BR"), t) }
    }

    func testFinishedRequestsKeepTheNormalSilence() {
        for t in ["Open the sunroof", "Yes", "Yes please", "Stop", "No", "Close it please", "Set the fan to five", "Thank you", "Lock the car", "What's that"] {
            XCTAssertFalse(looksUnfinished(t, "en"), t)
        }
        for t in ["Fecha a janela, por favor", "Sim", "Pode", "Liga o ar", "Tranca o carro"] { XCTAssertFalse(looksUnfinished(t, "pt-BR"), t) }
        XCTAssertFalse(looksUnfinished("Mach das", "de"))
        XCTAssertEqual(1500 + unfinishedExtraMs, silenceFor("Set the", 1500, "en"))
        XCTAssertEqual(1500, silenceFor("Open the window", 1500, "en"))
    }

    func testLockTheSunroofIsOfferedAsClosingIt() {
        FollowUp.reset()
        XCTAssertEqual("I can't lock the sunroof, but I can close it. Want me to close it?", FollowUp.carTurnInput("Can you lock the sunroof?", "en", nil).reply)
        XCTAssertEqual("Close the sunroof", FollowUp.carTurnInput("Yes", "en", nil).text)
        FollowUp.reset()
        _ = FollowUp.carTurnInput("Lock the sunroof", "en", nil)
        XCTAssertEqual("Close the sunroof", FollowUp.carTurnInput("Close it", "en", nil).text)
        FollowUp.reset()
        _ = FollowUp.carTurnInput("Unlock the windows", "en", nil)
        XCTAssertEqual("Okay.", FollowUp.carTurnInput("No", "en", nil).reply)
        FollowUp.reset()
        _ = FollowUp.carTurnInput("Tranca o teto solar", "pt-BR", nil)
        XCTAssertEqual("Fecha o teto solar", FollowUp.carTurnInput("Sim", "pt-BR", nil).text)
        FollowUp.reset()
        _ = FollowUp.carTurnInput("Destranca os vidros", "pt-BR", nil)
        XCTAssertEqual("Abre todos os vidros", FollowUp.carTurnInput("Pode abrir", "pt-BR", nil).text)
    }
}
