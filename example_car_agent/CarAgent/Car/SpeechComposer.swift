import Foundation

// What the driver HEARS when one request did several car actions (the same as the other car apps' speech composer): the car tools' own
// sentences of actions that ran in a row become one natural sentence:
//   "I closed all the doors. I locked the car."  ->  "All set. I closed all the doors and locked the car. Everything is secure."
//   "Fechei todas as portas. Tranquei o carro."  ->  "Pronto, já fiz isso para você. Fechei todas as portas e tranquei o carro. Agora o carro está todo seguro."
// Nothing here decides an action. Only sentences of actions that really ran (recorded by the tool runner in this turn) are merged, word
// for word; anything else (a question, a refusal, an undo, a status answer) is said as it was. The history the model sees keeps the
// original sentences: only speech and the screen change.

struct CarTurnAction {
    let tool: String
    var say: String
    /// false: refused / failed / an undo: never merged
    let merge: Bool
    /// the call's arguments (picks the friendly closing line)
    var args: JObj = JObj()
    /// 'did' = changed the car; 'already' = it was already so; 'answer' = a lookup. Only 'did' gets the friendly words.
    var kind: String?
    /// the calls a plain "yes" to this reply runs (the result's offer, handled by the agent core), by name
    var offer: [String]?

    func withSay(_ s: String) -> CarTurnAction {
        var c = self
        c.say = s
        return c
    }
}

enum SpeechComposer {
    private static var turn: [CarTurnAction] = []
    private static var variant = 0
    private static var ackVariant = 0

    /// Call before each request.
    static func beginCarTurn() {
        turn.removeAll()
        BasicLanguage.beginTurn()
    }

    /// Called by the car tool runner with the sentence it returns.
    static func noteCarSay(_ tool: String, _ say: String, _ merge: Bool, args: JObj = JObj(), kind: String? = nil, offer: [String]? = nil) {
        if !say.trimmed.isEmpty { turn.append(CarTurnAction(tool: tool, say: say.trimmed, merge: merge, args: args, kind: kind, offer: offer)) }
    }

    static func carTurnActions() -> [CarTurnAction] { turn }

    /// Before beginCarTurn: the calls the previous request's offer runs on a plain "yes" (the core keeps it for one request), or nil.
    static func pendingOfferCalls() -> [String]? { turn.reversed().first { !($0.offer ?? []).isEmpty }?.offer }

    /// For tests: start the openers from the first one.
    static func resetVariant() {
        variant = 0
        ackVariant = 0
    }

    private static let openers = ["en": ["All set.", "Done.", "You got it."],
                                  "pt": ["Pronto, já fiz isso para você.", "Certo, já resolvi isso para você.", "Tudo certo, já cuidei disso para você."]]
    private static let secure = ["en": "Everything is secure.", "pt": "Agora o carro está todo seguro."]
    private static let closingTools: Set<String> = ["close_doors", "set_window", "set_sunroof", "set_trunk"]
    private static let lookupTools: Set<String> = ["get_vehicle_status", "get_trip_eta", "find_along_route"]

    // A friendlier voice: the same facts, word for word, with a warm opener and, every other time, a short closing line that fits the
    // action. Only for actions that really ran, tuned languages only.
    private static let friendlyOpeners = [
        "en": ["Sure, you got it.", "You got it!", "Consider it done!", "Alright, all set!", "There you go!"],
        "pt": ["Claro, já fiz isso para você.", "Pronto, já fiz isso para você.", "Certo, já resolvi isso para você.",
               "Tudo certo, já cuidei disso para você.", "Feito, já está tudo certinho agora."],
    ]

    /// What the car says while a request takes a moment.
    private static let acks = ["en": ["Got it.", "On it.", "One moment."],
                               "pt": ["Entendido, só um instante, por favor.", "Só um instante, já vou fazer isso.", "Pode deixar, só um instante, por favor."]]

    /// A short acknowledgement for a request that takes a moment, or nil (Basic languages keep their own flow).
    static func carAck(_ language: String) -> String? {
        let lang: String
        switch language {
        case "pt-BR": lang = "pt"
        case "en": lang = "en"
        default: return nil
        }
        let list = acks[lang]!
        defer { ackVariant += 1 }
        return list[ackVariant % list.count]
    }

    /// The closing line for an action that ran, or nil.
    private static func friendlyTail(_ a: CarTurnAction, _ lang: String, _ driving: Bool = false) -> String? {
        let g = a.args
        func t(_ en: String, _ pt: String) -> String { lang == "pt" ? pt : en }
        func n(_ v: JSON?) -> Double { numOf(v) ?? numOf(.str(str(v ?? 0))) ?? 0 }
        switch a.tool {
        case "unlock_car": return driving ? nil : t("Come on in!", "Pode entrar, o carro já está aberto.")
        case "lock_car": return t("You're good to go.", "Pode ficar tranquilo, está tudo seguro.")
        case "set_window": return g["position"] == "close" ? nil : t("Enjoy the fresh air.", "Aproveite o vento fresco da estrada.")
        case "set_sunroof": return g["action"] == "close" ? nil : t("Enjoy the view!", "Aproveite a vista lá de cima.")
        case "comfort_feeling":
            return g["feeling"] == "hot" ? t("It'll cool down in a minute.", "O carro vai refrescar em um minutinho.")
                : t("It'll feel cozier in a minute.", "Já já o carro fica mais quentinho.")
        case "set_temperature":
            if g["temperature"] != nil { return nil }
            let c = n(g["change"])
            return c > 0 ? t("It'll warm up soon.", "O carro vai esquentar em um minutinho.")
                : c < 0 ? t("It'll cool down soon.", "O carro vai refrescar em um minutinho.") : nil
        case "set_seat_climate":
            if g["level"] == "off" { return nil }
            return g["feature"] == "ventilation" ? t("That should cool you down.", "A ventilação do banco vai refrescar você.")
                : t("Nice and cozy.", "O assento vai ficar quentinho rapidinho.")
        case "set_steering_wheel_heater": return g["on"] == false ? nil : t("Warm hands coming up.", "O volante vai ficar quentinho rapidinho.")
        case "navigate_to": return t("Let's go!", "Vamos lá, tenha uma ótima viagem!")
        case "play_media", "tune_radio": return t("Enjoy the music!", "Aproveite a música durante a viagem.")
        case "set_defrost": return g["on"] == false ? nil : t("You'll see clearly in a moment.", "O vidro vai desembaçar em um minutinho.")
        default: return nil
        }
    }

    private static func did(_ a: CarTurnAction) -> Bool { (a.kind ?? (lookupTools.contains(a.tool) ? "answer" : "did")) == "did" }

    // ---- how a tool sentence is SAID: the tools' sentences stay as they are in the history (the model was trained with them); only
    // the spoken wording is smoother. Same facts, same numbers; tuned languages.

    /// "airport" -> "the airport" (a common noun without its article); names, "home" and "my office" stay as they are.
    private static func enPlace(_ d: String) -> String {
        let p = d.replacingOccurrences(of: "_", with: " ").trimmed
        return re("^[a-z]").has(p) && !re("^(the|a|an|my|your|our|his|her|their|work|downtown)\\b").has(p) && !re("'s\\b").has(p) ? "the \(p)" : p
    }

    /// "aeroporto" -> (to: "o aeroporto", at: "no aeroporto"); "casa" -> (to: "casa", at: "em casa"); "São Paulo" stays.
    private static func ptPlace(_ d: String) -> (to: String, at: String) {
        let p = d.replacingOccurrences(of: "_", with: " ").trimmed
        if re("^casa$", ignoreCase: true).has(p) { return ("casa", "em casa") }
        if let art = re("^(o|a|os|as) (.+)$", ignoreCase: true).find(p) {
            let into = ["o": "no", "a": "na", "os": "nos", "as": "nas"]
            return (p, "\(into[art.gs(1).lowercased()] ?? "null") \(art.gs(2))")
        }
        if re("^[a-zà-ü]").has(p) && !re("^(um|uma|meu|minha|meus|minhas|seu|sua|nosso|nossa)\\b", ignoreCase: true).has(p) {
            let fem = re("(a|ção|dade|gem)$", ignoreCase: true).has(p.splitSpace()[0])
            return ("\(fem ? "a" : "o") \(p)", "\(fem ? "na" : "no") \(p)")
        }
        return (p, "em \(p)")
    }

    /// The sentence as the driver hears it (or the tool's own sentence when nothing reads better).
    static func spokenSay(_ a: CarTurnAction, _ language: String) -> String {
        let s = a.say
        // an undo ("Undone. <the tool's sentence>"): said as putting it back, the sentence said like any other
        if let undo = re("^(Undone|Desfeito)\\. (.+)$", dotAll: true).find(s), language == "en" || language == "pt-BR" {
            return "\(language == "en" ? "Okay, I put it back." : "Pronto, voltei tudo como estava antes.") \(spokenSay(a.withSay(undo.gs(2)), language))"
        }
        let change = numOf(.str(str(a.args["change"] ?? 0))) ?? 0
        if a.tool == "find_along_route" && (a.offer?.contains("navigate_to") == true) && (language == "en" || language == "pt-BR") {
            return "\(s) \(language == "en" ? "Want me to take you there?" : "Quer que eu te leve até lá?")"
        }
        let sub: [(Rx, (RxMatch) -> String)]
        switch language {
        case "en":
            sub = [
                (re("^I set the whole cabin to (.+)$"), { "I set the temperature to \($0.gs(1))" }),
                (re("^I raised the whole cabin to (.+)$"), { "I turned the temperature up to \($0.gs(1))" }),
                (re("^I lowered the whole cabin to (.+)$"), { "I turned the temperature down to \($0.gs(1))" }),
                (re("^The whole cabin is already at (.+)$"), { "The temperature is already at \($0.gs(1))" }),
                (re("^I set the fan to level (\\d+)\\.$"), { m in
                    change > 0 ? "I turned the fan up to level \(m.gs(1))." : change < 0 ? "I turned the fan down to level \(m.gs(1))." : "I set the fan to level \(m.gs(1))."
                }),
                (re("^I set the (heater|ventilation) in (the .+? seat) to (\\w+)\\.$"), { "I set \($0.gs(2)) \($0.gs(1)) to \($0.gs(3))." }),
                (re("^I turned off the (heater|ventilation) in (the .+? seat)\\.$"), { "I turned off \($0.gs(2)) \($0.gs(1))." }),
                (re("^The (heater|ventilation) in (the .+? seat) is already (.+)$"), { "\(cap($0.gs(2))) \($0.gs(1)) is already \($0.gs(3))" }),
                (re("^I turned the (rear defogger|windshield defrost) (on|off)\\.$"), { "I turned \($0.gs(2)) the \($0.gs(1))." }),
                (re("^Navigating to (.+?): (.*)$"), { m in
                    m.gs(1) == "home" ? "Navigating home: \(m.gs(2))" : "Navigating to \(enPlace(m.gs(1))): \(m.gs(2))"
                }),
                (re("^You'll get to (.+?) in about (.*)$"), { m in
                    m.gs(1) == "home" ? "You'll get home in about \(m.gs(2))" : "You'll get to \(enPlace(m.gs(1))) in about \(m.gs(2))"
                }),
                (re("^(.*) Close them first\\?$"), { "\($0.gs(1)) Want me to close them first?" }),
                (re("^(.*) Close it first\\?$"), { "\($0.gs(1)) Want me to close it first?" }),
                (re("^I didn't change it: (.+) must be between (\\S+) and (\\S+)\\.$"), { m in
                    let w = m.gs(1)
                    return "Sorry, \(re("^(am|fm)$").matches(w) ? w.uppercased() : w == "volume" ? "the volume" : w) only goes from \(m.gs(2)) to \(m.gs(3))."
                }),
                (re("^I didn't change the temperature: both values must be between (\\S+) and (\\S+)\\.$"), {
                    "Sorry, the temperature only goes from \($0.gs(1)) to \($0.gs(2))."
                }),
                (re("^I can't do that while the car is moving\\.$"), { _ in "Sorry, I can't do that while we're moving." }),
            ]
        case "pt-BR":
            sub = [
                (re("^Coloquei a cabine toda em (.+)$"), { "Coloquei a temperatura em \($0.gs(1))" }),
                (re("^Subi a cabine toda para (.+)$"), { "Subi a temperatura para \($0.gs(1))" }),
                (re("^Baixei a cabine toda para (.+)$"), { "Baixei a temperatura para \($0.gs(1))" }),
                (re("^A cabine toda já está em (.+)$"), { "A temperatura já está em \($0.gs(1))" }),
                (re("^Coloquei a ventilação no nível (\\d+)\\.$"), { m in
                    change > 0 ? "Aumentei a ventilação para o nível \(m.gs(1))." : change < 0 ? "Baixei a ventilação para o nível \(m.gs(1))."
                        : "Coloquei a ventilação no nível \(m.gs(1))."
                }),
                (re("^Coloquei (o aquecimento|a ventilação) do banco (.+)$"), { "Liguei \($0.gs(1)) do banco \($0.gs(2))" }),
                (re("^Indo para (.+?): (.*)$"), { "Indo para \(ptPlace($0.gs(1)).to): \($0.gs(2))" }),
                (re("^Você chega em (.+?) em cerca de (.*)$"), { "Você chega \(ptPlace($0.gs(1)).at) em cerca de \($0.gs(2))" }),
                (re("^Não mudei: (.+) precisa ficar entre (\\S+) e (\\S+)\\.$"), { m in
                    let w = m.gs(1)
                    return "Desculpe, \(re("^(am|fm)$").matches(w) ? w.uppercased() : w) só vai de \(m.gs(2)) a \(m.gs(3))."
                }),
                (re("^Não mudei a temperatura: os dois valores precisam ficar entre (\\S+) e (\\S+)\\.$"), {
                    "Desculpe, a temperatura só vai de \($0.gs(1)) a \($0.gs(2))."
                }),
                (re("^Não posso fazer isso com o carro em movimento\\.$"), { _ in "Desculpe, não dá pra fazer isso com o carro em movimento." }),
            ]
        default:
            return s
        }
        for (r, to) in sub {
            if let m = r.find(s) { return to(m) }
        }
        return s
    }

    // pt-BR wording (2026-11-22, temporary until the pt-BR voice model is fixed; as the RN example): the speech library speaks one
    // sentence at a time and the pt-BR model drops or garbles short sentences said alone ("Claro!", "Tranquei o carro."). Every pt
    // sentence in this file was synthesized 5 times with the app's model and voice and understood 5/5 by speech-to-text; keep new ones
    // at about six words and test them. A short tool sentence said ON ITS OWN is said longer; a merged sentence stays as it is.
    // "vidros" is said as "janelas" here (the pt-BR model's "vidros" is heard as "vídeos"). Same list as the RN example's PT_LONGER.
    private static let ptLonger: [(Rx, (RxMatch) -> String)] = [
        (re("^Tranquei o carro\\.$"), { _ in "Tranquei todas as portas do carro." }),
        (re("^Destranquei o carro\\.$"), { _ in "Destranquei todas as portas do carro." }),
        (re("^Abri todas as portas\\.$"), { _ in "Abri todas as portas do carro." }),
        (re("^Fechei todas as portas\\.$"), { _ in "Fechei todas as portas para você." }),
        (re("^Abri todos os vidros\\.$"), { _ in "Abri todas as janelas do carro para você." }),
        (re("^Fechei todos os vidros\\.$"), { _ in "Fechei todas as janelas do carro." }),
        (re("^Abri o teto solar\\.$"), { _ in "Deixei o teto solar aberto para você." }),
        (re("^Fechei o teto solar\\.$"), { _ in "Fechei o teto solar para você." }),
        (re("^Inclinei o teto solar\\.$"), { _ in "Deixei o teto solar inclinado, como você pediu." }),
        (re("^Tocando (.+)\\.$"), { "Agora tocando \($0.gs(1)) para você." }),
        (re("^Sintonizei a rádio (\\S+)\\.$"), { "Sintonizei a rádio \($0.gs(1)) para você." }),
        (re("^(Liguei|Desliguei) o desembaçador traseiro\\.$"), { "\($0.gs(1)) o desembaçador traseiro para você." }),
    ]

    private static func ptLongerSentence(_ sentence: String) -> String {
        for (r, to) in ptLonger {
            if let m = r.find(sentence) { return to(m) }
        }
        return sentence
    }

    /// "A. B! C" -> ["A.", "B!", "C"]: a sentence ends at a word ending in . ! or ? ("2,1 km." and "87.5" stay whole).
    private static func sentencesOf(_ text: String) -> [String] {
        var out: [String] = []
        var cur: [String] = []
        for w in re("\\s+").split(text) where !w.isEmpty {
            cur.append(w)
            if re("[.!?]$").has(w) {
                out.append(cur.joined(separator: " "))
                cur = []
            }
        }
        if !cur.isEmpty { out.append(cur.joined(separator: " ")) }
        return out
    }

    /// One action that ran, said with a warm opener (none when the car already said "Got it.") and, every other time, its closing line.
    private static func friendlyOne(_ a: CarTurnAction, _ lang: String, _ acked: Bool, _ driving: Bool) -> String {
        // ONE friendly phrase (2026-11-25: opener + sentence + closing line made every reply long): every other time the closing line
        // when there is one, else a warm opener
        let v = variant
        variant += 1
        if v % 2 == 0, let tail = friendlyTail(a, lang, driving) { return "\(a.say) \(tail)" }
        let list = friendlyOpeners[lang]!
        let opener = acked ? "" : "\(list[v % list.count]) "
        return "\(opener)\(a.say)"
    }

    /// "I closed all the doors." -> "closed all the doors" (en); "Fechei todas as portas." -> "fechei todas as portas" (pt); else nil.
    private static func clause(_ say: String, _ pt: Bool) -> String? {
        let s = say.trimmed
        if !re("[.!]$").has(s) || re("[.!?]\\s").has(String(s.dropLast())) { return nil }
        let body = String(s.dropLast())
        if !pt { return re("^I (?:'ve |have )?([a-z].*)$").find(body)?.g(1) }
        let first = body.splitSpace()[0]
        if !re("^[A-ZÁÉÍÓÚÂÊÔÃÕ][a-záéíóúâêôãõç]*i$").matches(first) { return nil }
        return body.prefix(1).lowercased() + body.dropFirst()
    }

    private static func join(_ parts: [String], _ pt: Bool) -> String {
        parts.count == 1 ? parts[0] : "\(parts.dropLast().joined(separator: ", ")) \(pt ? "e" : "and") \(parts.last!)"
    }

    private static func merged(_ run: [CarTurnAction], _ pt: Bool, _ friendly: Bool, _ driving: Bool) -> String? {
        let parts = run.map { clause($0.say, pt) }
        let lang = pt ? "pt" : "en"
        let secures = run.contains { $0.tool == "lock_car" } && run.contains { closingTools.contains($0.tool) }
        let list = openers[lang]!
        if parts.contains(where: { $0 == nil }) {
            // sentences that don't merge ("All the windows are already closed.", "Navigating to ..."): one after the other after the
            // opener, when at least one action ran and the rest were already so
            if !friendly || !run.contains(where: did) || !run.allSatisfy({ did($0) || $0.kind == "already" }) { return nil }
            let opener = list[variant % list.count]
            variant += 1
            return "\(opener) \(run.map(\.say).joined(separator: " "))\(secures ? " \(secure[lang]!)" : "")"
        }
        let opener = list[variant % list.count]
        variant += 1
        let body = join(parts.map { $0! }, pt)
        let sentence = pt ? body.prefix(1).uppercased() + body.dropFirst() : "I \(body)"
        // the friendly closing line of the last action that has one ("I unlocked the car and opened all the doors. Come on in!")
        var tail: String?
        if !secures && friendly && run.allSatisfy(did) {
            for a in run.reversed() {
                tail = friendlyTail(a, lang, driving)
                if tail != nil { break }
            }
        }
        // one extra phrase at most (2026-11-25, the reply is said before the driver can talk again): the closing line, else the opener
        let extra = secures ? secure[lang] : tail
        if let extra { return "\(sentence). \(extra)" }
        return "\(opener) \(sentence)."
    }

    /// The reply text as the driver should hear it. text = what the agent said (core order); actions = this turn's tool sentences.
    static func composeCarSpeech(_ text: String, _ actions: [CarTurnAction], _ language: String, acked: Bool = false, driving: Bool = false) -> String {
        let pt = language.lowercased().hasPrefix("pt")
        // the friendlier voice: the tuned languages only (a Basic language says its own short "done")
        let friendly = language == "en" || language == "pt-BR"
        var pending = actions
        var segs: [(String, CarTurnAction?)] = []
        var rest = text.trimmed
        while !rest.isEmpty {
            if let i = pending.firstIndex(where: { rest.hasPrefix($0.say) }) {
                let found = pending.remove(at: i)
                rest = String(rest.dropFirst(found.say.count)).trimmedStart
                // the action as it is said (spokenSay): the same facts in smoother words; merging and the friendly words work on it
                let a = found.withSay(spokenSay(found, language))
                segs.append((a.say, a))
                continue
            }
            let piece = re("^.*?[.!?](?:\\s+|$)", dotAll: true).find(rest)?.value ?? rest
            segs.append((piece.trimmed, nil))
            rest = String(rest.dropFirst(piece.count)).trimmedStart
        }
        // friendly words only when everything said is the sentences of actions that ran (no refusal, question, undo or model text)
        let warm = friendly && segs.allSatisfy { $0.1?.merge == true }
        var out: [String] = []
        var i = 0
        while i < segs.count {
            if segs[i].1?.merge == true {
                var j = i
                while j < segs.count && segs[j].1?.merge == true { j += 1 }
                let run = segs[i..<j].map { $0.1! }
                var one: String?
                if run.count >= 2 { one = merged(run, pt, warm, driving) } else if warm && run.count == 1 && did(run[0]) {
                    one = friendlyOne(run[0], pt ? "pt" : "en", acked, driving)
                }
                let texts = segs[i..<j].map(\.0)
                out.append(one ?? texts.enumerated().filter { $0.offset == 0 || $0.element != texts[$0.offset - 1] }.map(\.element).joined(separator: " "))
                i = j
            } else {
                out.append(segs[i].0)
                i += 1
            }
        }
        // two confirmed actions in a Basic language both say "Erledigt.": once is enough
        let said = out.enumerated().filter { $0.offset == 0 || $0.element != out[$0.offset - 1] }.map(\.element).joined(separator: " ")
        return language == "pt-BR" ? sentencesOf(said).map(ptLongerSentence).joined(separator: " ") : said
    }
}
