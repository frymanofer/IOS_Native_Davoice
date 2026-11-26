import Foundation

// JSON as a Swift value, the way the React Native, Flutter and Android car apps handle the agent's and the car's JSON: objects keep
// their key order (tool results and the agent pack go into the model's prompt as they are written), numbers are doubles that print as
// JavaScript prints them (22, not 22.0), and a missing key reads the same as null.

indirect enum JSON: Equatable {
    case null
    case bool(Bool)
    case num(Double)
    case str(String)
    case arr([JSON])
    case obj(JObj)

    // ---- reading -------------------------------------------------------------------------------------------------------------

    /// The value of a key (nil when missing or null).
    subscript(key: String) -> JSON? {
        if case .obj(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .str(let s) = self { return s }; return nil }
    var double: Double? { if case .num(let d) = self { return d }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSON]? { if case .arr(let a) = self { return a }; return nil }
    var object: JObj? { if case .obj(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }
}

/// A JSON object with its keys in insertion order (Kotlin's LinkedHashMap, a JavaScript object).
struct JObj: Equatable, Sequence {
    private(set) var keys: [String] = []
    private var map: [String: JSON] = [:]

    init() {}

    init(_ pairs: [(String, JSON)]) {
        for (k, v) in pairs { self[k] = v }
    }

    /// The value (nil when missing or null, as Kotlin's map[k] on a parsed JSON object).
    subscript(key: String) -> JSON? {
        get {
            guard let v = map[key] else { return nil }
            if case .null = v { return nil }
            return v
        }
        set {
            if let v = newValue {
                if map[key] == nil { keys.append(key) }
                map[key] = v
            } else {
                remove(key)
            }
        }
    }

    /// The stored value, null included.
    func raw(_ key: String) -> JSON? { map[key] }

    /// Stores null (kept as a key).
    mutating func setNull(_ key: String) {
        if map[key] == nil { keys.append(key) }
        map[key] = .null
    }

    mutating func remove(_ key: String) {
        guard map.removeValue(forKey: key) != nil else { return }
        keys.removeAll { $0 == key }
    }

    func has(_ key: String) -> Bool { map[key] != nil }
    var isEmpty: Bool { keys.isEmpty }
    var count: Int { keys.count }

    func makeIterator() -> AnyIterator<(key: String, value: JSON)> {
        var i = 0
        let keys = self.keys
        let map = self.map
        return AnyIterator {
            guard i < keys.count else { return nil }
            defer { i += 1 }
            return (keys[i], map[keys[i]]!)
        }
    }

    /// Kotlin's `a + b`: b's values replace a's (in a's key order), b's new keys follow.
    static func + (a: JObj, b: JObj) -> JObj {
        var out = a
        for (k, v) in b { out.map[k] == nil ? out.keys.append(k) : (); out.map[k] = v }
        return out
    }

    static func == (a: JObj, b: JObj) -> Bool { a.map == b.map }
}

// ---- literals: ["name": "set_window", "arguments": ["window": "all"]] ------------------------------------------------------------

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByStringInterpolation {
    init(stringLiteral value: String) { self = .str(value) }
    init(integerLiteral value: Int) { self = .num(Double(value)) }
    init(floatLiteral value: Double) { self = .num(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .arr(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) { self = .obj(JObj(elements)) }
    init(nilLiteral: ()) { self = .null }
}

extension JObj: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, JSON)...) { self.init(elements) }
}

extension JSON {
    init(_ s: String) { self = .str(s) }
    init(_ s: String?) { self = s.map { .str($0) } ?? .null }
    init(_ d: Double) { self = .num(d) }
    init(_ d: Double?) { self = d.map { .num($0) } ?? .null }
    init(_ i: Int) { self = .num(Double(i)) }
    init(_ b: Bool) { self = .bool(b) }
    init(_ o: JObj) { self = .obj(o) }
    init(_ a: [String]) { self = .arr(a.map { .str($0) }) }
    init(_ a: [JObj]) { self = .arr(a.map { .obj($0) }) }
    init(_ a: [JSON]) { self = .arr(a) }
    init(_ m: [String: String]) { self = .obj(JObj(m.sorted { $0.key < $1.key }.map { ($0.key, .str($0.value)) })) }
    init(_ m: [String: Double]) { self = .obj(JObj(m.sorted { $0.key < $1.key }.map { ($0.key, .num($0.value)) })) }
    init(_ m: [String: Bool]) { self = .obj(JObj(m.sorted { $0.key < $1.key }.map { ($0.key, .bool($0.value)) })) }

    /// From Foundation values (the bridges' NSDictionary / NSArray results).
    init(foundation v: Any?) {
        switch v {
        case nil, is NSNull: self = .null
        case let s as String: self = .str(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .num(n.doubleValue) }
        case let a as [Any]: self = .arr(a.map { JSON(foundation: $0) })
        case let d as [String: Any]: self = .obj(JObj(d.keys.sorted().map { ($0, JSON(foundation: d[$0])) }))
        default: self = .str("\(v!)")
        }
    }

    /// To Foundation values (what the bridges take).
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .num(let d): return d == d.rounded() && abs(d) < 1e15 ? NSNumber(value: Int64(d)) : NSNumber(value: d)
        case .str(let s): return s
        case .arr(let a): return a.map { $0.foundation }
        case .obj(let o):
            var d: [String: Any] = [:]
            for (k, v) in o { d[k] = v.foundation }
            return d
        }
    }
}

// ---- helpers with the other apps' semantics ----------------------------------------------------------------------------------

/// A value as an object (empty when it is not one).
func asObj(_ v: JSON?) -> JObj { v?.object ?? JObj() }

/// A value as a list (empty when it is not one).
func asList(_ v: JSON?) -> [JSON] { v?.array ?? [] }

/// A value as a number, as Dart's `v is num ? v : num.tryParse(v)`.
func numOf(_ v: JSON?) -> Double? {
    switch v {
    case .num(let d)?: return d
    case .str(let s)?: return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
    default: return nil
    }
}

/// A value as the JS / Dart string interpolation prints it ("22", "22.5", "true", nil -> "").
func str(_ v: JSON?) -> String {
    switch v {
    case nil, .null?: return ""
    case .str(let s)?: return s
    case .num(let d)?: return Json.num(d)
    case .bool(let b)?: return b ? "true" : "false"
    case let other?: return Json.stringify(other)
    }
}

enum Json {
    /// A number as JSON / JavaScript prints it: 22 (not 22.0), 22.5.
    static func num(_ d: Double) -> String {
        if d == d.rounded() && d.isFinite && abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }

    static func stringify(_ v: JSON) -> String {
        var out = ""
        write(&out, v)
        return out
    }

    static func stringify(_ o: JObj) -> String { stringify(.obj(o)) }

    private static func write(_ b: inout String, _ v: JSON) {
        switch v {
        case .null: b += "null"
        case .bool(let x): b += x ? "true" : "false"
        case .num(let d): b += num(d)
        case .str(let s): quote(&b, s)
        case .arr(let a):
            b += "["
            for (i, x) in a.enumerated() {
                if i > 0 { b += "," }
                write(&b, x)
            }
            b += "]"
        case .obj(let o):
            b += "{"
            var first = true
            for k in o.keys {
                if !first { b += "," }
                first = false
                quote(&b, k)
                b += ":"
                write(&b, o.raw(k) ?? .null)
            }
            b += "}"
        }
    }

    private static func quote(_ b: inout String, _ s: String) {
        b += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": b += "\\\""
            case "\\": b += "\\\\"
            case "\n": b += "\\n"
            case "\r": b += "\\r"
            case "\t": b += "\\t"
            case "\u{08}": b += "\\b"
            case "\u{0C}": b += "\\f"
            default:
                if u.value < 0x20 { b += String(format: "\\u%04x", u.value) } else { b.unicodeScalars.append(u) }
            }
        }
        b += "\""
    }

    // ---- parsing (keeps key order; JSONSerialization does not) ---------------------------------------------------------------

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ text: String) throws -> JSON {
        var p = Parser(Array(text.utf8))
        p.skipSpace()
        let v = try p.value()
        p.skipSpace()
        if p.i != p.b.count { throw ParseError(description: "trailing text at \(p.i)") }
        return v
    }

    static func obj(_ text: String) throws -> JObj {
        guard case .obj(let o) = try parse(text) else { throw ParseError(description: "not an object") }
        return o
    }

    private struct Parser {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        mutating func skipSpace() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        }

        mutating func value() throws -> JSON {
            guard i < b.count else { throw ParseError(description: "unexpected end") }
            switch b[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .str(try string())
            case UInt8(ascii: "t"): try word("true"); return .bool(true)
            case UInt8(ascii: "f"): try word("false"); return .bool(false)
            case UInt8(ascii: "n"): try word("null"); return .null
            default: return .num(try number())
            }
        }

        mutating func word(_ w: String) throws {
            let u = Array(w.utf8)
            guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { throw ParseError(description: "bad literal at \(i)") }
            i += u.count
        }

        mutating func number() throws -> Double {
            let start = i
            while i < b.count, (b[i] >= 0x30 && b[i] <= 0x39) || b[i] == UInt8(ascii: "-") || b[i] == UInt8(ascii: "+")
                || b[i] == UInt8(ascii: ".") || b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") { i += 1 }
            guard let s = String(bytes: b[start..<i], encoding: .ascii), let d = Double(s) else {
                throw ParseError(description: "bad number at \(start)")
            }
            return d
        }

        mutating func string() throws -> String {
            i += 1 // opening quote
            var out = [UInt8]()
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < b.count else { break }
                    let e = b[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if code >= 0xD800 && code < 0xDC00, i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out.append(contentsOf: Array(String(UnicodeScalar(code).map { Character($0) } ?? "\u{FFFD}").utf8))
                    default: out.append(e)
                    }
                    continue
                }
                out.append(c)
                i += 1
            }
            throw ParseError(description: "unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count, let s = String(bytes: b[i..<i + 4], encoding: .ascii), let v = UInt32(s, radix: 16) else {
                throw ParseError(description: "bad \\u escape at \(i)")
            }
            i += 4
            return v
        }

        mutating func array() throws -> JSON {
            i += 1
            var out = [JSON]()
            skipSpace()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .arr(out) }
            while true {
                skipSpace()
                out.append(try value())
                skipSpace()
                guard i < b.count else { throw ParseError(description: "unterminated array") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .arr(out) }
                throw ParseError(description: "bad array at \(i)")
            }
        }

        mutating func object() throws -> JSON {
            i += 1
            var out = JObj()
            skipSpace()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .obj(out) }
            while true {
                skipSpace()
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw ParseError(description: "bad key at \(i)") }
                let k = try string()
                skipSpace()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw ParseError(description: "missing : at \(i)") }
                i += 1
                skipSpace()
                let v = try value()
                if case .null = v { out.setNull(k) } else { out[k] = v }
                skipSpace()
                guard i < b.count else { throw ParseError(description: "unterminated object") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .obj(out) }
                throw ParseError(description: "bad object at \(i)")
            }
        }
    }
}

/// Parses, or nil (for JSON from the engines that is checked anyway).
func parseJSON(_ text: String) -> JSON? { try? Json.parse(text) }
