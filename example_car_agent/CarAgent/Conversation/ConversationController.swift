import Foundation

// Conversation controller: who owns the microphone between requests, for the settings in ConversationSettings. The same phases, events
// and commands as the other apps (src/conversation/controller.ts, conversation_controller.dart, ConversationController.kt); all of them
// run the scripted flows in conversation_flow.json.
//   off        not in the conversation screen (start-up / the wake-word screen owns the audio)
//   listening  the speech recognizer is open for the user's request
//   busy       a request is being answered (thinking, then the agent speaking)
//   asleep     the recognizer is closed; the wake word (or a tap) opens it again

/// The reply asked something ("Should I open the driver window?"): in the wake-word mode only then does the user get a follow-up turn
/// without the wake word.
func isQuestion(_ reply: String) -> Bool { re("[?？][\"'”’)\\]]*\\s*$").has(reply.trimmed) }

enum ConversationPhase: String {
    case off, listening, busy, asleep
    var id: String { rawValue }
}

/// A timer the controller can cancel.
final class Cancellable {
    private let onCancel: () -> Void
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}

struct ConversationCommands {
    /// Open the speech recognizer (a fresh transcript). preFetchMs: keep that much audio from before it opened.
    var openMic: (_ preFetchMs: Int, _ why: String) -> Void
    /// Close the speech recognizer.
    var closeMic: (_ why: String) -> Void
    /// Wake word detection on.
    var armWakeWord: (_ why: String) -> Void
    /// Wake word detection off (the microphone stays with the app).
    var disarmWakeWord: (_ why: String) -> Void
    /// Stop the agent's reply now: its voice, the sentences still queued, the request.
    var stopReply: (_ why: String) -> Void
    var onPhase: ((ConversationPhase) -> Void)?
    var log: ((String) -> Void)?
    /// Tests pass a fake clock; the app uses dispatch timers.
    var timer: (_ ms: Int, _ fn: @escaping () -> Void) -> Cancellable
    /// Where the commands run, one after another (nil: right away, on the caller's thread: tests).
    var queue: DispatchQueue? = DispatchQueue(label: "ConversationAudio")
}

final class ConversationController {
    private let commands: ConversationCommands
    private var settings: ConversationSettings
    private let lock = NSRecursiveLock()

    private(set) var phase = ConversationPhase.off
    private var speaking = false
    private var duplex = false
    private var wakeArmed = false
    private var timer: Cancellable?

    init(_ commands: ConversationCommands, _ settings: ConversationSettings) {
        self.commands = commands
        self.settings = settings
    }

    private func sync<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    /// In the conversation screen.
    var active: Bool { sync { phase != .off } }

    /// The agent's voice is playing (replySpeaking .. replyFinished).
    var agentSpeaking: Bool { sync { speaking } }

    /// Interrupt mode: the recognizer is open under the agent's voice.
    var duplexOpen: Bool { sync { duplex } }

    var config: ConversationSettings { sync { settings } }

    private enum Window { case listen, followUp, idle }

    /// New settings (the Save button). An open listening window restarts with the new timeout. Asleep in the wake-word mode and
    /// switched to "just talk": the microphone opens (otherwise nothing would ever open it).
    func update(_ s: ConversationSettings) {
        sync {
            let before = settings
            settings = s
            if phase == .asleep && before.wakeWord && !s.wakeWord {
                disarm("just talk")
                run { self.commands.openMic(0, "just talk") }
                setPhase(.listening)
                startWindow(.idle)
            } else if phase == .listening && !before.wakeWord && s.wakeWord {
                sleep("wake word before each request") // from now on every request starts with the wake word
            } else if phase == .listening {
                startWindow(settings.wakeWord ? .listen : .idle)
            }
        }
    }

    /// Just talk: the app has opened the recognizer (and paused the wake word). Wake word before each request: asleep until the wake
    /// word (the app left the recognizer paused; the wake word that opened the screen is not a request).
    func enter() {
        sync {
            clearWindow()
            speaking = false
            duplex = false
            wakeArmed = false
            if settings.wakeWord {
                sleep("wake word before each request")
                return
            }
            setPhase(.listening)
            startWindow(.idle)
        }
    }

    /// Back to the start screen; the app closes the recognizer. rearmWakeWord: the start screen listens for the wake word (the car
    /// agents); false: the wake word goes back to paused, as in the conversation.
    func leave(rearmWakeWord: Bool = true) {
        sync {
            clearWindow()
            speaking = false
            duplex = false
            setPhase(.off)
            if rearmWakeWord { arm("leave") } else { disarm("leave") }
        }
    }

    /// A request was sent (the app closed the recognizer for it).
    func turnStarted() {
        sync {
            if phase == .off { return } // a request outside the conversation screen: not ours
            clearWindow()
            speaking = false
            duplex = false
            setPhase(.busy)
        }
    }

    /// The reply's voice starts. Interrupt mode opens the recognizer under it; the wake-word mode can arm the stop word.
    func replySpeaking() {
        sync {
            if phase != .busy || speaking { return }
            speaking = true
            if settings.interrupt {
                duplex = true
                run { self.commands.openMic(0, "interrupt: listen under the reply") }
            } else if settings.wakeWord && settings.wakeWordMode.stopWord {
                arm("stop word during the reply")
            }
        }
    }

    /// The request ended (its reply was spoken, or it ended without one): the next request, or sleep. reply: what the agent said.
    /// Wake-word mode: the user answers without the wake word only when the reply was a question (and the follow-up window is on);
    /// then recognition pauses and unpauses for a fresh turn. Otherwise back to the wake word.
    func replyFinished(_ reply: String = "") {
        sync {
            if phase != .busy { return }
            let wasDuplex = duplex
            speaking = false
            duplex = false
            if settings.wakeWord {
                let question = isQuestion(reply)
                if settings.wakeWordMode.followUpMs == 0 || !question {
                    sleep(question ? "wake word every time" : "the reply was not a question") // a stop word armed for the reply stays armed
                    return
                }
                disarm("a question: the user answers")
                run { self.commands.closeMic("pause before the answer") }
                run { self.commands.openMic(0, "answer to the question") }
                setPhase(.listening)
                startWindow(.followUp)
                return
            }
            disarm("reply finished")
            // the recognizer open under the reply heard the reply: a fresh session for the user's turn
            if wasDuplex { run { self.commands.closeMic("fresh session after the reply") } }
            run { self.commands.openMic(0, "after the reply") }
            setPhase(.listening)
            startWindow(.idle)
        }
    }

    /// The user said something while listening: the window timeout no longer applies.
    func userSpeech() {
        sync { if phase == .listening { clearWindow() } }
    }

    /// Speech heard while busy. True: the user interrupted the reply (interrupt mode, while the agent speaks, words the agent isn't
    /// saying): the reply was stopped and the words start the user's next request. False: drop them.
    func heardWhileBusy(_ heard: String, _ agentText: String) -> Bool {
        sync {
            if phase != .busy || !duplex || !speaking { return false }
            if resolveBargeIn(heard, agentText) != .interrupt { return false }
            speaking = false
            duplex = false
            commands.log?("[Conversation] the user interrupted: \"\(heard)\"")
            run { self.commands.stopReply("the user interrupted") }
            setPhase(.listening)
            startWindow(settings.wakeWord ? .listen : .idle)
            return true
        }
    }

    /// The wake word was heard. False when the conversation isn't open (the app's own start-up path handles it).
    func wakeWord() -> Bool {
        sync {
            switch phase {
            case .off: return false
            // a stop word while the agent talks; while it is thinking the wake word is ignored
            case .busy: if speaking && wakeArmed { stopAndListen("stop word") }
            case .asleep:
                disarm("wake word")
                let preFetch = settings.wakeWord ? settings.wakeWordMode.preFetchMs : 0
                run { self.commands.openMic(preFetch, "wake word") }
                setPhase(.listening)
                startWindow(settings.wakeWord ? .listen : .idle)
            case .listening: break
            }
            return true
        }
    }

    /// The microphone button: wakes the conversation, or stops the agent and listens.
    func tapToTalk() {
        sync {
            if phase == .asleep {
                disarm("tap")
                run { self.commands.openMic(0, "tap") }
                setPhase(.listening)
                startWindow(settings.wakeWord ? .listen : .idle)
            } else if phase == .busy && speaking {
                stopAndListen("tap")
            }
        }
    }

    private func stopAndListen(_ why: String) {
        let wasDuplex = duplex
        speaking = false
        duplex = false
        run { self.commands.stopReply(why) }
        disarm(why)
        if wasDuplex { run { self.commands.closeMic("fresh session") } }
        // no pre-fetch: the audio before this moment is the agent's voice and the wake word itself
        run { self.commands.openMic(0, "after the \(why)") }
        setPhase(.listening)
        startWindow(settings.wakeWord ? .listen : .idle)
    }

    private func sleep(_ why: String) {
        clearWindow()
        speaking = false
        duplex = false
        run { self.commands.closeMic(why) }
        arm(why)
        setPhase(.asleep)
    }

    private func startWindow(_ kind: Window) {
        clearWindow()
        let ms: Int
        switch kind {
        case .listen: ms = settings.wakeWordMode.listenMs
        case .followUp: ms = settings.wakeWordMode.followUpMs
        case .idle: ms = settings.freeMode.idleMs
        }
        if ms <= 0 { return }
        var me: Cancellable?
        me = commands.timer(ms) { [weak self] in
            guard let self else { return }
            self.sync {
                guard let mine = me, self.timer === mine else { return }
                self.timer = nil
                if self.phase == .listening { self.sleep(kind == .idle ? "nothing said" : "no request") }
            }
        }
        timer = me
    }

    private func clearWindow() {
        timer?.cancel()
        timer = nil
    }

    private func arm(_ why: String) {
        if wakeArmed { return }
        wakeArmed = true
        run { self.commands.armWakeWord(why) }
    }

    private func disarm(_ why: String) {
        if !wakeArmed { return }
        wakeArmed = false
        run { self.commands.disarmWakeWord(why) }
    }

    private func setPhase(_ p: ConversationPhase) {
        if p == phase { return }
        phase = p
        commands.log?("[Conversation] \(p.id)")
        commands.onPhase?(p)
    }

    private func run(_ command: @escaping () -> Void) {
        if let q = commands.queue { q.async(execute: command) } else { command() }
    }

    /// Returns when every command issued so far has run (before a screen change).
    func idle() { commands.queue?.sync {} }
}

// ---- the interrupt rule, the microphone line and the wake phrase (shared fixtures conversation_barge_in.json /
// conversation_wake_phrase.json) --------------------------------------------------------------------------------------------------

enum BargeInDecision: String {
    case interrupt, echo, empty
}

func bargeInWords(_ text: String) -> [String] {
    re("[^\\p{L}\\p{N}']+").replace(text.lowercased(), with: " ").splitSpace().filter { !$0.isEmpty }
}

/// Interrupt mode: a word the agent is not saying can only have come from the user, and one is enough; a window made only of the
/// agent's words is echo leaking past echo cancellation.
func resolveBargeIn(_ heard: String, _ agentText: String) -> BargeInDecision {
    let words = bargeInWords(heard)
    if words.isEmpty { return .empty }
    let agentWords = Set(bargeInWords(agentText))
    return words.allSatisfy { agentWords.contains($0) } ? .echo : .interrupt
}

/// The microphone line: what the conversation is doing now and how to go on.
func conversationHint(_ phase: ConversationPhase, _ wakePhrase: String, _ wakeWord: Bool) -> String {
    switch phase {
    case .asleep: return wakeWord ? "Say “\(wakePhrase)” before each request" : "Say “\(wakePhrase)” or tap to talk"
    case .listening: return wakeWord ? "Listening… say your request" : "Listening… just talk"
    case .busy: return "Answering… tap to stop"
    case .off: return "“\(wakePhrase)” + your command"
    }
}

/// A tap on the microphone line does something (wakes the conversation, or stops the agent).
func conversationTapEnabled(_ phase: ConversationPhase) -> Bool { phase == .asleep || phase == .busy }

/// How speech recognition also writes each wake-phrase word, as word sequences (on the phone: "Hey couch", "A coach", "Hey the voice",
/// "Hey da voice", "Hello voice").
private let soundsLike: [String: [[String]]] = [
    "hey": [["hey"], ["hi"], ["hay"], ["hei"], ["a"], ["okay"], ["ok"]],
    "hello": [["hello"], ["hallo"], ["hullo"], ["hola"], ["allo"], ["hey"], ["hi"]],
    "coach": [["coach"], ["couch"], ["koch"], ["coachs"], ["coaches"]],
    "davoice": [
        ["davoice"], ["da", "voice"], ["the", "voice"], ["de", "voice"], ["devoice"], ["divoice"], ["dvoice"], ["d", "voice"], ["davoices"],
        ["the", "voices"], ["voice"], ["voices"], ["davos"], ["davis"],
    ],
]

/// A first word that counts alone ("Hey, open the window"); "a" or "ok" only count in front of the next word of the phrase.
private let aloneWords = ["hey": ["hey", "hi", "hay", "hei"], "hello": ["hello", "hallo", "hullo"]]

private func wakeNorm(_ w: String) -> String { re("[^\\p{L}\\p{N}]+").replace(w.lowercased(), with: "") }
private func forms(_ phraseWord: String) -> [[String]] { soundsLike[phraseWord] ?? [[phraseWord]] }
private func aloneWord(_ word: String, _ phraseWord: String) -> Bool { (aloneWords[phraseWord] ?? [phraseWord]).contains(wakeNorm(word)) }

/// The transcript without the wake phrase that leads it, so the model never gets it: "Hey DaVoice, open the window" -> "open the
/// window". Also part of the phrase ("DaVoice, lock the car", "The voice, lock the car", "Hey, open the window"), the way recognition
/// mishears it ("Hey the voice", "Hey couch"), and the phrase said twice. Only wake words ("Hey DaVoice.", "The voice", "Hey") -> ""
/// (the request is still to come). Words are compared whole: "Coaching tips", "Heyday", "a car" stay as they are. As the React Native
/// apps' dropWakePhrase (src/conversation/wakePhrase.ts), the same fixture (conversation_wake_phrase.json).
func dropWakePhrase(_ text: String, _ wakePhrase: String) -> String {
    let phrase = re("\\s+").split(wakePhrase).map(wakeNorm).filter { !$0.isEmpty }
    let words = re("[\\p{L}\\p{N}']+").findAll(text)
    if words.isEmpty { return "" }
    if phrase.isEmpty { return text.trimmed }
    let normalized = words.map { wakeNorm($0.value) }
    var at = 0 // words consumed
    var round = 0
    while round < 3 && at < words.count {
        let taken = leadingPhrase(Array(normalized[at...]), phrase)
        if taken == 0 { break }
        at += taken
        round += 1
    }
    if at == 0 { return text.trimmed }
    if at >= words.count { return "" }
    return re("^[\\s,.!?;:'\"“”‘’-]+").replace(String(text[words[at - 1].range.upperBound...]), with: "").trimmed
}

/// How many words phrase[from...] takes at the start of words (each phrase word in one of its forms), or -1. Longest first.
private func matchFrom(_ words: [String], _ phrase: [String], _ from: Int, _ at: Int = 0) -> Int {
    if from == phrase.count { return at }
    var best = -1
    for form in forms(phrase[from]) {
        let fits = at + form.count <= words.count && form.indices.allSatisfy { words[at + $0] == form[$0] }
        if fits { best = max(best, matchFrom(words, phrase, from + 1, at + form.count)) }
    }
    return best
}

/// How many leading words are the wake phrase: all of it, its end ("davoice", "the voice"), or its first word alone ("hey").
private func leadingPhrase(_ words: [String], _ phrase: [String]) -> Int {
    for start in phrase.indices {
        let taken = matchFrom(words, phrase, start)
        if taken > 0 { return taken }
    }
    if phrase.count > 1 && aloneWord(words[0], phrase[0]) { return 1 }
    return 0
}
