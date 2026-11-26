import Foundation

// Regular expressions with the semantics the car code was written for (Kotlin / Dart / JavaScript): ICU patterns (the same syntax as
// Java's for everything used here), replacements are literal text, and a group that did not take part is nil. Compiled patterns are
// cached: the car code builds them inline.

final class Rx {
    let ns: NSRegularExpression

    init(_ pattern: String, ignoreCase: Bool = false, dotAll: Bool = false, multiLine: Bool = false) {
        var o: NSRegularExpression.Options = []
        if ignoreCase { o.insert(.caseInsensitive) }
        if dotAll { o.insert(.dotMatchesLineSeparators) }
        if multiLine { o.insert(.anchorsMatchLines) }
        do {
            ns = try NSRegularExpression(pattern: pattern, options: o)
        } catch {
            fatalError("bad pattern \(pattern): \(error)")
        }
    }

    private static let lock = NSLock()
    private static var cache: [String: Rx] = [:]

    /// A cached pattern (the same text and options give the same object).
    static func of(_ pattern: String, ignoreCase: Bool = false, dotAll: Bool = false, multiLine: Bool = false) -> Rx {
        let key = "\(ignoreCase ? 1 : 0)\(dotAll ? 1 : 0)\(multiLine ? 1 : 0)\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let r = cache[key] { return r }
        let r = Rx(pattern, ignoreCase: ignoreCase, dotAll: dotAll, multiLine: multiLine)
        cache[key] = r
        return r
    }

    /// Kotlin's containsMatchIn.
    func has(_ s: String) -> Bool {
        ns.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// The first match, or nil.
    func find(_ s: String) -> RxMatch? {
        ns.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)).map { RxMatch(s, $0) }
    }

    func findAll(_ s: String) -> [RxMatch] {
        ns.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { RxMatch(s, $0) }
    }

    /// Kotlin's Regex.matches: the whole text matches.
    func matches(_ s: String) -> Bool {
        guard let m = ns.firstMatch(in: s, options: [.anchored], range: NSRange(s.startIndex..., in: s)) else { return false }
        return m.range.length == (s as NSString).length
    }

    /// Every match replaced by f(match) (literal text).
    func replace(_ s: String, _ f: (RxMatch) -> String) -> String {
        let all = ns.matches(in: s, range: NSRange(s.startIndex..., in: s))
        if all.isEmpty { return s }
        var out = ""
        var last = s.startIndex
        for r in all {
            let m = RxMatch(s, r)
            out += s[last..<m.range.lowerBound]
            out += f(m)
            last = m.range.upperBound
        }
        out += s[last...]
        return out
    }

    func replace(_ s: String, with literal: String) -> String { replace(s) { _ in literal } }

    /// The first match replaced by f(match) (literal text).
    func replaceFirst(_ s: String, _ f: (RxMatch) -> String) -> String {
        guard let m = find(s) else { return s }
        return String(s[..<m.range.lowerBound]) + f(m) + String(s[m.range.upperBound...])
    }

    func replaceFirst(_ s: String, with literal: String) -> String { replaceFirst(s) { _ in literal } }

    /// Kotlin's split(Regex): the pieces between matches.
    func split(_ s: String) -> [String] {
        var out = [String]()
        var last = s.startIndex
        for m in findAll(s) {
            out.append(String(s[last..<m.range.lowerBound]))
            last = m.range.upperBound
        }
        out.append(String(s[last...]))
        return out
    }
}

struct RxMatch {
    let text: String
    let result: NSTextCheckingResult

    init(_ text: String, _ result: NSTextCheckingResult) {
        self.text = text
        self.result = result
    }

    var range: Range<String.Index> { Range(result.range, in: text)! }
    var value: String { String(text[range]) }

    /// Group i, nil when it did not take part.
    func g(_ i: Int) -> String? {
        guard i < result.numberOfRanges else { return nil }
        let r = result.range(at: i)
        guard r.location != NSNotFound, let rr = Range(r, in: text) else { return nil }
        return String(text[rr])
    }

    /// Group i, "" when it did not take part.
    func gs(_ i: Int) -> String { g(i) ?? "" }
}

/// A cached pattern (Kotlin's `re(...)` / `Regex(...)` in the car code).
func re(_ pattern: String, ignoreCase: Bool = false, dotAll: Bool = false, multiLine: Bool = false) -> Rx {
    Rx.of(pattern, ignoreCase: ignoreCase, dotAll: dotAll, multiLine: multiLine)
}

/// Escapes a literal for a pattern (Kotlin's Regex.escape).
func rxEscape(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

/// "door" -> "Door".
func cap(_ t: String) -> String { t.isEmpty ? t : t.prefix(1).uppercased() + t.dropFirst() }

extension String {
    /// Kotlin's trim() (whitespace at both ends).
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Kotlin's trimStart().
    var trimmedStart: String { String(drop { $0.isWhitespace }) }

    /// Kotlin's trimEnd().
    var trimmedEnd: String {
        var s = Substring(self)
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        return String(s)
    }

    /// Kotlin's split(' ') (empty pieces kept).
    func splitSpace() -> [String] { components(separatedBy: " ") }
}
