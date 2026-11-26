import Foundation

// The app's languages (the same list, order and texts as the React Native, Flutter and Android example_car_agent).

/// One language of the language screen: STT locale, the agent's reply instruction, and whether it is offered.
struct AppLanguageInfo {
    let id: String
    let label: String
    let sttLocale: String
    let llmReplyInstruction: String
    var hidden = false
}

let appLanguageInfos: [AppLanguageInfo] = [
    // Order: English, then Brazilian Portuguese (the two tuned languages); then by voice quality: Spanish, Italian, German, Dutch; Greek,
    // Swedish, Danish; French, European Portuguese. Hebrew is hidden.
    AppLanguageInfo(id: "en", label: "English", sttLocale: "en-US", llmReplyInstruction: "The user speaks English. Always reply in English."),
    AppLanguageInfo(id: "pt-BR", label: "Português do Brasil (Brazilian Portuguese)", sttLocale: "pt-BR",
                    llmReplyInstruction: "Important: always reply in Brazilian Portuguese (pt-BR). Sempre responda em português do Brasil."),
    AppLanguageInfo(id: "es", label: "Español (Spanish)", sttLocale: "es-ES", llmReplyInstruction: "The user speaks Spanish. Always reply in Spanish."),
    AppLanguageInfo(id: "it", label: "Italiano (Italian)", sttLocale: "it-IT", llmReplyInstruction: "The user speaks Italian. Always reply in Italian."),
    AppLanguageInfo(id: "de", label: "Deutsch (German)", sttLocale: "de-DE", llmReplyInstruction: "The user speaks German. Always reply in German."),
    AppLanguageInfo(id: "nl", label: "Nederlands (Dutch)", sttLocale: "nl-NL", llmReplyInstruction: "The user speaks Dutch. Always reply in Dutch."),
    AppLanguageInfo(id: "el", label: "Ελληνικά (Greek)", sttLocale: "el-GR",
                    llmReplyInstruction: "The user speaks Greek. Always reply in Greek. Απάντα πάντα στα ελληνικά."),
    AppLanguageInfo(id: "sv", label: "Svenska (Swedish)", sttLocale: "sv-SE",
                    llmReplyInstruction: "The user speaks Swedish. Always reply in Swedish. Svara alltid på svenska."),
    AppLanguageInfo(id: "da", label: "Dansk (Danish)", sttLocale: "da-DK",
                    llmReplyInstruction: "The user speaks Danish. Always reply in Danish. Svar altid på dansk."),
    AppLanguageInfo(id: "fr", label: "Français (French)", sttLocale: "fr-FR", llmReplyInstruction: "The user speaks French. Always reply in French."),
    AppLanguageInfo(id: "pt-PT", label: "Português de Portugal (European Portuguese)", sttLocale: "pt-PT",
                    llmReplyInstruction: "Important: always reply in European Portuguese (pt-PT), never Brazilian Portuguese. Responde sempre em português de Portugal."),
    AppLanguageInfo(id: "he", label: "עברית (Hebrew)", sttLocale: "he-IL",
                    llmReplyInstruction: "The user speaks Hebrew. Always reply in Hebrew. ענה תמיד בעברית.", hidden: true),
]

let appLanguages = appLanguageInfos.map(\.id)

/// A TTS v1 model's own voice (named after the language): no voice conversion, so much faster. The language's default voice.
let originalTtsVoices = ["da": "Mads", "sv": "Erik", "el": "Eleni"]

enum AppLanguage {
    private static let lock = NSLock()
    private static var value = "en"

    /// The app's language (an id of appLanguageInfos).
    static var current: String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    static func set(_ language: String) {
        lock.lock()
        value = appLanguages.contains(language) ? language : "en"
        lock.unlock()
    }

    /// Portuguese (Brazil or Portugal).
    static var isPortuguese: Bool { current == "pt-BR" || current == "pt-PT" }
}

func appLanguageInfo(_ language: String) -> AppLanguageInfo {
    appLanguageInfos.first { $0.id == language } ?? appLanguageInfos[0]
}

/// The system-prompt line that sets the agent's reply language.
func llmReplyInstructionFor(_ language: String) -> String { appLanguageInfo(language).llmReplyInstruction }
