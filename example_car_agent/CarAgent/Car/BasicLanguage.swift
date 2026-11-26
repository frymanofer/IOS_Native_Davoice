import Foundation

// Basic language support (port of the other car apps' basic language). The on-device model and the agent core's word lists are tuned
// for English and Brazilian Portuguese only. In every other language ("Basic") the agent never acts on its own reading of the request:
// each car action is first ASKED in the user's language ("Soll ich das Fahrerfenster öffnen?") and runs only after a plain yes.
// Read-only lookups (fuel, ETA, places) answer directly. The sentences come from Resources/car/basic_languages.json (the same file as the
// other apps).
//
// How the yes reaches the action: the car tool refuses with an "offer" (the call itself); the agent core runs an offered call when the
// next request is a plain yes. The core's yes / no words are English + Portuguese, so the app turns a plain "ja" / "sí" / "oui" into
// "yes" / "no" before the request goes to the agent (normalizeYesNo).

enum BasicLanguage {
    private static var langs: [String: JObj] = [:]

    /// Loads basic_languages.json (CarTools.load does it).
    static func load(_ json: String) throws {
        var out: [String: JObj] = [:]
        for (k, v) in asObj(try Json.obj(json)["languages"]) { out[k] = asObj(v) }
        langs = out
        hintCache = [:]
        phraseRe = [:]
    }

    /// The languages the model and the agent core were tuned for: they act directly.
    static let tunedLanguages: Set<String> = ["en", "pt-BR"]
    static func isBasic(_ language: String?) -> Bool { !tunedLanguages.contains(language ?? "en") }

    private static func entry(_ language: String) -> JObj { langs[language] ?? langs["en"] ?? JObj() }

    private static func table(_ e: JObj, _ key: String) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in asObj(e[key]) { out[k] = str(v) }
        return out
    }

    /// The app's own sentence in a Basic language (whichSeat, didNotCatch, notInDemo, noRemote, lowClarify, lowDecline, lowNoRemote).
    static func message(_ language: String, _ key: String) -> String? {
        isBasic(language) ? table(langs[language] ?? JObj(), "messages")[key] : nil
    }

    /// The agent pack's spoken prompts in a Basic language (see AgentPack).
    static func packTexts(_ language: String) -> JObj? { isBasic(language) ? langs[language]?["pack"]?.object : nil }

    private static func fill(_ tpl: String, _ vars: [String: String]) -> String {
        re("\\{(\\w+)\\}").replace(tpl) { vars[$0.gs(1)] ?? $0.value }
    }

    private static func num(_ n: JSON?, _ language: String) -> String {
        guard let v = numOf(n) else { return str(n) }
        let r = (v * 10).rounded() / 10.0
        let s = r == r.rounded() ? String(Int64(r.rounded())) : "\(r)"
        return language == "en" ? s : s.replacingOccurrences(of: ".", with: ",")
    }

    private static func deg(_ t: JSON?, _ unit: JSON?, _ language: String) -> String {
        "\(num(t, language)) °\(unit == "fahrenheit" ? "F" : "C")"
    }

    /// The action a call stands for, as a short phrase ("das Fahrerfenster öffnen"). Unknown calls get the generic phrase.
    static func describeCall(_ name: String, _ args: JObj, _ language: String) -> String {
        let e = entry(language)
        let t = table(e, "t")
        func tt(_ key: String, _ vars: [String: String] = [:]) -> String { fill(t[key] ?? t["generic"] ?? "", vars) }
        func pick(_ tbl: String, _ key: JSON?, _ fallback: String) -> String {
            let m = table(e, tbl)
            return m[str(key)] ?? m[fallback] ?? (key == nil ? "" : str(key))
        }
        let a = args
        switch name {
        case "set_window":
            let pos = ["open", "close", "half", "crack"].contains(str(a["position"])) && a["position"] != nil ? str(a["position"]) : "open"
            return tt("window.\(pos)", ["window": pick("window", a["window"] ?? "all", "all")])
        case "open_door": return tt("door.open", ["door": pick("door", a["door"] ?? "all", "all")])
        case "close_doors": return tt("door.close", ["door": pick("door", a["door"] ?? "all", "all")])
        case "lock_car", "unlock_car":
            let door = a["door"] != nil && a["door"] != "all" ? pick("door", a["door"], "car") : (table(e, "door")["car"] ?? "")
            return tt(name == "lock_car" ? "lock" : "unlock", ["door": door])
        case "set_sunroof":
            return tt("sunroof.\(["open", "tilt", "close"].contains(str(a["action"])) && a["action"] != nil ? str(a["action"]) : "open")")
        case "set_trunk": return tt("\(a["which"] == "frunk" ? "frunk" : "trunk").\(a["action"] == "close" ? "close" : "open")")
        case "set_temperature":
            if a["temperature"] != nil {
                let temp = deg(a["temperature"], a["unit"], language)
                if a["zone"] != nil && a["zone"] != "all" { return tt("temp.setZone", ["t": temp, "zone": pick("zone", a["zone"], "all")]) }
                return tt("temp.set", ["t": temp])
            }
            let c = numOf(.str(str(a["change"] ?? 1))) ?? 1
            return tt(c >= 0 ? "temp.up" : "temp.down", ["n": num(.num(abs(c) == 0 ? 1 : abs(c)), language)])
        case "set_dual_zone_temperature":
            return tt("dual", ["d": deg(a["driver"], a["unit"], language), "p": deg(a["passenger"], a["unit"], language)])
        case "comfort_feeling": return tt(a["feeling"] == "hot" ? "feel.hot" : "feel.cold")
        case "set_fan_speed":
            if a["level"] != nil { return tt("fan.set", ["n": num(a["level"], language)]) }
            return tt((numOf(.str(str(a["change"] ?? 1))) ?? 1) >= 0 ? "fan.up" : "fan.down")
        case "set_airflow": return tt("air", ["mode": pick("air", a["mode"], "face")])
        case "set_defrost": return tt("defrost.\(a["target"] == "rear" ? "rear" : "windshield").\(a["on"] == false ? "off" : "on")")
        case "set_seat_climate":
            let vars = ["feature": pick("feature", a["feature"] ?? "heater", "heater"), "seat": pick("seat", a["seat"] ?? "driver", "driver")]
            if a["level"] == "off" { return tt("seat.off", vars) }
            return tt("seat.set", vars.merging(["level": pick("level", a["level"] ?? "medium", "medium")]) { $1 })
        case "set_steering_wheel_heater": return tt(a["on"] == false ? "wheel.off" : "wheel.on")
        case "play_media": return tt("media", ["q": str(a["query"] ?? "")])
        case "tune_radio": return tt("radio", ["band": str(a["band"] ?? "fm").uppercased(), "f": num(a["frequency"], language)])
        case "set_audio_source": return tt("source", ["source": pick("source", a["source"], "radio")])
        case "set_volume":
            let act = str(a["action"] ?? JSON((numOf(.str(str(a["change"] ?? 0))) ?? 0) < 0 ? "down" : "up"))
            if act == "set" { return tt("vol.set", ["n": num(a["level"], language)]) }
            return tt("vol.\(["up", "down", "mute", "unmute"].contains(act) ? act : "up")")
        case "navigate_to":
            let dest = str(a["destination"] ?? "").trimmed
            switch dest.lowercased() {
            case "home": return tt("nav.home")
            case "work": return tt("nav.work")
            default: return tt("nav", ["dest": dest])
            }
        case "set_route_avoid": return tt("avoid", ["avoid": pick("avoid", a["avoid"], "traffic")])
        default: return tt("generic")
        }
    }

    /// One question for one or more calls: "Soll ich das Fahrerfenster öffnen und das Gebläse auf Stufe 3 stellen?"
    static func confirmQuestion(_ calls: [JObj], _ language: String) -> String {
        let e = entry(language)
        let parts = calls.map { describeCall(str($0["name"]), asObj($0["arguments"]), language) }
        let and = str(e["and"] ?? "and")
        let body: String
        if parts.isEmpty { body = table(e, "t")["generic"] ?? "" } else if parts.count == 1 { body = parts[0] } else {
            body = "\(parts.dropLast().joined(separator: ", ")) \(and) \(parts.last!)"
        }
        return fill(str(e["q"] ?? "{a}?"), ["a": e["capitalize"] == true ? cap(body) : body])
    }

    static func done(_ language: String) -> String { str(entry(language)["done"] ?? "") }
    static func cannot(_ language: String) -> String { str(entry(language)["cannot"] ?? "") }
    static func driving(_ language: String) -> String { str(entry(language)["driving"] ?? "") }

    /// A read-only lookup answered in the Basic language, or nil (then the tool's own sentence is used).
    static func answer(_ name: String, _ args: JObj, _ language: String, _ destination: String?, _ fuelPercent: Int) -> String? {
        let e = entry(language)
        let ans = table(e, "answer")
        func a(_ key: String, _ vars: [String: String] = [:]) -> String? { ans[key].map { fill($0, vars) } }
        switch name {
        case "get_trip_eta": return destination != nil ? a("eta", ["min": "24"]) : a("eta.none")
        case "find_along_route":
            return a("find", ["place": table(e, "place")[str(args["place_type"])] ?? str(args["place_type"] ?? "")])
        case "get_vehicle_status":
            let item = str(args["item"] ?? "")
            return a("status.\(item)", [
                "km": item == "fuel" ? String(Int((Double(fuelPercent) * 5).rounded())) : "312",
                "pct": item == "fuel" ? "\(fuelPercent)" : "76",
                "v": num(.num(12.4), language),
            ])
        default: return nil
        }
    }

    // ---- what waits for a yes ------------------------------------------------------------------------------------------------

    private static func stable(_ v: JSON?) -> String {
        switch v {
        case .arr(let a)?: return "[\(a.map { stable($0) }.joined(separator: ","))]"
        case .obj(let o)?: return "{\(o.keys.sorted().map { "\(Json.stringify(.str($0))):\(stable(o.raw($0)))" }.joined(separator: ","))}"
        case let x?: return Json.stringify(x)
        case nil: return "null"
        }
    }

    private static func keyOf(_ name: String, _ args: JObj) -> String { "\(name)|\(stable(.obj(args)))" }

    private struct Pending {
        let key: String
        let call: JObj
        let turn: Int
    }

    private static var turn = 0
    private static var pending: [Pending] = []

    /// Call before each request (after normalizeYesNo). Calls asked in the previous request stay confirmable for this one only.
    static func beginTurn() {
        turn += 1
        pending.removeAll { $0.turn < turn - 1 }
    }

    /// True (and consumed) when this call was asked in the previous request: the user's yes ran it.
    static func takeConfirmed(_ name: String, _ args: JObj) -> Bool {
        let k = keyOf(name, args)
        guard let i = pending.firstIndex(where: { $0.key == k && $0.turn == turn - 1 }) else { return false }
        pending.remove(at: i)
        return true
    }

    /// Remembers calls to ask about; returns every call asked in this request (the core keeps one offer per request).
    static func addPending(_ calls: [JObj]) -> [JObj] {
        for call in calls {
            let k = keyOf(str(call["name"]), asObj(call["arguments"]))
            if !pending.contains(where: { $0.key == k && $0.turn == turn }) { pending.append(Pending(key: k, call: call, turn: turn)) }
        }
        return pending.filter { $0.turn == turn }.map(\.call)
    }

    static func clearPending() { pending.removeAll() }

    private static let accentPairs = "àa áa âa ãa äa åa āa ăa ąa çc ćc čc ďd èe ée êe ëe ēe ėe ęe ěe ìi íi îi ïi īi įi ñn ńn ňn òo óo ôo õo öo ōo őo " +
        "ùu úu ûu üu ūu ůu űu ųu ýy ÿy žz źz żz śs šs şs řr ťt ţt ľl ĺl άα έε ήη ίι ϊι ΐι όο ύυ ϋυ ΰυ ώω"
    private static let accentMap: [UnicodeScalar: UnicodeScalar] = {
        var m: [UnicodeScalar: UnicodeScalar] = [:]
        for pair in accentPairs.split(separator: " ") {
            let s = Array(pair.unicodeScalars)
            if s.count == 2 { m[s[0]] = s[1] }
        }
        return m
    }()

    /// Lower case, no accents, letters and digits only.
    static func fold(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars { out.append(accentMap[u] ?? u) }
        return re("[^\\p{L}\\p{N}]+").replace(String(out), with: " ").trimmed
    }

    private static var phraseRe: [String: Rx] = [:]

    private static func onlyPhrases(_ text: String, _ phrases: [String], _ cacheKey: String) -> Bool {
        let r: Rx
        if let cached = phraseRe[cacheKey] { r = cached } else {
            let alts = Array(Set(phrases.map { fold($0) })).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
            r = Rx("^((\(alts.map(rxEscape).joined(separator: "|")))( |$))+$")
            phraseRe[cacheKey] = r
        }
        return r.has(fold(text))
    }

    /// A plain yes / no to the agent's question in a Basic language -> "yes" / "no" (what the agent core understands), else nil.
    static func normalizeYesNo(_ text: String, _ language: String) -> String? {
        if !isBasic(language) || !pending.contains(where: { $0.turn == turn }) { return nil }
        let e = entry(language)
        let yes = asList(e["yes"]).map { str($0) }
        let no = asList(e["no"]).map { str($0) }
        if onlyPhrases(text, yes, "\(language)|yes") { return "yes" }
        if onlyPhrases(text, no, "\(language)|no") { return "no" }
        return nil
    }

    // ---- English hints for the model -----------------------------------------------------------------------------------------

    /// A hint pattern for the folded text: words are separated by single spaces, so \w = any non-space and \b = a space or the end.
    private static func hintRegex(_ pattern: String) -> Rx {
        let p = Array(pattern)
        var out = ""
        var i = 0
        while i < p.count {
            if p[i] == "\\" && i + 1 < p.count && p[i + 1] == "b" {
                let next = String(p[(i + 2)...])
                let end = next.isEmpty || next.hasPrefix("|") || next.hasPrefix(")") || next.hasPrefix("(?!") || next.hasPrefix("(?=")
                out += end ? "(?= |$)" : "(?:^| )"
                i += 2
            } else if p[i] == "\\" && i + 1 < p.count && p[i + 1] == "w" {
                out += "[^ ]"
                i += 2
            } else {
                out.append(p[i])
                i += 1
            }
        }
        return Rx(out)
    }

    private static var hintCache: [String: [(Rx, String)]] = [:]

    /// Basic language: the car words the user said, in English, added in brackets for the model ("Mach die Musik leiser" ->
    /// "Mach die Musik leiser (volume down, music)"). Tuned languages and sentences without a car word stay as they are.
    static func withCarHints(_ text: String, _ language: String) -> String {
        if !isBasic(language) { return text }
        let rules: [(Rx, String)]
        if let cached = hintCache[language] { rules = cached } else {
            rules = asList(langs[language]?["hints"]).map { r in
                let l = asList(r)
                return (hintRegex(str(l[0])), str(l[1]))
            }
            hintCache[language] = rules
        }
        let folded = fold(text)
        var words: [String] = []
        for (r, en) in rules where r.has(folded) && !words.contains(en) { words.append(en) }
        return words.isEmpty ? text : "\(text.trimmed) (\(words.joined(separator: ", ")))"
    }

    private static let ptWords = re("(?:^|[^\\p{L}])(você|voce|não|desculpe|ouvir|isso|quer|obrigad[oa]|disponível)(?=$|[^\\p{L}])", ignoreCase: true)

    /// Basic language: a sentence the model said in Portuguese becomes "Sorry, could you say it again?" in the user's language; nil = keep.
    static func replyFix(_ sentence: String, _ language: String) -> String? {
        if !isBasic(language) || language.hasPrefix("pt") { return nil }
        if !ptWords.has(sentence) { return nil }
        return message(language, "didNotCatch")
    }
}
