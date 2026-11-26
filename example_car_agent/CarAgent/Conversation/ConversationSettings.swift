import Foundation

// Conversation mode settings (the settings sheet): how the user and the agent take turns. The same JSON shape and rules as the other
// apps (src/conversation/settings.ts, conversation_settings.dart, ConversationSettings.kt).
//  - interrupt: false = take turns (the microphone is closed while the agent answers), true = the user can talk over the agent. It keeps
//    the microphone open under the agent's voice, so it turns echo cancellation (AEC) on.
//  - wakeWord: true = each request starts with the wake word (a short window after a reply lets a follow-up through without it),
//    false = just talk: the microphone stays open between requests.
//  - Each mode has its own timeouts; the wake-word mode can keep the audio from just before the recognizer opened (preFetchMs).

struct WakeWordModeSettings: Equatable {
    /// Silence that ends the user's request (ms).
    var endOfSpeechMs: Int
    /// After the wake word (or a tap), how long to wait for the first words before going back to the wake word (ms).
    var listenMs: Int
    /// After a reply, how long to keep listening for a follow-up without the wake word (ms). 0 = the wake word every time.
    var followUpMs: Int
    /// Audio kept from just before the recognizer opened after the wake word (ms). 0 = off.
    var preFetchMs: Int
    /// The wake word said while the agent is talking stops it and opens a new request.
    var stopWord: Bool

    var json: JObj {
        ["endOfSpeechMs": JSON(endOfSpeechMs), "listenMs": JSON(listenMs), "followUpMs": JSON(followUpMs), "preFetchMs": JSON(preFetchMs),
         "stopWord": JSON(stopWord)]
    }
}

struct FreeModeSettings: Equatable {
    /// Silence that ends the user's request (ms).
    var endOfSpeechMs: Int
    /// With nothing said for this long, the microphone closes until the wake word or a tap (ms). 0 = never.
    var idleMs: Int

    var json: JObj { ["endOfSpeechMs": JSON(endOfSpeechMs), "idleMs": JSON(idleMs)] }
}

struct ConversationSettings: Equatable {
    var interrupt: Bool
    var wakeWord: Bool
    var wakeWordMode: WakeWordModeSettings
    var freeMode: FreeModeSettings

    var json: JObj {
        ["interrupt": JSON(interrupt), "wakeWord": JSON(wakeWord), "wakeWordMode": .obj(wakeWordMode.json), "freeMode": .obj(freeMode.json)]
    }

    /// The silence that ends a request in the selected mode.
    var endOfSpeechMs: Int { wakeWord ? wakeWordMode.endOfSpeechMs : freeMode.endOfSpeechMs }

    /// One line for the settings row ("Wake word · take turns").
    var description: String { "\(wakeWord ? "Wake word" : "Just talk") · \(interrupt ? "interrupt anytime" : "take turns")" }
}

/// Today's behaviour: take turns; after the first wake word the microphone stays open (no wake word).
let defaultConversationSettings = ConversationSettings(
    interrupt: false,
    wakeWord: false,
    wakeWordMode: WakeWordModeSettings(endOfSpeechMs: 1500, listenMs: 8000, followUpMs: 8000, preFetchMs: 2000, stopWord: false),
    freeMode: FreeModeSettings(endOfSpeechMs: 1500, idleMs: 0))

struct Choice: Hashable {
    let value: Int
    let label: String
}

let endOfSpeechChoices = [Choice(value: 1000, label: "1 s"), Choice(value: 1500, label: "1.5 s"), Choice(value: 2000, label: "2 s"),
                          Choice(value: 2500, label: "2.5 s"), Choice(value: 3000, label: "3 s")]
let listenChoices = [Choice(value: 4000, label: "4 s"), Choice(value: 6000, label: "6 s"), Choice(value: 8000, label: "8 s"),
                     Choice(value: 10000, label: "10 s"), Choice(value: 15000, label: "15 s")]
let followUpChoices = [Choice(value: 0, label: "Off"), Choice(value: 5000, label: "5 s"), Choice(value: 8000, label: "8 s"),
                       Choice(value: 15000, label: "15 s"), Choice(value: 30000, label: "30 s")]
let preFetchChoices = [Choice(value: 0, label: "Off"), Choice(value: 500, label: "0.5 s"), Choice(value: 1000, label: "1 s"),
                       Choice(value: 2000, label: "2 s"), Choice(value: 3000, label: "3 s")]
let idleChoices = [Choice(value: 0, label: "Never"), Choice(value: 15000, label: "15 s"), Choice(value: 30000, label: "30 s"),
                   Choice(value: 60000, label: "1 min"), Choice(value: 120000, label: "2 min")]

private func settingNum(_ v: JSON?, _ fallback: Int, _ min: Int, _ max: Int) -> Int {
    var n = fallback
    if case .num(let d)? = v, !d.isNaN, !d.isInfinite { n = Int(d.rounded()) }
    return Swift.min(max, Swift.max(min, n))
}

private func settingBool(_ v: JSON?, _ fallback: Bool) -> Bool { v?.bool ?? fallback }

/// Any stored or edited value -> complete, in-range settings (unknown keys dropped, missing ones defaulted).
func normalizeConversationSettings(_ raw: JSON?) -> ConversationSettings {
    let d = defaultConversationSettings
    let r = asObj(raw)
    let w = asObj(r["wakeWordMode"])
    let f = asObj(r["freeMode"])
    return ConversationSettings(
        interrupt: settingBool(r["interrupt"], d.interrupt),
        wakeWord: settingBool(r["wakeWord"], d.wakeWord),
        wakeWordMode: WakeWordModeSettings(
            endOfSpeechMs: settingNum(w["endOfSpeechMs"], d.wakeWordMode.endOfSpeechMs, 500, 6000),
            listenMs: settingNum(w["listenMs"], d.wakeWordMode.listenMs, 2000, 60000),
            followUpMs: settingNum(w["followUpMs"], d.wakeWordMode.followUpMs, 0, 120000),
            preFetchMs: settingNum(w["preFetchMs"], d.wakeWordMode.preFetchMs, 0, 3000),
            stopWord: settingBool(w["stopWord"], d.wakeWordMode.stopWord)),
        freeMode: FreeModeSettings(
            endOfSpeechMs: settingNum(f["endOfSpeechMs"], d.freeMode.endOfSpeechMs, 500, 6000),
            idleMs: settingNum(f["idleMs"], d.freeMode.idleMs, 0, 600000)))
}

/// The routing JSON (wake word, STT and TTS) for these settings: echo cancellation on for every listener when the user can interrupt,
/// and unchanged otherwise (as the other apps' routingConfigForConversation).
func routingConfigForConversation(_ base: JObj, _ s: ConversationSettings) -> JObj {
    if !s.interrupt { return base }
    return base + ["AEC": ["mode": "always"], "WakewordAEC": ["regular": true, "duringTTS": true]]
}
