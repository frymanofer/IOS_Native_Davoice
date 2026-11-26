import Foundation

// A question about the car's state is answered from the car itself (port of the other car apps' state answers; shared fixtures
// state_answers.json and car_dialogs.json): the model RAN the action for a question. "Is the car locked?" locked it, "Are the windows
// closed?" closed them. The answer says the state and offers the obvious change ("No, the car is unlocked. Want me to lock it?"): a yes
// sends that request to the agent (FollowUp), so the model runs a request it handles; nothing runs here. Only a question (question
// words, a state word and a part of the car together) is answered; anything else goes to the agent as before. Pure: the language and the
// car state are parameters. Tuned languages (en, pt-BR) only.

/// The reply, the request a plain yes sends to the agent (nil: nothing offered), and whether the reply asks where to go.
struct StateAnswer: Equatable {
    let reply: String
    var offer: String?
    var askDestination = false
}

enum StateAnswers {
    private static func has(_ f: String, _ p: String) -> Bool { re(p).has(f) }

    private static func list(_ items: [String], _ lang: String) -> String {
        items.count <= 1 ? items.joined() : "\(items.dropLast().joined(separator: ", ")) \(lang == "en" ? "and" : "e") \(items.last!)"
    }

    /// A position as the driver says it: the driver's / passenger window (door) by the car's steering side, else its place.
    private static func posName(_ p: String, _ obj: String, _ l: String, _ s: CarState) -> String {
        let driver = resolvePositions("driver", s.steering)![0]
        let passenger = resolvePositions("passenger", s.steering)![0]
        return positionName(p == driver ? "driver" : p == passenger ? "passenger" : p, obj, l).text
    }

    private static let FILLER = "^(?:(?:hey|so|um|uh|hmm|ok|okay|oi|ei|e ai|hum|entao|tipo) )*"
    private static let EN_Q = "^(?:is|are|was|were|did|do|does|have|has|what|what s|whats|where|how|which|can you (?:check|tell me|see)|could you (?:check|tell me|see)|do you know|i wonder|tell me)\\b"
    private static let PT_Q = "^(?:sera que|voce sabe|vc sabe|sabe|qual|quais|quanto|quantos|em quanto|que|o que|pra onde|para onde|onde|como|eu (?:tranquei|fechei|deixei|travei)|tranquei|fechei|deixei|travei|(?:(?:o|a|os|as) )?(?:meu |minha |meus |minhas )?(?:carro|vidro|vidros|janela|janelas|porta|portas|teto|aquecimento|ventilacao|banco|volume|som|temperatura|ar)\\b)"
    private static let EN_WH = "^(?:what s|whats|what is|what|how|which|tell me|can you tell me|could you tell me|do you know)\\b"
    private static let PT_WH = "^(?:qual|quais|em quanto|quanto|como|sera que|voce sabe|vc sabe|sabe|(?:ta|esta) em quanto)\\b"

    /// A question with a request after it ("What's the temperature? Set it to 22") goes to the agent.
    private static let EN_AND_DO = "\\b(?:set it|turn it|make it|put it|change it|lock it|close it|open it|close them|open them|and (?:set|turn|make|open|close|lock|unlock|play|raise|lower)|then)\\b"
    private static let PT_AND_DO = "\\b(?:coloca|poe|bota|muda|aumenta|abaixa|abre|fecha|tranca|destranca|liga|desliga|toca|esquenta|refresca)\\b"

    /// Polite requests are requests ("Can you open the window?"): not questions about the state.
    private static let EN_REQUEST = "^(?:can|could|would|will) you (?!check|tell me|see)|^would you mind|^please\\b"

    private static func isQuestion(_ raw: String, _ f: String, _ lang: String) -> Bool {
        let t = re(FILLER).replaceFirst(f, with: "")
        let endsQ = re("\\?\\s*$").has(raw)
        if lang == "en" { return !has(t, EN_REQUEST) && (has(t, EN_Q) || endsQ) }
        return has(t, PT_Q) || (endsQ &&
            !has(t, "^(?:abre|fecha|tranca|destranca|liga|desliga|deixa|coloca|poe|bota|aumenta|abaixa|esquenta|refresca|pode|voce pode|vc pode|da pra)\\b"))
    }

    private static func windowTarget(_ f: String, _ lang: String) -> String {
        if lang == "en" {
            if has(f, "\\b(my window|my side|driver s|drivers|driver)\\b") { return "driver" }
            if has(f, "\\b(passenger|passenger s)\\b") { return "passenger" }
            if has(f, "\\b(rear|back)\\b") { return "rear" }
            if has(f, "\\bfront\\b") { return "front" }
            return "all"
        }
        if has(f, "\\b(meu vidro|minha janela|meu lado|motorista)\\b") { return "driver" }
        if has(f, "\\b(passageiro|carona)\\b") { return "passenger" }
        if has(f, "\\b(de tras|traseiros?|traseiras?)\\b") { return "rear" }
        if has(f, "\\bda frente\\b") { return "front" }
        return "all"
    }

    private static func seatOf(_ f: String, _ lang: String) -> String {
        has(f, lang == "en" ? "\\b(passenger|passenger s)\\b" : "\\b(passageiro|carona)\\b") ? "passenger" : "driver"
    }

    private static let enLevel = ["low": "low", "medium": "medium", "high": "high"]
    private static let ptLevel = ["low": "baixo", "medium": "médio", "high": "alto"]
    private static let enSeatName = ["driver": "the driver's seat", "passenger": "the passenger seat"]
    private static let ptSeatName = ["driver": "do banco do motorista", "passenger": "do banco do passageiro"]

    private static func lock(_ s: CarState, _ lang: String, _ askedUnlocked: Bool) -> StateAnswer {
        let open = positions.filter { s.doorLocks[$0] != true }
        let all = open.isEmpty
        let none = open.count == 4
        let yes = askedUnlocked ? !all : all
        if lang == "en" {
            let offer = "Lock the car"
            if all { return StateAnswer(reply: "\(yes ? "Yes" : "No"), the car is locked.") }
            if none { return StateAnswer(reply: "\(yes ? "Yes" : "No"), the car is unlocked. Want me to lock it?", offer: offer) }
            let doors = open.map { posName($0, "door", "en", s) }
            return StateAnswer(reply: "Not completely: \(list(doors, lang)) \(doors.count > 1 ? "are" : "is") unlocked. Want me to lock the car?", offer: offer)
        }
        let offer = "Tranca o carro"
        if all { return StateAnswer(reply: "\(yes ? "Sim" : "Não"), o carro está trancado.") }
        if none { return StateAnswer(reply: "\(yes ? "Sim" : "Não"), o carro está destrancado. Quer que eu tranque?", offer: offer) }
        let doors = open.map { posName($0, "door", "pt-BR", s) }
        return StateAnswer(reply: "Não totalmente: \(list(doors, lang)) \(doors.count > 1 ? "estão destrancadas" : "está destrancada"). Quer que eu tranque o carro?", offer: offer)
    }

    private static func allThe(_ text: String, _ lang: String) -> String {
        if lang == "en" {
            return re("^the ").replaceFirst(text, with: "all the ").replacingFirst("all the all the", with: "all the")
        }
        return re("^os ").replaceFirst(text, with: "todos os ").replacingFirst("todos os todos os", with: "todos os")
    }

    private static func windows(_ s: CarState, _ lang: String, _ target: String, _ askedOpen: Bool) -> StateAnswer {
        let l = lang == "en" ? "en" : "pt-BR"
        let ps = resolvePositions(.str(target), s.steering) ?? []
        let open = ps.filter { s.windows[$0] != "close" }
        let n = positionName(target, "window", l)
        if ps.count == 1 {
            let isOpen = open.count == 1
            let yes = askedOpen == isOpen
            if lang == "en" {
                return isOpen ? StateAnswer(reply: "\(yes ? "Yes" : "No"), \(n.text) is open. Want me to close it?", offer: "Close \(n.text)")
                    : StateAnswer(reply: "\(yes ? "Yes" : "No"), \(n.text) is closed.")
            }
            return isOpen ? StateAnswer(reply: "\(yes ? "Sim" : "Não"), \(n.text) está aberto. Quer que eu feche?", offer: "Fecha \(n.text)")
                : StateAnswer(reply: "\(yes ? "Sim" : "Não"), \(n.text) está fechado.")
        }
        if open.isEmpty {
            return lang == "en" ? StateAnswer(reply: "\(askedOpen ? "No" : "Yes"), \(allThe(n.text, lang)) are closed.")
                : StateAnswer(reply: "\(askedOpen ? "Não" : "Sim"), \(allThe(n.text, lang)) estão fechados.")
        }
        let names = open.map { posName($0, "window", l, s) }
        let one = open.count == 1
        let close = one ? "\(lang == "en" ? "Close" : "Fecha") \(names[0])" : "\(lang == "en" ? "Close" : "Fecha") \(n.text)"
        let allOpen = open.count == ps.count
        if lang == "en" {
            let what = allOpen ? "\(allThe(n.text, lang)) are open" : "\(list(names, lang)) \(one ? "is" : "are") open"
            return StateAnswer(reply: "\(askedOpen ? "Yes" : "No"), \(what). Want me to close \(one ? "it" : "them")?", offer: close)
        }
        let what = allOpen ? "\(allThe(n.text, lang)) estão abertos" : "\(list(names, lang)) \(one ? "está aberto" : "estão abertos")"
        return StateAnswer(reply: "\(askedOpen ? "Sim" : "Não"), \(what). Quer que eu feche?", offer: close)
    }

    private static func doors(_ s: CarState, _ lang: String, _ askedOpen: Bool) -> StateAnswer {
        let open = positions.filter { s.doors[$0] == "open" }
        if open.isEmpty {
            return StateAnswer(reply: lang == "en" ? "\(askedOpen ? "No" : "Yes"), all the doors are closed."
                : "\(askedOpen ? "Não" : "Sim"), todas as portas estão fechadas.")
        }
        let l = lang == "en" ? "en" : "pt-BR"
        let names = open.map { posName($0, "door", l, s) }
        let one = open.count == 1
        if lang == "en" {
            return StateAnswer(reply: "\(askedOpen ? "Yes" : "No"), \(list(names, lang)) \(one ? "is" : "are") open. Want me to close \(one ? "it" : "them")?",
                               offer: "Close the doors")
        }
        let n = positionName(open[0], "door", l)
        return StateAnswer(reply: "\(askedOpen ? "Sim" : "Não"), \(list(names, lang)) \(one ? "está \(adj("abert", n))" : "estão abertas"). Quer que eu feche?",
                           offer: "Fecha as portas")
    }

    private static func sunroof(_ s: CarState, _ lang: String, _ askedOpen: Bool) -> StateAnswer {
        let isOpen = s.sunroof != "close"
        let yes = askedOpen == isOpen
        if lang == "en" {
            if !isOpen { return StateAnswer(reply: "\(yes ? "Yes" : "No"), the sunroof is closed.") }
            return StateAnswer(reply: "\(yes ? "Yes" : "No"), the sunroof is \(s.sunroof == "tilt" ? "tilted open" : "open"). Want me to close it?",
                               offer: "Close the sunroof")
        }
        if !isOpen { return StateAnswer(reply: "\(yes ? "Sim" : "Não"), o teto solar está fechado.") }
        return StateAnswer(reply: "\(yes ? "Sim" : "Não"), o teto solar está \(s.sunroof == "tilt" ? "inclinado" : "aberto"). Quer que eu feche?",
                           offer: "Fecha o teto solar")
    }

    private static func seat(_ s: CarState, _ lang: String, _ seat: String, _ feature: String, _ askedOn: Bool) -> StateAnswer {
        let level = (feature == "heater" ? s.seatHeater : s.seatVentilation)[seat] ?? "off"
        let on = level != "off"
        let yes = askedOn == on
        if lang == "en" {
            let what = "\(enSeatName[seat] ?? "") \(feature == "heater" ? "heater" : "ventilation")"
            if on { return StateAnswer(reply: "\(yes ? "Yes" : "No"), \(what) is on \(enLevel[level] ?? "null").") }
            return StateAnswer(reply: "\(yes ? "Yes" : "No"), \(what) is off. Want me to turn it on?",
                               offer: "\(feature == "heater" ? "Heat" : "Cool") \(enSeatName[seat] ?? "")")
        }
        let what = "\(feature == "heater" ? "o aquecimento" : "a ventilação") \(ptSeatName[seat] ?? "")"
        if on { return StateAnswer(reply: "\(yes ? "Sim" : "Não"), \(what) está \(feature == "heater" ? "ligado" : "ligada") no \(ptLevel[level] ?? "null").") }
        return StateAnswer(
            reply: "\(yes ? "Sim" : "Não"), \(what) está \(feature == "heater" ? "desligado" : "desligada"). Quer que eu ligue?",
            offer: "\(feature == "heater" ? "Esquenta" : "Refresca") o banco do \(seat == "driver" ? "motorista" : "passageiro")")
    }

    private static func num(_ v: Double, _ lang: String) -> String {
        let t = Json.num(v)
        return lang == "pt" ? t.replacingOccurrences(of: ".", with: ",") : t
    }

    private static func temperature(_ s: CarState, _ lang: String) -> StateAnswer {
        let u = s.unit == "fahrenheit" ? "°F" : "°C"
        let d = s.temperature["driver"] ?? 21
        let p = s.temperature["passenger"] ?? 21
        if d == p { return StateAnswer(reply: lang == "en" ? "It's set to \(num(d, lang))\(u)." : "Está em \(num(d, lang))\(u).") }
        return StateAnswer(reply: lang == "en" ? "The driver's side is set to \(num(d, lang))\(u) and the passenger side to \(num(p, lang))\(u)."
            : "O lado do motorista está em \(num(d, lang))\(u) e o do passageiro em \(num(p, lang))\(u).")
    }

    private static func media(_ s: CarState, _ lang: String) -> StateAnswer {
        let muted = s.muted ? (lang == "en" ? ", but the sound is muted" : ", mas o som está no mudo") : ""
        if let m = s.media { return StateAnswer(reply: lang == "en" ? "You're listening to \(m)\(muted)." : "Você está ouvindo \(m)\(muted).") }
        if let r = s.radio { return StateAnswer(reply: lang == "en" ? "You're listening to \(r)\(muted)." : "Você está ouvindo a rádio \(r)\(muted).") }
        return StateAnswer(reply: lang == "en" ? "Nothing's playing right now." : "Não tem nada tocando agora.")
    }

    private static func destination(_ s: CarState, _ lang: String) -> StateAnswer {
        guard let d = s.destination else {
            return StateAnswer(reply: lang == "en" ? "There's no active route. Where do you want to go?" : "Não há nenhuma rota ativa. Para onde você quer ir?",
                               offer: nil, askDestination: true)
        }
        if lang == "en" {
            if d == "home" { return StateAnswer(reply: "We're heading home.") }
            let p = re("^[a-z]").has(d) && !re("^(the|a|an|my|your|our|work|downtown)\\b").has(d) ? "the \(d)" : d
            return StateAnswer(reply: "We're heading to \(p).")
        }
        if d == "casa" { return StateAnswer(reply: "Estamos indo para casa.") }
        let p = re("^[a-zà-ü]").has(d) && !re("^(o|a|os|as|um|uma|meu|minha)\\b").has(d)
            ? "\(re("(a|ção|dade|gem)$").has(d.splitSpace()[0]) ? "a" : "o") \(d)" : d
        return StateAnswer(reply: "Estamos indo para \(p).")
    }

    /// The answer to a question about the car's state, or nil (not such a question: the agent gets it).
    static func answer(_ userText: String, _ language: String, _ s: CarState) -> StateAnswer? {
        let lang: String
        switch language {
        case "en": lang = "en"
        case "pt-BR": lang = "pt"
        default: return nil
        }
        let f = BasicLanguage.fold(userText)
        if f.isEmpty || f.splitSpace().count > 14 || !isQuestion(userText, f, lang) { return nil }
        // a second sentence ("Is the car locked? Lock it") or a request in it: the agent decides
        if re("[.?!;]\\s*\\S").has(re("[.?!]+$").replaceFirst(userText.trimmed, with: "")) || has(f, lang == "en" ? EN_AND_DO : PT_AND_DO) {
            return nil
        }
        let t = re(FILLER).replaceFirst(f, with: "")
        if lang == "en" {
            let outside = has(f, "\\b(outside|outdoors?|out there|weather|today|tomorrow|tonight|forecast)\\b")
            if has(f, "\\b(locked|unlocked)\\b") || has(f, "\\b(?:did|have) (?:i|you) lock\\b") { return lock(s, lang, has(f, "\\bunlocked\\b")) }
            if has(f, "\\bwindows?\\b") && has(f, "\\b(open|opened|closed|shut|up|down|cracked)\\b") {
                return windows(s, lang, windowTarget(f, lang), has(f, "\\b(open|opened|down|cracked)\\b"))
            }
            if has(f, "\\bdoors?\\b") && has(f, "\\b(open|opened|closed|shut|ajar)\\b") { return doors(s, lang, has(f, "\\b(open|opened|ajar)\\b")) }
            if has(f, "\\bsun ?roof\\b") && has(f, "\\b(open|opened|closed|shut)\\b") { return sunroof(s, lang, has(f, "\\b(open|opened)\\b")) }
            if has(f, "\\bseats?\\b") && has(f, "\\b(heater|heaters|heating|heated|warmer|warmers)\\b") && has(f, "\\b(on|off|running|working)\\b") {
                return seat(s, lang, seatOf(f, lang), "heater", !has(f, "\\boff\\b"))
            }
            if has(f, "\\bseats?\\b") && has(f, "\\b(ventilation|ventilated|cooling|cooler|fans?)\\b") && has(f, "\\b(on|off|running|working)\\b") {
                return seat(s, lang, seatOf(f, lang), "ventilation", !has(f, "\\boff\\b"))
            }
            if !outside && (has(f, "\\b(temperature|temp)\\b") && has(t, EN_WH) || has(t, "^how (?:warm|hot|cold) is it (?:set|in here)\\b")) {
                return temperature(s, lang)
            }
            if has(t, EN_WH) && has(t, "\\bvolume\\b|^how loud\\b") { return StateAnswer(reply: s.muted ? "The sound is muted." : "The volume is at \(s.volume).") }
            if has(t, EN_WH) && has(f, "\\bfan\\b") && !has(f, "\\bseat\\b") { return StateAnswer(reply: "The fan is at level \(s.fan).") }
            if has(t, "^(?:what s playing|whats playing|what is playing|what song is (?:this|playing)|what am i listening to|what station is (?:this|on)|what s on the radio|who s (?:singing|playing)|who is (?:singing|playing)|what music is (?:this|playing))\\b") {
                return media(s, lang)
            }
            if has(t, "^(?:where are we (?:going|headed|heading)|what s (?:my|our|the) destination|what is (?:my|our|the) destination|where am i (?:going|headed|heading))\\b") {
                return destination(s, lang)
            }
            return nil
        }
        let outside = has(f, "\\b(la fora|fora|lado de fora|tempo|clima|hoje|amanha|previsao)\\b")
        if has(f, "\\b(trancad[oa]s?|destrancad[oa]s?|travad[oa]s?|destravad[oa]s?|tranquei|travei|trancou|travou)\\b") {
            return lock(s, lang, has(f, "\\b(destrancad|destravad)"))
        }
        if has(f, "\\bcarro\\b") && has(f, "\\b(abert[oa]|fechad[oa])\\b") && !has(f, "\\b(vidros?|janelas?|portas?|teto)\\b") {
            return lock(s, lang, has(f, "\\babert"))
        }
        if has(f, "\\b(vidros?|janelas?)\\b") && has(f, "\\b(abert[oa]s?|fechad[oa]s?|abaixad[oa]s?|levantad[oa]s?|fechei)\\b") {
            return windows(s, lang, windowTarget(f, lang), has(f, "\\b(abert|abaixad)"))
        }
        if has(f, "\\bportas?\\b") && has(f, "\\b(abert[oa]s?|fechad[oa]s?|fechei)\\b") { return doors(s, lang, has(f, "\\babert")) }
        if has(f, "\\bteto( solar)?\\b") && has(f, "\\b(abert[oa]|fechad[oa])\\b") { return sunroof(s, lang, has(f, "\\babert")) }
        if has(f, "\\bbancos?\\b") && has(f, "\\b(aquecimento|aquecid[oa]|esquentando)\\b") && has(f, "\\b(ligad[oa]|desligad[oa]|esquentando|funcionando)\\b") {
            return seat(s, lang, seatOf(f, lang), "heater", !has(f, "\\bdesligad"))
        }
        if has(f, "\\bbancos?\\b") && has(f, "\\b(ventilacao|ventilad[oa])\\b") && has(f, "\\b(ligad[oa]|desligad[oa]|funcionando)\\b") {
            return seat(s, lang, seatOf(f, lang), "ventilation", !has(f, "\\bdesligad"))
        }
        if !outside && (has(f, "\\btemperatura\\b") && has(t, PT_WH) || has(t, "^(?:ta|esta) em quantos graus\\b|^quantos graus\\b")) {
            return temperature(s, lang)
        }
        if has(f, "\\b(volume|som)\\b") && has(t, PT_WH) && !has(f, "\\b(musica|tocando)\\b") {
            return StateAnswer(reply: s.muted ? "O som está no mudo." : "O volume está em \(s.volume).")
        }
        if has(t, PT_WH) && has(f, "\\b(ventilacao|ventilador)\\b") && !has(f, "\\bbanco") { return StateAnswer(reply: "A ventilação está no nível \(s.fan).") }
        if has(t, "^(?:o que (?:ta|esta) tocando|que musica (?:e essa|e esta|ta tocando|esta tocando)|qual (?:e )?(?:a )?musica|que radio (?:e essa|e esta)|qual (?:e )?(?:a )?radio|qual (?:e )?(?:a )?estacao|o que (?:eu )?(?:to|tou|estou) ouvindo|quem (?:ta|esta) cantando|quem canta)\\b") {
            return media(s, lang)
        }
        if has(t, "^(?:pra onde|para onde|onde) (?:a gente |nos )?(?:ta|esta|estamos|tamos|vamos|vai)(?: indo)?\\b|^qual (?:e )?o (?:meu |nosso )?destino\\b") {
            return destination(s, lang)
        }
        return nil
    }
}

extension String {
    /// Kotlin's String.replaceFirst(String, String): the first occurrence of a literal.
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let r = range(of: target) else { return self }
        return replacingCharacters(in: r, with: replacement)
    }
}
