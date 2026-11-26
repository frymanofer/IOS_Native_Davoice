import Foundation

// Speech text helpers (ports of the React Native / Flutter / Android apps' transcript, fragments and sentence splitting).

private let fillers: Set<String> = [
    "the", "a", "an", "and", "but", "or", "so", "then", "um", "uh", "uhm", "hmm", "mm", "oh", "ah", "eh", "boy", "well", "like", "just",
    "o", "os", "as", "e", "é", "mas", "ou", "então", "entao", "tipo", "né", "ne", "hã", "ha", "hum", "ahn", "ué", "ue", "peraí", "perai", "bom",
]

private func fragmentWords(_ text: String) -> [String] {
    let cleaned = re("[^\\p{L}\\p{N}\\s']").replace(text.lowercased(), with: " ")
    return re("\\s+").split(cleaned).filter { !$0.isEmpty }
}

/// True for a transcript that is only noise: filler words, or one word said twice ("Alma Alma.").
func isNoiseFragment(_ text: String) -> Bool {
    let words = fragmentWords(text)
    if words.isEmpty { return true }
    if words.count > 2 || words.contains(where: { re("\\d").has($0) }) { return false }
    if words.allSatisfy({ fillers.contains($0) }) { return true }
    return words.count == 2 && words[0] == words[1]
}

/// A very short request (two words or fewer, no number): too little to be a real "can't do that".
func isTooShortForDecline(_ text: String) -> Bool {
    let words = fragmentWords(text)
    return words.count <= 2 && !words.contains(where: { re("\\d").has($0) })
}

/// A bare "Done." (en / pt): in the car demo the app's own sentence confirms every real action, so "Done." alone means nothing ran.
func isBareDone(_ sentence: String) -> Bool {
    re("^\\s*(done|all set|okay,? done|ok,? done|pronto|prontinho|feito|ok,? feito|tudo certo)\\s*[.!]?\\s*$", ignoreCase: true).has(sentence)
}

/// Partial / final speech results merged into one running transcript (the same overlap and punctuation rules as the other apps).
func mergeTranscript(_ previous: String, _ current: String) -> String {
    let prev = previous.trimmed
    let curr = current.trimmed
    if prev.isEmpty { return curr }
    if curr.isEmpty { return prev }
    if curr.hasPrefix(prev) { return curr }
    if prev.hasPrefix(curr) { return prev }
    func normalize(_ t: String) -> String {
        re("\\s+").replace(re("[^A-Za-z0-9\\s]+").replace(t.lowercased(), with: ""), with: " ").trimmed
    }
    let np = normalize(prev)
    let nc = normalize(curr)
    if nc.hasPrefix(np) { return curr }
    let words = re("[A-Za-z0-9]+")
    let pw = words.findAll(prev).map { $0.value.lowercased() }
    let spans = words.findAll(curr)
    let cw = spans.map { $0.value.lowercased() }
    var k = min(pw.count, cw.count)
    while k >= 2 {
        if (0..<k).allSatisfy({ pw[pw.count - k + $0] == cw[$0] }) {
            let tail = String(curr[spans[k - 1].range.upperBound...])
            var left = prev
            if let last = re("[?!]+$").find(prev), let first = re("^[?!]+").find(tail), last.value.first == first.value.first {
                left = String(prev[..<last.range.lowerBound])
            }
            let space = re("[A-Za-z0-9]$").has(left) && re("^[A-Za-z0-9]").has(tail)
            return "\(left)\(space ? " " : "")\(tail)"
        }
        k -= 1
    }
    return nc.count >= np.count ? curr : prev
}

/// Model output as it is read aloud: no markdown, sentence boundaries kept.
func normalizeTextForSpeech(_ input: String) -> String {
    var text = re("^\\s*(?:[-*•]|\\d+[.)])\\s+", multiLine: true).replace(input, with: "")
    text = re("\\*\\*(.+?)\\*\\*|__(.+?)__").replace(text) { $0.g(1) ?? $0.g(2) ?? "" }
    text = re("(^|\\s)[*_](\\S(?:[^*_\\n]*\\S)?)[*_](?=\\s|[.,!?:;]|$)", multiLine: true).replace(text) { "\($0.g(1) ?? "")\($0.g(2) ?? "")" }
    text = re("^#+\\s*", multiLine: true).replace(text, with: "")
    let source = text
    var out = re("\\s*\\n+\\s*").replace(source) { m in
        let before = String(source[..<m.range.lowerBound]).trimmedEnd
        let after = String(source[m.range.upperBound...]).trimmedStart
        return re("[.!?,:;]$").has(before) || re("^[.!?,:;]").has(after) ? " " : ". "
    }
    out = re("\\s+([.!?,:;])").replace(out) { $0.gs(1) }
    out = re("([.!?,:;]){2,}").replace(out) { $0.gs(1) }
    out = re("\\s{2,}").replace(out, with: " ")
    return out.trimmed
}

/// Finished sentences and the unfinished rest, so speech starts on the first sentence while the model still writes.
func splitCompletedSentences(_ text: String) -> (completed: [String], rest: String) {
    let chars = Array(text)
    var completed = [String]()
    var start = 0
    var index = 0
    while index < chars.count {
        if !".!?".contains(chars[index]) {
            index += 1
            continue
        }
        var boundary = index + 1
        while boundary < chars.count, "\"')]".contains(chars[boundary]) { boundary += 1 }
        while boundary < chars.count, chars[boundary].isWhitespace { boundary += 1 }
        let sentence = String(chars[start..<boundary]).trimmed
        if !sentence.isEmpty { completed.append(sentence) }
        start = boundary
        index = boundary
    }
    return (completed, String(chars[start...]))
}
