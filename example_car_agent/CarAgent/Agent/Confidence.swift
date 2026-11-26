import Foundation

// Local confidence (agent core configure "confidence"): an application-developer choice, adjustable at runtime. The on-device model's
// tool call carries a score (the product of the probabilities of the tokens it wrote). With the filter ON, a call scoring below the
// threshold does not run, and the fallback decides what happens instead (clarify: the user is asked to say it again; remote: the request
// goes to the text-only remote assistant; decline: the user hears that nothing was changed). With the filter OFF the threshold is
// ignored. Either way the core's deterministic checks still apply. The score is model-derived, NOT a guaranteed probability of being
// right. Same behaviour as the React Native, Flutter and Android apps.

let confidenceFallbacks = ["clarify", "remote", "decline"]
let confidenceFallbackLabels = ["clarify": "Clarify", "remote": "Remote", "decline": "Decline"]
let confidenceFallbackDetails = [
    "clarify": "ask the driver to say it again",
    "remote": "text-only answer, never a car action",
    "decline": "say nothing was changed",
]
let confidenceStep = 0.05

struct ConfidenceSettings: Equatable {
    var enabled = false
    var threshold = 0.9
    var fallback = "clarify"

    var json: JObj { ["enabled": JSON(enabled), "threshold": JSON(threshold), "fallback": JSON(fallback)] }

    static let defaults = ConfidenceSettings()

    static func parse(_ raw: JSON?) -> ConfidenceSettings {
        guard let r = raw?.object else { return defaults }
        return ConfidenceSettings(
            enabled: r["enabled"] == true,
            threshold: r["threshold"]?.double.map(snapThreshold) ?? defaults.threshold,
            fallback: confidenceFallbacks.contains(str(r["fallback"])) ? str(r["fallback"]) : defaults.fallback)
    }
}

/// Rounds to the 0.05 grid and clamps to 0..1 (no float noise: 0.9 stays 0.9).
func snapThreshold(_ value: Double) -> Double {
    if value.isNaN || value.isInfinite { return ConfidenceSettings.defaults.threshold }
    let v = min(1, max(0, value))
    return (v / confidenceStep).rounded() * 5 / 100
}

/// "0.90 / 90%"
func formatThreshold(_ value: Double) -> String {
    let v = snapThreshold(value)
    return "\(String(format: "%.2f", v)) / \(Int((v * 100).rounded()))%"
}

private let confidenceMessages: [String: [(String, String)]] = [
    "en": [
        ("clarify", "I'm not sure I understood that. Could you say it again in other words?"),
        ("decline", "I'm not sure enough about that one, so I didn't change anything."),
        ("noRemote", "I'm not sure enough to do that here, and no remote assistant is set up, so I didn't change anything."),
    ],
    "pt-BR": [
        ("clarify", "Não tenho certeza se entendi. Pode repetir de outro jeito?"),
        ("decline", "Não tenho certeza suficiente sobre esse comando, então não mudei nada."),
        ("noRemote", "Não tenho certeza suficiente para fazer isso aqui e não há um assistente remoto configurado, então não mudei nada."),
    ],
]

/// What the agent core gets (configure {"confidence": ...}); the threshold is sent even when OFF, so switching ON restores it.
func toCoreConfidence(_ s: ConfidenceSettings, _ language: String) -> JObj {
    let basicKey = ["clarify": "lowClarify", "decline": "lowDecline", "noRemote": "lowNoRemote"]
    let base = language.lowercased().hasPrefix("pt") ? confidenceMessages["pt-BR"]! : confidenceMessages["en"]!
    // Basic languages have their own sentences
    let messages = JObj(base.map { k, v in (k, JSON(BasicLanguage.message(language, basicKey[k]!) ?? v)) })
    return ["enabled": JSON(s.enabled), "min": JSON(snapThreshold(s.threshold)), "fallback": JSON(s.fallback), "messages": .obj(messages)]
}

let outcomeLabels = [
    "executed": "Executed",
    "clarified": "Clarified",
    "declined": "Declined",
    "remote": "Routed to remote",
    "ignored": "Ignored",
    "answered": "Answered",
]

/// What happened to a request and the model's score for its action (core result "outcome" / "confidence").
struct TurnInfo: Equatable {
    var outcome: String?
    var value: Double?
    var low = false
    var unavailable = false
    var measured = false

    /// "Model score 0.93 (93%)" / "Model score unavailable" / ""
    var score: String {
        if !measured { return "" }
        guard let v = value else { return unavailable ? "Model score unavailable" : "" }
        return "Model score \(String(format: "%.2f", v)) (\(Int((v * 100).rounded()))%)"
    }

    static func read(_ json: JObj) -> TurnInfo {
        let o = str(json["outcome"])
        let outcome = outcomeLabels[o] != nil ? o : nil
        if let c = json["confidence"]?.object {
            return TurnInfo(outcome: outcome, value: c["value"]?.double, low: c["low"] == true, unavailable: c["unavailable"] == true, measured: true)
        }
        return TurnInfo(outcome: outcome)
    }
}
