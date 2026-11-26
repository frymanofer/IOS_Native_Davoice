import Foundation

// What the driver says right after the agent's own question or offer (the same rules and lists as the other car apps' follow-up;
// shared fixture follow_up.json):
//  - an answer to the agent's question goes to the agent WITH the request it answers ("Which window should I open?" -> "The driver's
//    one" = "Open the window, the driver's one"; "Where do you want to go?" -> "The airport" = "Navigate to the airport").
//  - "never mind", "cancel", "stop", "no" with nothing pending: a short "Okay." (with an offer pending they go to the agent core).
//  - an offer pending: more ways to say yes ("tá bom", "sounds good") reach the core as its plain "yes"; "take me there" accepts a
//    navigation offer.
//  - a question about the car ("Is the car locked?") is answered from the car (StateAnswers).
//  - "Say that again" / "What?" / "Repete": the last reply again.
//  - requests the model gets wrong every time are said the way it handles them ("Turn on the seat heater" -> "Heat the seat").
// Nothing here runs an action. Tuned languages (en, pt-BR) only: the Basic languages have their own yes / no flow.

/// What goes to the agent (text), or the app's own short reply (reply).
struct TurnInput: Equatable {
    var text: String?
    var reply: String?
}

enum FollowUp {
    private static func tuned(_ language: String) -> String? {
        switch language {
        case "en": return "en"
        case "pt-BR": return "pt"
        default: return nil
        }
    }

    private static func fold(_ s: String) -> String { BasicLanguage.fold(s) }

    private static var onlyCache: [String: Rx] = [:]

    private static func only(_ text: String, _ phrases: [String]) -> Bool {
        let t = fold(text)
        if t.isEmpty { return false }
        let key = phrases.joined(separator: "|")
        let r: Rx
        if let c = onlyCache[key] { r = c } else {
            r = Rx("^(?:(?:\(phrases.sorted { $0.count > $1.count }.joined(separator: "|")))(?: |$))+$")
            onlyCache[key] = r
        }
        return r.has(t)
    }

    private static func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        let t = " \(fold(text)) "
        return phrases.contains { t.contains(" \($0) ") }
    }

    private static let dismiss = [
        "en": ["never mind", "nevermind", "forget it", "forget about it", "forget that", "cancel", "cancel that", "cancel it", "stop", "stop it",
               "nothing", "no", "nope", "nah", "no thanks", "no thank you", "not now", "leave it", "that s all", "that s it", "all good", "i m good",
               "i m fine", "no worries", "don t", "don t bother", "thanks", "okay", "ok", "oh"],
        "pt": ["deixa pra la", "deixa para la", "deixa", "deixa assim", "esquece", "esquece isso", "cancela", "cancelar", "cancela isso", "para",
               "pare", "nada", "nada nao", "nao", "nao precisa", "nao obrigado", "nao obrigada", "agora nao", "melhor nao", "so isso", "e so isso",
               "obrigado", "obrigada", "valeu", "ok", "ta"],
    ]
    private static let dismissCore = [
        "en": ["never mind", "nevermind", "forget it", "forget about it", "forget that", "cancel", "cancel that", "cancel it", "stop", "stop it",
               "nothing", "no", "nope", "nah", "no thanks", "no thank you", "not now", "leave it", "that s all", "that s it", "don t", "don t bother"],
        "pt": ["deixa pra la", "deixa para la", "deixa", "deixa assim", "esquece", "esquece isso", "cancela", "cancelar", "cancela isso", "para",
               "pare", "nada", "nada nao", "nao", "nao precisa", "nao obrigado", "nao obrigada", "agora nao", "melhor nao", "so isso", "e so isso"],
    ]
    private static let dismissReply = ["en": ["Okay.", "No problem."],
                                       "pt": ["Tudo bem, então não vou fazer nada.", "Sem problema, fica para uma próxima vez."]]
    private static let yes = [
        "en": ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "please", "go ahead", "do it", "sounds good", "go for it", "please do",
               "sure thing", "why not", "let s do it", "of course", "absolutely", "alright", "all right", "perfect", "great", "cool",
               "that would be great", "yes please"],
        "pt": ["sim", "claro", "pode", "isso", "bora", "por favor", "faz isso", "pode ser", "com certeza", "certo", "quero", "ta bom", "ta",
               "beleza", "fechado", "manda", "manda ver", "vai", "uhum", "aham", "pode sim", "ok", "perfeito", "otimo", "show", "demorou",
               "quero sim"],
    ]
    private static let goThere = [
        "en": ["take me there", "go there", "navigate there", "let s go there", "let s go", "drive there", "navigate to it", "take me", "go",
               "yes take me there", "sure take me there", "ok take me there", "okay take me there", "yes please take me there"],
        "pt": ["me leva la", "me leva", "leva eu la", "me leve la", "vamos la", "vai la", "navega pra la", "navega para la", "bora la", "quero ir",
               "partiu", "sim me leva la", "pode me levar", "pode me levar la", "me leva ate la"],
    ]
    private static let commandStart = [
        "en": re("^(open|close|shut|turn|set|play|lock|unlock|navigate|take|find|raise|lower|increase|decrease|put|make|start|stop|switch|tune|mute|unmute|call|what|how|where|when|who|why|is|are|can|could|do|does|please|i|it|its|undo|cancel|show|tell|give|heat|cool|warm|defrost|avoid|go)( |$)"),
        "pt": re("^(abre|abra|abrir|fecha|feche|fechar|liga|ligue|ligar|desliga|desligue|coloca|coloque|poe|bota|toca|toque|tocar|tranca|tranque|destranca|navega|navegue|leva|me|acha|procura|aumenta|abaixa|baixa|diminui|sobe|muda|troca|sintoniza|silencia|o que|como|onde|quando|quem|quanto|quantos|quantas|por que|pode|voce|vc|eu|esta|ta|to|faz|deixa|desfaz|esquenta|esfria|desembaca|evita|vai)( |$)"),
    ]
    private static let lowerFirst: [String: Set<String>] = [
        "en": ["the", "a", "an", "to", "my", "mine", "both", "yours", "your", "his", "her", "our", "all", "front", "rear", "back", "left",
               "right", "passenger", "driver", "driver s", "just", "only", "some", "everyone", "everybody"],
        "pt": ["o", "a", "os", "as", "pro", "pra", "para", "pros", "pras", "meu", "minha", "dois", "ambos", "todos", "todas", "do", "da",
               "no", "na", "so", "apenas", "frente", "tras", "esquerdo", "direito", "passageiro", "motorista", "um", "uma", "algum", "alguma"],
    ]

    /// "Stop" while music plays means the music.
    private static let stopMusic = [
        "en": ["stop", "stop it", "pause", "pause it", "stop the music", "pause the music", "stop music", "stop playing", "enough", "please stop", "stop please"],
        "pt": ["para", "pare", "pausa", "pausar", "para a musica", "para o som", "pausa a musica", "para de tocar", "chega", "para por favor", "por favor para"],
    ]

    /// The seat in an answer to "Which seat: yours, the passenger's, or both?" (checked in this order on the folded answer).
    private static let seatAnswer: [String: [(Rx, String)]] = [
        "en": [
            (re("\\b(both|everyone|all|the two|both of us)\\b"), "both"),
            (re("\\b(passenger|passenger s|his|hers|her|him|the other one|my wife s|my husband s)\\b"), "passenger"),
            (re("\\b(mine|me|my|myself|driver|driver s|yours)\\b"), "driver"),
        ],
        "pt": [
            (re("\\b(os dois|ambos|todos|dos dois|nos dois|as duas)\\b"), "both"),
            (re("\\b(carona|passageiro|dele|dela|o outro)\\b"), "passenger"),
            (re("\\b(meu|o meu|eu|mim|motorista|o seu)\\b"), "driver"),
        ],
    ]
    private static let seatWords = [
        "en": ["driver": "the driver's seat", "passenger": "the passenger seat", "both": "both front seats"],
        "pt": ["driver": "o banco do motorista", "passenger": "o banco do passageiro", "both": "os dois bancos da frente"],
    ]

    /// The request with the seat put in (nil: no seat word to replace).
    private static func withSeat(_ request: String, _ seat: String, _ lang: String) -> String? {
        let r = re("[.!?]+$").replace(request.trimmed, with: "")
        let f = fold(r)
        let off = lang == "en" ? re("\\b(off|stop|disable|deactivate)\\b").has(f) : re("\\b(desliga|desligar|desligue|desativa|para)\\b").has(f)
        let level = re("\\b(low|medium|high|max|maximum|min|minimum|level|baixo|medio|alto|maximo|minimo|nivel|\\d+)\\b").has(f)
        let heat = lang == "en" ? re("\\b(heat|heater|heaters|heated|heating|warm|warmer)\\b").has(f) : re("\\b(esquent\\w*|aquec\\w*|quent\\w*)\\b").has(f)
        let cool = lang == "en" ? re("\\b(cool|cooler|cooling|vent|ventilate|ventilation|ventilated)\\b").has(f)
            : re("\\b(ventil\\w*|refresc\\w*|esfri\\w*|fresc\\w*)\\b").has(f)
        let words = seatWords[lang]!
        if !off && !level && heat != cool {
            let verb = lang == "en" ? (heat ? "heat" : "cool") : (heat ? "esquenta" : "refresca")
            func one(_ k: String) -> String { "\(verb) \(words[k]!)" }
            let said = seat == "both" ? "\(one("driver")) \(lang == "en" ? "and" : "e") \(one("passenger"))" : one(seat)
            return cap(said)
        }
        let w = words[seat]!
        func swap(_ rx: Rx, _ to: (RxMatch) -> String) -> String? { rx.has(r) ? rx.replaceFirst(r, to) : nil }
        if lang == "en" {
            return swap(re("\\b(the |my |our )?seats\\b", ignoreCase: true)) { _ in w }
                ?? swap(re("\\b(the |my )?seat (heaters?|ventilation)\\b", ignoreCase: true)) { m in
                    let what = m.gs(2)
                    return seat == "both" ? "both front seat \(what.hasPrefix("heater") ? "heaters" : "ventilation")" : "\(w) \(re("s$").replace(what, with: ""))"
                }
                ?? swap(re("\\b(the |my )?seat\\b", ignoreCase: true)) { _ in w }
        }
        return swap(re("\\b(os|o|meus|meu) bancos?\\b", ignoreCase: true)) { _ in w }
            ?? swap(re("\\bdos? bancos?\\b", ignoreCase: true)) { _ in seat == "both" ? "dos dois bancos da frente" : "d\(w)" }
    }

    /// "Say that again": the last reply again.
    private static let repeatPhrases = [
        "en": ["what", "what did you say", "what was that", "say that again", "say it again", "repeat", "repeat that", "repeat it", "come again",
               "pardon", "pardon me", "sorry what", "huh", "i didn t hear you", "i didn t hear that", "i didn t catch that", "can you repeat that",
               "could you repeat that", "can you say that again", "could you say that again", "please repeat", "one more time", "what was that again"],
        "pt": ["o que", "o que voce disse", "o que vc disse", "o que foi", "o que foi que voce disse", "repete", "repete ai", "repete por favor",
               "pode repetir", "fala de novo", "fala de novo por favor", "como", "como e que e", "hein", "nao ouvi", "nao escutei", "nao entendi",
               "fala outra vez", "repete isso"],
    ]

    /// "Next song" while music plays: this demo has no track control.
    private static let skip = [
        "en": ["skip", "skip it", "skip this", "skip this song", "skip the song", "skip song", "next", "next song", "next track", "next one",
               "play the next song", "play the next one", "previous song", "previous track", "go back a song", "last song"],
        "pt": ["pula", "pula essa", "pula essa musica", "pula a musica", "proxima", "proxima musica", "proxima faixa", "passa", "passa essa",
               "passa a musica", "musica anterior", "volta a musica", "toca a proxima"],
    ]

    /// A bare "Turn it off" / "Desliga" with nothing to refer to.
    private static let bareOff = [
        "en": ["turn it off", "turn that off", "switch it off", "turn off", "switch off", "shut it off", "off"],
        "pt": ["desliga", "desliga isso", "desliga ele", "desliga ela", "desligar", "desliga ai", "apaga", "apaga isso"],
    ]
    private static let bareOn = [
        "en": ["turn it on", "turn that on", "switch it on", "turn on", "switch on", "on"],
        "pt": ["liga", "liga isso", "liga ele", "liga ela", "ligar", "liga ai", "acende", "acende isso"],
    ]
    private static let askWhat = [
        "en": ["off": ("What should I turn off?", "Turn off"), "on": ("What should I turn on?", "Turn on")],
        "pt": ["off": ("O que você quer que eu desligue?", "Desliga"), "on": ("O que você quer que eu ligue?", "Liga")],
    ]
    private static let whichSeat = ["en": "Which seat: yours, the passenger's, or both?", "pt": "Qual banco: o seu, o do carona ou os dois?"]

    /// The driver's words, said the way the model handles them (nil: as they are).
    private static func canonical(_ userText: String, _ lang: String) -> String? {
        let f = fold(userText)
        let t = userText.replacingOccurrences(of: "’", with: "'")
        if lang == "en" {
            if re("^(?:please )?(?:turn |put |set |crank )?(?:the )?(?:volume|music|sound|it) (?:all the way up|(?:up )?to (?:the )?max(?:imum)?|(?:at |on )?max(?:imum)?)(?: please)?$|^(?:please )?max(?:imum)? volume(?: please)?$").has(f) {
                return "Set the volume to 30"
            }
            if re("^(?:please )?turn on (?:the |our )?seat heaters (?:for )?(?:both of us|both|everyone)(?: please)?$").has(f) {
                return "Heat the driver's seat and heat the passenger seat"
            }
            if re("^(?:please )?lock (?:it )?(?:up|everything)(?: please)?$").has(f) { return "Lock the car" }
            if re("^(?:please )?close (?:everything|it all|all of it|up everything)(?: please)?$").has(f) { return "Close all the windows and the sunroof" }
            if re("^(?:please )?turn (?:on|off) the lights(?: please)?$").has(f) {
                return f.contains(" off ") ? "Turn off the cabin lights" : "Turn on the cabin lights"
            }
            if let warm = re("^(?:a bit |a little |slightly )?(warmer|hotter|cooler|colder)(?: please)?$").find(f) {
                return re("warmer|hotter").has(warm.gs(1)) ? "Make it warmer" : "Make it cooler"
            }
            if re("^(?:is )?(?:everything|all) (?:ok|okay|alright|all right|fine|good) with the car$|^is the car (?:ok|okay|alright|all right|fine)$|^how s the car(?: doing)?$|^car status$").has(f) {
                return "Are there any warning lights?"
            }
            // "No, I said the passenger window" was ignored (no reply at all); "No, the passenger window" runs
            if let said = re("^(?:no,? |nope,? )?i (?:said|meant|mean)\\s+(.+)$", ignoreCase: true).find(t.trimmed), fold(said.gs(1)).splitSpace().count <= 8 {
                return "No, \(said.gs(1))"
            }
            let seat = re("\\bturn(ing)? on (the |my |our )?(driver's |drivers |passenger's |passenger )?seat (heater|heating|warmer)(s?)\\b", ignoreCase: true)
            if seat.has(t) && !re("\\b(low|medium|high|max|maximum|level|\\d+)\\b").has(f) {
                let replaced = seat.replaceFirst(t) { m in
                    let who = m.g(3)
                    let whose = who != nil ? (re("^driver", ignoreCase: true).has(who!) ? "the driver's " : "the passenger ") : (m.g(2) ?? "the ").lowercased()
                    return "heat\(m.g(1) != nil ? "ing" : "") \(whose)seat\(!(m.g(5) ?? "").isEmpty && who == nil ? "s" : "")"
                }
                return re("^heat").replaceFirst(replaced, with: "Heat")
            }
            return nil
        }
        if re("^(?:coloca |poe |bota |deixa |aumenta )?(?:o )?(?:volume|som)(?: (?:no|ao|ate o|em|pro|para o) (?:maximo|talo)| maximo)(?: por favor)?$|^aumenta (?:o volume |o som |tudo )?(?:no|ao|ate o) (?:maximo|talo)(?: por favor)?$").has(f) {
            return "Coloca o volume em 30"
        }
        if re("^(?:por favor )?fecha tudo(?: por favor)?$").has(f) { return "Fecha todos os vidros e o teto solar" }
        if re("^(?:por favor )?(?:acende|liga) as luzes(?: por favor)?$").has(f) { return "Liga a luz ambiente" }
        if re("^(?:da pra |pode |voce pode |vc pode )?deixa(?:r)? (?:o carro |aqui )?(?:um pouco |um pouquinho )?mais fresco(?: por favor)?$").has(f) {
            return "Esfria um pouco"
        }
        if re("^(?:(?:ta|esta) tudo (?:certo|bem|ok|em ordem) com o carro|o carro (?:ta|esta) (?:bem|ok|certo)|como (?:ta|esta) o carro)$").has(f) {
            return "Tem alguma luz de alerta?"
        }
        // the "Você …?" rule runs last, so "Você liga o aquecimento do meu banco?" also loses its question form
        var pt = re("\\b(?:liga|ligar|ligue|ativa) o aquecimento do (meu |seu )?banco( do motorista| do passageiro| do carona)?\\b", ignoreCase: true)
            .replaceFirst(t) { m in
                let who = m.g(2)
                return "esquenta o \(m.g(1) ?? "")banco\(who != nil ? (re("carona", ignoreCase: true).has(who!) ? " do passageiro" : who!) : "")"
            }
        pt = re("\\b(?:liga|ligar|ligue) o banco aquecido\\b", ignoreCase: true).replaceFirst(pt, with: "esquenta o banco")
        pt = re("\\b(?:liga|ligar|ligue) o aquecimento dos dois bancos( da frente)?\\b|\\besquenta os dois bancos( da frente)?\\b", ignoreCase: true)
            .replaceFirst(pt, with: "esquenta o banco do motorista e esquenta o banco do passageiro")
        pt = re("^(?:você|voce|vc) (esquenta|refresca)(.*?)\\?*$", ignoreCase: true).replaceFirst(pt) { "\($0.gs(1))\($0.gs(2))" }
        if pt != t { return cap(pt) }
        return nil
    }

    /// A heat / cool request for "the seats" with no seat said: asked here. The request to complete.
    private static func pluralSeats(_ userText: String, _ lang: String) -> String? {
        if lang != "pt" { return nil }
        let f = re(" por favor$").replaceFirst(fold(userText), with: "")
        if re("^(?:liga|ligar|ligue|ativa) o aquecimento dos bancos$|^esquenta os bancos$|^(?:liga|ligar) os bancos aquecidos$").has(f) {
            return "Esquenta os bancos"
        }
        if re("^(?:liga|ligar|ligue|ativa) a ventilacao dos bancos$|^refresca os bancos$").has(f) { return "Refresca os bancos" }
        return nil
    }

    /// The driver says the offered request short ("Close it", "Lock it", "Turn it on", "Fecha", "Pode trancar"): the offer itself.
    private static let offerVerbs: [String: [(Rx, Rx)]] = [
        "en": [
            (re("^close\\b", ignoreCase: true), re("^(?:close|shut)$")),
            (re("^open\\b", ignoreCase: true), re("^open$")),
            (re("^lock\\b", ignoreCase: true), re("^lock$")),
            (re("^(?:heat|cool)\\b", ignoreCase: true), re("^(?:turn on|switch on|heat|cool|turn on)$")),
        ],
        "pt": [
            (re("^fecha\\b", ignoreCase: true), re("^(?:fecha|fechar|feche|pode fechar)$")),
            (re("^abre\\b", ignoreCase: true), re("^(?:abre|abrir|abra|pode abrir)$")),
            (re("^tranca\\b", ignoreCase: true), re("^(?:tranca|trancar|tranque|pode trancar)$")),
            (re("^(?:esquenta|refresca)\\b", ignoreCase: true), re("^(?:liga|ligar|ligue|pode ligar|esquenta|refresca)$")),
        ],
    ]

    private static func sameRequest(_ userText: String, _ request: String, _ lang: String) -> Bool {
        guard let verb = offerVerbs[lang]!.first(where: { $0.0.has(request) })?.1 else { return false }
        var f = re("^(?:yes|yeah|sure|ok|okay|please|sim|claro|pode|ok|beleza) ").replaceFirst(fold(userText), with: "")
        f = re(" (?:please|por favor|pra mim|para mim)$").replaceFirst(f, with: "")
        f = re("^(turn|switch) (?:it|them) on$").replaceFirst(f) { "\($0.gs(1)) on" }
        f = re(" (?:it|them|that|ele|eles|ela|elas|isso)$").replaceFirst(f, with: "")
        return verb.has(f)
    }

    private struct Pending {
        let kind: String
        let request: String
    }

    private static var pending: Pending?
    private static var dismissVariant = 0
    private static var lastSpoken = ""

    /// For tests.
    static func reset() {
        pending = nil
        dismissVariant = 0
        lastSpoken = ""
    }

    /// What the driver last heard (said again for "Say that again").
    static func noteCarSpoken(_ text: String) {
        if !text.trimmed.isEmpty { lastSpoken = text.trimmed }
    }

    /// What goes to the agent for what the driver said, or the app's own short reply. offer: the calls a plain yes would run now.
    static func carTurnInput(_ userText: String, _ language: String, _ offer: [String]?, musicOn: Bool = false, state: CarState? = nil,
                             lastActed: Bool? = nil) -> TurnInput {
        guard let lang = tuned(language) else {
            return TurnInput(text: BasicLanguage.normalizeYesNo(userText, language) ?? BasicLanguage.withCarHints(userText, language))
        }
        let asked = pending
        pending = nil
        // "Say that again": what was said, and the question in it still waits for its answer
        if !lastSpoken.isEmpty && only(userText, repeatPhrases[lang]!) {
            pending = asked
            return TurnInput(reply: lastSpoken)
        }
        // the app's own offer (an answer about the car: "Want me to lock it?"): a yes is that request
        if let asked, asked.kind == "command", only(userText, yes[lang]!) || sameRequest(userText, asked.request, lang) {
            return TurnInput(text: asked.request)
        }
        // a question about the car: answered from the car (the model ran the action)
        if let state, let known = StateAnswers.answer(userText, language, state) {
            if let o = known.offer { pending = Pending(kind: "command", request: o) } else if known.askDestination {
                pending = Pending(kind: "destination", request: "")
            }
            return TurnInput(reply: known.reply)
        }
        let yesWord = lang == "pt" ? "sim" : "yes"
        // music playing, "next song": not in this demo
        if musicOn && only(userText, skip[lang]!) { return TurnInput(reply: notInDemoTexts[language] ?? notInDemoTexts["en"]!) }
        // music playing: "stop" / "para" means the music
        if musicOn && (offer ?? []).isEmpty && only(userText, stopMusic[lang]!) {
            return TurnInput(text: lang == "pt" ? "Desliga o som" : "Stop the music")
        }
        if let offer, !offer.isEmpty {
            if only(userText, yes[lang]!) { return TurnInput(text: yesWord) }
            if offer.contains("navigate_to") && only(userText, goThere[lang]!) { return TurnInput(text: yesWord) }
            if only(userText, dismiss[lang]!) && containsAny(userText, dismissCore[lang]!) { return TurnInput(text: lang == "pt" ? "não" : "no") }
            return TurnInput(text: userText)
        }
        if only(userText, dismiss[lang]!) && containsAny(userText, dismissCore[lang]!) {
            let list = dismissReply[lang]!
            defer { dismissVariant += 1 }
            return TurnInput(reply: list[dismissVariant % list.count])
        }
        // "Turn it off" with nothing it can mean (no music, the last request changed nothing): asked, not guessed
        if !musicOn && lastActed == false && asked == nil {
            let which = only(userText, bareOff[lang]!) ? "off" : only(userText, bareOn[lang]!) ? "on" : nil
            if let which {
                let (question, verb) = askWhat[lang]![which]!
                pending = Pending(kind: "verb", request: verb)
                return TurnInput(reply: question)
            }
        }
        if let asked {
            let a = fold(userText)
            let words = a.isEmpty ? 0 : a.splitSpace().count
            if (1...5).contains(words) && !commandStart[lang]!.has(a) && !only(userText, yes[lang]!) {
                // "The driver's one" -> "the driver's one" inside the request (a name such as "Coldplay" keeps its capital)
                let saidText = re("[.!?]+$").replace(userText.trimmed, with: "")
                let answer = lowerFirst[lang]!.contains(fold(saidText.splitSpace()[0])) ? saidText.prefix(1).lowercased() + saidText.dropFirst() : saidText
                switch asked.kind {
                case "destination":
                    if lang == "pt" {
                        return TurnInput(text: re("^(pra|pro|para|pras|pros)\\b", ignoreCase: true).has(answer) ? "Navega \(answer)" : "Navega para \(answer)")
                    }
                    return TurnInput(text: re("^to\\b", ignoreCase: true).has(answer) ? "Navigate \(answer)" : "Navigate to \(answer)")
                case "media": return TurnInput(text: "\(lang == "pt" ? "Toca" : "Play") \(answer)")
                case "verb": return TurnInput(text: "\(asked.request) \(answer)")
                case "seat":
                    // the core asks again unless the request names one seat: the seat goes into the request
                    if let seat = seatAnswer[lang]!.first(where: { $0.0.has(a) })?.1, let rewritten = withSeat(asked.request, seat, lang) {
                        return TurnInput(text: rewritten)
                    }
                default: break
                }
                if asked.kind != "command" { return TurnInput(text: "\(re("[.!?,;:]+$").replace(asked.request.trimmed, with: "")), \(answer)") }
            }
        }
        if let seats = pluralSeats(userText, lang) {
            pending = Pending(kind: "seat", request: seats)
            return TurnInput(reply: whichSeat[lang])
        }
        // something the car can't do, with the action it can ("Lock the sunroof" -> close it): asked, nothing runs without a yes
        if let near = nearMiss(userText, lang) {
            pending = Pending(kind: "command", request: near.request)
            return TurnInput(reply: near.reply)
        }
        return TurnInput(text: canonical(userText, lang) ?? userText)
    }

    /// "Lock the sunroof" / "Unlock the windows": the car has no such lock (2026-11-25 iPhone: the model declined and the driver heard
    /// "not available in this demo"). The app says what it can do instead and asks; a yes ("Yes", "Close it") sends that request to the
    /// agent. (reply, request) or nil.
    private static func nearMiss(_ userText: String, _ lang: String) -> (reply: String, request: String)? {
        let f = fold(userText)
        if lang == "en" {
            guard let m = re("^(?:(?:can|could|would|will) you |please )*(lock|unlock) (?:up )?(?:the |my |our |all the |all )?(sunroof|moonroof|roof|windows)(?: please| for me)?$").find(f) else { return nil }
            let lock = m.gs(1) == "lock"
            let roof = m.gs(2) != "windows"
            let what = roof ? "the sunroof" : "the windows"
            let verb = lock ? "close" : "open"
            let it = roof ? "it" : "them"
            return ("I can't \(m.gs(1)) \(what), but I can \(verb) \(it). Want me to \(verb) \(it)?",
                    roof ? "\(lock ? "Close" : "Open") the sunroof" : "\(lock ? "Close" : "Open") all the windows")
        }
        // pt-BR: every sentence about six words or more; both tested 2026-11-25 (brv3 voice, 5/5 heard right)
        guard let m = re("^(?:(?:voce|vc) pode |pode |por favor )*(tranca|trancar|tranque|destranca|destrancar|destranque) (?:o |os |as |todos os |todas as )?(teto solar|teto|vidros|janelas)(?: do carro)?(?: por favor| pra mim)?$").find(f) else { return nil }
        let lock = !m.gs(1).hasPrefix("des")
        let roof = m.gs(2).hasPrefix("teto")
        let said = roof ? "o teto solar do carro" : "as janelas do carro"
        return ("Não consigo \(lock ? "trancar" : "destrancar") \(said). Posso \(lock ? "fechar" : "abrir") \(roof ? "o teto solar" : "todas as janelas") para você?",
                roof ? "\(lock ? "Fecha" : "Abre") o teto solar" : "\(lock ? "Fecha" : "Abre") todos os vidros")
    }

    /// After the agent's reply: remember a question the next short answer completes. sent = what went to the agent for this request.
    static func noteCarReply(_ sent: String, _ reply: String, _ language: String) {
        pending = nil
        if tuned(language) == nil { return }
        let r = reply.trimmed
        if !r.hasSuffix("?") { return }
        let last = (re("[^.!?]*\\?$").find(r)?.value ?? r).trimmed
        if re("where (?:do you want|would you like) to go\\?$|para onde (?:você |vc )?quer ir\\?$", ignoreCase: true).has(last) {
            pending = Pending(kind: "destination", request: sent)
        } else if re("what (?:do you want|would you like) to (?:hear|listen to)\\?$|o que (?:você |vc )?quer ouvir\\?$", ignoreCase: true).has(last) {
            pending = Pending(kind: "media", request: sent)
        } else if re("^(?:which seat|qual banco)\\b", ignoreCase: true).has(last) {
            pending = Pending(kind: "seat", request: sent)
        } else if re("\\b(?:which|qual|quais)\\b", ignoreCase: true).has(last) && !re("\\b(?:again|repetir|de novo)\\b", ignoreCase: true).has(last) {
            pending = Pending(kind: "merge", request: sent)
        }
    }
}
