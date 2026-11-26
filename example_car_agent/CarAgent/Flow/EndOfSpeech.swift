import Foundation

// When a pause ends the driver's request (2026-11-25 iPhone log: "Look at", "Please", "Yeah, it's" were sent after the end-of-speech
// silence while the driver was still talking). Words that cannot end a request ("Set the", "Open", "Can you", "Please") get a longer
// pause before they are sent. The same rule as the React Native car agent (src/stt/endOfSpeech.ts) and the Android app.

/// Extra wait when the words so far cannot end a request (ms).
let unfinishedExtraMs = 2000

private struct EndWords {
    let last: Set<String>
    let lastTwo: Set<String>
    let alone: Set<String>
    let english: Bool
}

private let endWordsEN = EndWords(
    last: ["the", "a", "an", "to", "at", "of", "on", "in", "into", "onto", "for", "with", "from", "by", "about", "and", "or", "but",
           "my", "your", "our", "their", "his", "her", "its", "is", "are", "was", "can", "could", "would", "will", "should", "please", "than"],
    lastTwo: ["can you", "could you", "would you", "will you", "it s", "that s", "there s", "i want", "i d like", "i would like",
              "set the", "turn the", "turn on", "turn off", "turn up", "turn down"],
    alone: ["open", "close", "shut", "set", "turn", "put", "make", "play", "lock", "unlock", "raise", "lower", "increase", "decrease",
            "navigate", "take", "find", "switch", "tune", "change", "hey", "so", "um", "uh", "and"],
    english: true)

private let endWordsPT = EndWords(
    last: ["o", "a", "os", "as", "de", "do", "da", "dos", "das", "no", "na", "nos", "nas", "em", "para", "pra", "pro", "por", "com",
           "e", "ou", "mas", "um", "uma", "meu", "minha", "seu", "sua", "que", "ao", "pelo", "pela"],
    lastTwo: ["voce pode", "vc pode", "por favor", "eu quero", "eu queria", "liga o", "liga a"],
    alone: ["abre", "fecha", "coloca", "poe", "bota", "aumenta", "diminui", "abaixa", "baixa", "sobe", "toca", "muda", "troca",
            "tranca", "destranca", "navega", "leva", "ei", "entao", "e"],
    english: false)

/// The words so far cannot end a request ("Set the", "Can you", "Please"). Languages other than English / Portuguese: never.
func looksUnfinished(_ text: String, _ language: String) -> Bool {
    let words = BasicLanguage.fold(text).splitSpace().filter { !$0.isEmpty }
    guard let last = words.last else { return false }
    let set: EndWords
    if language == "en" { set = endWordsEN } else if language.hasPrefix("pt") { set = endWordsPT } else { return false }
    if words.count == 1 && (set.alone.contains(last) || (set.english && last == "please")) { return true }
    if words.count >= 2 && set.lastTwo.contains("\(words[words.count - 2]) \(last)") {
        // "por favor" ends many requests ("Fecha a janela, por favor"): unfinished only when it is all that was said
        return !(!set.english && last == "favor" && words.count > 2)
    }
    if last == "please" { return false } // "yes please" / "close it please"
    return set.last.contains(last)
}

/// The silence that ends this request: the end-of-speech setting, longer when the words so far cannot end a request.
func silenceFor(_ text: String, _ baseMs: Int, _ language: String) -> Int {
    looksUnfinished(text, language) ? baseMs + unfinishedExtraMs : baseMs
}
