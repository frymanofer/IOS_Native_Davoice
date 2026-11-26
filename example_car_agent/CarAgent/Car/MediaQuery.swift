import Foundation

// What to play = the driver's own words when the model copied them wrong ("Play Pretty Woman" -> play_media {query: "Perma Woman"};
// "Can you play pretty woman on the radio please?" -> "woman"). Port of the other car apps' media query; shared fixture media_query.json.

// the words before the title (the first one: a title may hold one, "Play Let Me Play")
private let playVerb = re("(?<!\\p{L})(?:play|put on|listen to|toca|toque|tocar|coloca|coloque|bota|poe|põe|quero ouvir|ouvir)(?!\\p{L})", ignoreCase: true)

// words after the title that are not part of it
private let trailing = re(
    "(?:\\s+(?:on the radio|on spotify|in the car|for me|please|now|right now|no radio|no rádio|no spotify|pra mim|para mim|por favor|agora))+\\s*$",
    ignoreCase: true)

// words a copy may leave out or add without changing what is played
private let small: Set<String> = ["a", "o", "as", "os", "the", "some", "um", "uma", "me", "de", "do", "da", "song", "musica", "cancao"]

private let accents: [Character: Character] = [
    "á": "a", "à": "a", "â": "a", "ã": "a", "ä": "a", "é": "e", "ê": "e", "è": "e", "ë": "e", "í": "i", "ì": "i", "î": "i",
    "ï": "i", "ó": "o", "ô": "o", "õ": "o", "ò": "o", "ö": "o", "ú": "u", "ù": "u", "û": "u", "ü": "u", "ç": "c", "ñ": "n",
]

private func norm(_ w: String) -> String {
    let folded = String(w.lowercased().map { accents[$0] ?? $0 })
    return re("[^a-z0-9]").replace(folded, with: "")
}

private func mediaWords(_ s: String) -> [String] { re("\\s+").split(s).map(norm).filter { !$0.isEmpty } }

/// The title the driver said after the play verb (their own spelling), or nil.
func spokenTitle(_ userText: String) -> String? {
    guard let m = playVerb.find(userText) else { return nil }
    var span = String(userText[m.range.upperBound...])
    if let end = re("[?.!]+\\s*$").find(span) { span.removeSubrange(end.range) }
    if let t = trailing.find(span) { span.removeSubrange(t.range) }
    span = re("^[\\s,]+|[\\s,]+$").replace(span, with: "")
    return mediaWords(span).isEmpty ? nil : span
}

private func titleCase(_ s: String) -> String {
    s == s.lowercased() ? re("(^|\\s)(\\p{L})").replace(s) { "\($0.gs(1))\($0.gs(2).uppercased())" } : s
}

/// The query to play: the model's, or the driver's words when the model's is a damaged copy of them.
func groundMediaQuery(_ query: String, _ userText: String) -> String {
    guard let span = spokenTitle(userText) else { return query }
    let q = mediaWords(query).filter { !small.contains($0) }
    let s = mediaWords(span).filter { !small.contains($0) }
    if q.isEmpty || s.isEmpty || q.joined(separator: " ") == s.joined(separator: " ") { return query }
    let exact = q.filter { s.contains($0) }.count
    if exact == 0 { return query } // not a copy of what was said
    // (a) words left out: every query word was said, some said words are missing ("woman" for "pretty woman")
    let leftOut = exact == q.count && s.count > q.count
    // (b) words misspelt: as many words, at least half exact, the others start with the same letter ("Perma Woman")
    var misspelt = q.count == s.count && exact * 2 >= q.count
    var i = 0
    while misspelt && i < q.count {
        if !s.contains(q[i]) && q[i].first != s[i].first { misspelt = false }
        i += 1
    }
    return leftOut || misspelt ? titleCase(span) : query
}
