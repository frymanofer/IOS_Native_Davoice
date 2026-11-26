import Foundation
import os

// The DaVoice Car tools for the agent (port of the other car apps' car tools): definitions from Resources/car/*.json (the same files as
// the other apps), handlers that change the simulated car. Each call is recorded for the car screen. The app says what it did (a
// sentence naming the action, position, zone and value - success, already in that state, or refused) and the turn ends there; nothing
// is claimed before the handler returns.

enum CarTools {
    // what the agent was given this turn: the handlers check copied titles against it
    private static var lastUserText = ""
    static func noteUserText(_ text: String) { lastUserText = text }

    private struct Outcome {
        let summary: String
        let result: JObj
        var say: String?
    }

    /// Refused by the app: nothing changes; the message is a full sentence the user hears (the turn ends there). offer: what a plain
    /// "yes" to the refusal's question means (the agent core runs these calls on the user's yes, without the model).
    private struct Refused: Error {
        let message: String
        var offer: [JObj]?
    }

    private static func call(_ name: String, _ door: JSON? = nil) -> JObj {
        ["name": JSON(name), "arguments": door == nil ? .obj(JObj()) : ["door": door!]]
    }

    private static var pt: Bool { AppLanguage.current == "pt-BR" }
    private static func l(_ en: String, _ pt: String) -> String { self.pt ? pt : en }
    private static var lang: String { pt ? "pt-BR" : "en" }

    private static let ptSeat = ["driver": "motorista", "passenger": "passageiro", "rear_left": "traseiro esquerdo", "rear_right": "traseiro direito"]
    private static let ptLevel = ["off": "desligado", "low": "baixo", "medium": "médio", "high": "alto"]
    private static let ptPlace = ["gas_station": "posto de combustível", "ev_charger": "carregador", "parking": "estacionamento",
                                  "restaurant": "restaurante", "coffee": "café", "rest_area": "parada"]
    private static let ptAvoid = ["tolls": "pedágios", "traffic": "trânsito", "highways": "rodovias", "ferries": "balsas"]
    private static let ptAir = ["face": "rosto", "feet": "pés", "face_and_feet": "rosto e pés", "windshield": "para-brisa"]
    private static let ptAirArt = ["face": "o rosto", "feet": "os pés", "face_and_feet": "o rosto e os pés", "windshield": "o para-brisa"]
    private static let enSeat = ["driver": "the driver's seat", "passenger": "the passenger seat", "rear_left": "the rear left seat",
                                 "rear_right": "the rear right seat"]
    private static let enPlace = ["gas_station": "a gas station", "ev_charger": "an EV charger", "parking": "a parking spot",
                                  "restaurant": "a restaurant", "coffee": "a coffee shop", "rest_area": "a rest area"]
    private static let ptPlaceSay = ["gas_station": "um posto de combustível", "ev_charger": "um carregador", "parking": "um estacionamento",
                                     "restaurant": "um restaurante", "coffee": "um café", "rest_area": "uma parada"]
    private static let enAir = ["face": "your face", "feet": "your feet", "face_and_feet": "your face and feet", "windshield": "the windshield"]

    private static func words(_ s: JSON?) -> String { str(s).replacingOccurrences(of: "_", with: " ") }
    private static func words(_ s: String) -> String { s.replacingOccurrences(of: "_", with: " ") }

    /// A number as the other apps print it: 22 (not 22.0), 22.5; pt-BR with a comma.
    private static func n(_ v: Double) -> String {
        let s = Json.num(v)
        return pt ? s.replacingOccurrences(of: ".", with: ",") : s
    }

    private static func done(_ summary: String, _ extra: JObj = JObj(), _ say: String? = nil) -> Outcome {
        Outcome(summary: summary, result: ["status": JSON("Done: \(summary)")] + extra, say: say)
    }

    /// Nothing to do: the car is already in the requested state (said as such; nothing is claimed as done).
    private static func already(_ summary: String, _ say: String, _ extra: JObj = JObj()) -> Outcome {
        Outcome(summary: summary, result: ["already": true] + extra, say: say)
    }

    /// A lookup answered by the app itself (no second model round that could only say "Done.").
    private static func answer(_ summary: String, _ result: JObj, _ say: String) -> Outcome { Outcome(summary: summary, result: result, say: say) }

    private static var s: CarState { Car.state }

    /// The positions a window / door argument means in this car (steering-wheel side from the vehicle configuration).
    private static func positionsOf(_ target: JSON?, _ obj: String) throws -> [String] {
        guard let p = resolvePositions(target, s.steering) else {
            throw Refused(message: l("I don't know which \(obj) that is. Which one do you mean?",
                                     "Não sei qual \(obj == "door" ? "porta" : "vidro") é esse. Qual você quer?"))
        }
        return p
    }

    private static func nm(_ target: JSON?, _ obj: String) -> PositionName { positionName(target, obj, lang) }
    private static func degrees(_ t: Double, _ unit: String) -> String { "\(n(t))°\(unit == "fahrenheit" ? "F" : "C")" }

    /// Not while the car moves (the screen's Parked / Driving switch).
    private static let notWhileDriving: [String: (JObj) -> Bool] = [
        "set_trunk": { _ in true },
        "set_charge_port": { _ in true },
        "rotate_screen": { _ in true },
        "activate_scenario": { $0["mode"] == "car_wash" || $0["mode"] == "rest" },
        "set_window": { ($0["window"] ?? "all") == "all" && $0["position"] == "open" },
        "open_door": { _ in true },
    ]

    private static func range(_ value: JSON?, _ min: Double, _ max: Double, _ what: String) throws -> Double {
        guard let v = numOf(value), !v.isNaN, v >= min, v <= max else {
            throw Refused(message: l("I didn't change it: \(what.lowercased()) must be between \(n(min)) and \(n(max)).",
                                     "Não mudei: \(what.lowercased()) precisa ficar entre \(n(min)) e \(n(max))."))
        }
        return v
    }

    private static func range(_ value: Double, _ min: Double, _ max: Double, _ what: String) throws -> Double {
        try range(.num(value), min, max, what)
    }

    private static func lockDoors(_ door: JSON?, _ lock: Bool) throws -> Outcome {
        let which = try positionsOf(door, "door")
        let whole = which.count == 4
        let nn = nm(door, "door")
        if lock {
            let open = which.filter { s.doors[$0] == "open" }
            if !open.isEmpty {
                let on = open.count == 1 ? positionName(open[0], "door", lang) : positionName("all", "door", lang)
                // yes = close what is open, then lock what was asked
                let offer = (whole && open.count > 1 ? [call("close_doors", "all")] : open.map { call("close_doors", JSON($0)) }) + [call("lock_car", door)]
                throw Refused(
                    message: open.count == 1
                        ? l("I can't lock it while \(on.text) is open. Close it first?", "Não consigo trancar com \(on.text) \(adj("abert", on)). Quer que eu feche primeiro?")
                        : l("I can't lock the car while doors are open. Close them first?", "Não consigo trancar com portas abertas. Quer que eu feche primeiro?"),
                    offer: offer)
            }
        }
        let stem = lock ? "trancad" : "destrancad"
        if which.allSatisfy({ s.doorLocks[$0] == lock }) {
            if whole {
                return already(l("car already \(lock ? "locked" : "unlocked")", "carro já \(stem)o"),
                               l("The car is already \(lock ? "locked" : "unlocked").", "O carro já está \(stem)o."))
            }
            return already(
                l("\(nn.text) already \(lock ? "locked" : "unlocked")", "\(nn.text) já \(adj(stem, nn))"),
                l("\(cap(nn.text)) \(be(nn, "en")) already \(lock ? "locked" : "unlocked").", "\(cap(nn.text)) já \(be(nn, "pt-BR")) \(adj(stem, nn))."))
        }
        for k in which { s.doorLocks[k] = lock }
        s.locked = s.doorLocks.values.allSatisfy { $0 }
        Car.changed()
        if whole {
            return done(l(lock ? "car locked" : "car unlocked", lock ? "carro trancado" : "carro destrancado"), ["doors": JSON(which)],
                        l(lock ? "I locked the car." : "I unlocked the car.", lock ? "Tranquei o carro." : "Destranquei o carro."))
        }
        return done(l("\(nn.text) \(lock ? "locked" : "unlocked")", "\(nn.text) \(adj(stem, nn))"), ["doors": JSON(which)],
                    l("I \(lock ? "locked" : "unlocked") \(nn.text).", "\(lock ? "Tranquei" : "Destranquei") \(nn.text)."))
    }

    /// The place find_along_route found last: "yes" to its offer navigates there (2.1 km away, not the demo's usual 24 minutes).
    private static var lastFound: String?

    /// The route's time and distance, said again by get_trip_eta.
    private static var trip: (minutes: Int, km: Double) = (24, 18)
    private static let enNearest = ["gas_station": "the nearest gas station", "ev_charger": "the nearest EV charger", "parking": "the nearest parking spot",
                                    "restaurant": "the nearest restaurant", "coffee": "the nearest coffee shop", "rest_area": "the nearest rest area"]
    private static let ptNearest = ["gas_station": "o posto de combustível mais próximo", "ev_charger": "o carregador mais próximo",
                                    "parking": "o estacionamento mais próximo", "restaurant": "o restaurante mais próximo", "coffee": "o café mais próximo",
                                    "rest_area": "a parada mais próxima"]

    private static let handlers: [String: (JObj) throws -> Outcome] = [
        "navigate_to": { a in
            let d = str(a["destination"])
            let shown = d == "home" ? l("home", "casa") : d == "work" ? l("work", "trabalho") : d
            s.destination = shown
            Car.changed()
            if lastFound != nil && d == lastFound {
                trip = (3, 2.1)
                return done(l("navigating to \(shown)", "navegando para \(shown)"), ["minutes": 3, "km": 2.1],
                            l("Navigating to \(shown): about 3 minutes, 2.1 km.", "Indo para \(shown): cerca de 3 minutos, 2,1 km."))
            }
            trip = (24, 18)
            return done(l("navigating to \(shown)", "navegando para \(shown)"), ["minutes": 24, "km": 18],
                        l("Navigating to \(shown): about 24 minutes, 18 km.", "Indo para \(shown): cerca de 24 minutos, 18 km."))
        },
        // the found place comes with an offer: a plain "yes" (or "take me there") navigates there (the agent core runs the offered call)
        "find_along_route": { a in
            let p = str(a["place_type"])
            let found = l(enNearest[p] ?? "the nearest \(words(p))", ptNearest[p] ?? "\(words(p)) mais próximo")
            lastFound = found
            return done(l("found a \(words(p)) 2.1 km ahead", "\(ptPlace[p] ?? p) encontrado a 2,1 km"), [
                "name": "Nearest match",
                "km": 2.1,
                "offer": ["calls": [["name": "navigate_to", "arguments": ["destination": JSON(found)]]]],
            ], l("I found \(enPlace[p] ?? words(p)) 2.1 km ahead.", "Encontrei \(ptPlaceSay[p] ?? p) a 2,1 km."))
        },
        "get_trip_eta": { _ in
            guard let dest = s.destination else {
                return answer(l("no active route", "nenhuma rota ativa"), ["navigating": false],
                              l("There's no active route. Where do you want to go?", "Não há nenhuma rota ativa. Para onde você quer ir?"))
            }
            let (minutes, km) = trip
            let kmText = Json.num(km)
            return answer(l("arriving in \(minutes) min", "chegada em \(minutes) min"),
                          ["destination": JSON(dest), "minutes_left": JSON(minutes), "km_left": JSON(km)],
                          l("You'll get to \(dest) in about \(minutes) minutes, \(kmText) km to go.",
                            "Você chega em \(dest) em cerca de \(minutes) minutos; faltam \(kmText.replacingOccurrences(of: ".", with: ",")) km."))
        },
        "set_route_avoid": { a in
            let v = str(a["avoid"])
            if s.avoid.contains(v) {
                return already(l("route unchanged", "rota sem mudança"), l("The route already avoids \(words(v)).", "A rota já evita \(ptAvoid[v] ?? v)."))
            }
            s.avoid.append(v)
            Car.changed()
            return done(l("route avoids \(v)", "rota evitando \(ptAvoid[v] ?? v)"), JObj(),
                        l("The route now avoids \(words(v)).", "A rota agora evita \(ptAvoid[v] ?? v)."))
        },
        "set_temperature": { a in
            let u = a["unit"].map(str) ?? s.unit
            let z = a["zone"].map(str) ?? "all"
            let temperature = numOf(a["temperature"])
            let change = numOf(a["change"])
            let current = z == "all" ? s.temperature["driver"]! : (s.temperature[z] ?? s.temperature["driver"]!)
            if temperature == nil && change == nil { throw Refused(message: l("no temperature given", "nenhuma temperatura informada")) }
            let target = temperature ?? (current + change!)
            let t = u == "fahrenheit" ? try range(target, 60, 86, l("The temperature", "A temperatura"))
                : try range(target, 16, 30, l("The temperature", "A temperatura")) as Double
            let zones = z == "all" ? ["driver", "passenger", "rear"] : [z]
            if zones.allSatisfy({ s.temperature[$0] == t }) && u == s.unit {
                let enZ = ["all": "The whole cabin is", "driver": "The driver's side is", "passenger": "The passenger side is", "rear": "The back is"][z]
                    ?? "\(cap(words(z))) is"
                let ptZ = ["all": "A cabine toda já está", "driver": "O lado do motorista já está", "passenger": "O lado do passageiro já está",
                           "rear": "A parte de trás já está"][z] ?? "\(z) já está"
                return already(l("temperature already \(degrees(t, u))", "temperatura já em \(degrees(t, u))"),
                               l("\(enZ) already at \(degrees(t, u)).", "\(ptZ) em \(degrees(t, u))."), ["temperature": JSON(t)])
            }
            s.unit = u
            for k in zones { s.temperature[k] = t }
            Car.changed()
            let zoneText = z == "all" ? l("cabin", "cabine") : l(words(z), ptSeat[z] ?? z)
            let deg = degrees(t, u)
            let enZone = ["all": "the whole cabin", "driver": "the driver's side", "passenger": "the passenger side", "rear": "the back"][z] ?? words(z)
            let ptZone = ["all": "a cabine toda", "driver": "o lado do motorista", "passenger": "o lado do passageiro", "rear": "a parte de trás"][z] ?? z
            let up = temperature == nil && change! > 0
            let down = temperature == nil && change! < 0
            let say = l("\(up ? "I raised" : down ? "I lowered" : "I set") \(enZone) to \(deg).",
                        "\(up ? "Subi" : down ? "Baixei" : "Coloquei") \(ptZone) \(up || down ? "para" : "em") \(deg).")
            return done(l("\(zoneText) temperature \(deg)", "temperatura \(zoneText) em \(deg)"), ["temperature": JSON(t)], say)
        },
        // Two zones in one request: each value validated; what can't be set is reported, the rest is done.
        "set_dual_zone_temperature": { a in
            let u = a["unit"].map(str) ?? s.unit
            let (min, max): (Double, Double) = u == "fahrenheit" ? (60, 86) : (16, 30)
            func check(_ v: JSON?) -> Double? { numOf(v).flatMap { $0 >= min && $0 <= max ? $0 : nil } }
            let d = check(a["driver"])
            let p = check(a["passenger"])
            if d == nil && p == nil {
                throw Refused(message: l("I didn't change the temperature: both values must be between \(n(min)) and \(n(max)).",
                                         "Não mudei a temperatura: os dois valores precisam ficar entre \(n(min)) e \(n(max))."))
            }
            if d == s.temperature["driver"] && p == s.temperature["passenger"] && u == s.unit {
                return already(l("temperatures already set", "temperaturas já ajustadas"),
                               l("The driver's side is already at \(degrees(d!, u)) and the passenger side at \(degrees(p!, u)).",
                                 "O lado do motorista já está em \(degrees(d!, u)) e o do passageiro em \(degrees(p!, u))."))
            }
            s.unit = u
            if let d { s.temperature["driver"] = d }
            if let p { s.temperature["passenger"] = p }
            Car.changed()
            let result: JObj = [
                "driver": d != nil ? ["ok": true, "temperature": JSON(d!)] : ["ok": false, "error": "out of range"],
                "passenger": p != nil ? ["ok": true, "temperature": JSON(p!)] : ["ok": false, "error": "out of range"],
                "atomic": false,
            ]
            if let d, let p {
                return done(l("driver \(degrees(d, u)), passenger \(degrees(p, u))", "motorista \(degrees(d, u)), passageiro \(degrees(p, u))"), result,
                            l("I set the driver's side to \(degrees(d, u)) and the passenger side to \(degrees(p, u)).",
                              "Coloquei o lado do motorista em \(degrees(d, u)) e o do passageiro em \(degrees(p, u))."))
            }
            let okSide = d != nil ? l("the driver's side", "o lado do motorista") : l("the passenger side", "o lado do passageiro")
            let badSide = d != nil ? l("the passenger side", "o do passageiro") : l("the driver's side", "o do motorista")
            let v = d ?? p!
            return done(l("partly: \(okSide) \(degrees(v, u))", "parcial: \(okSide) \(degrees(v, u))"), result,
                        l("I set \(okSide) to \(degrees(v, u)), but not \(badSide): it must be between \(n(min)) and \(n(max)).",
                          "Coloquei \(okSide) em \(degrees(v, u)), mas não \(badSide): precisa ficar entre \(n(min)) e \(n(max))."))
        },
        "comfort_feeling": { a in
            let cold = a["feeling"] == "cold"
            s.temperature["driver"] = Swift.min(30, Swift.max(16, s.temperature["driver"]! + (cold ? 2 : -2)))
            s.seatHeater["driver"] = cold ? "medium" : "off"
            s.seatVentilation["driver"] = cold ? "off" : "medium"
            Car.changed()
            return done(
                cold ? l("warmer air, seat heater on medium", "ar mais quente e aquecimento do banco no médio")
                    : l("cooler air, seat ventilation on medium", "ar mais frio e ventilação do banco no médio"),
                JObj(),
                cold ? l("I made it warmer: the air is two degrees up and your seat heater is on medium.",
                         "Deixei mais quente: subi o ar dois graus e liguei o aquecimento do banco no médio.")
                    : l("I cooled it down: the air is two degrees lower and your seat ventilation is on medium.",
                        "Deixei mais fresco: baixei o ar dois graus e liguei a ventilação do banco no médio."))
        },
        "set_fan_speed": { a in
            let level = numOf(a["level"])
            let change = numOf(a["change"])
            if level == nil && change == nil { throw Refused(message: l("no fan level given", "nenhum nível de ventilação informado")) }
            let target = level ?? (Double(s.fan) + change!)
            let fan = Int(try range(Swift.min(7, Swift.max(1, target)), 1, 7, l("The fan level", "O nível de ventilação")))
            // Outside 1-7 the car goes to the nearest end and says so (never a silent clamp).
            let edge = target > 7 ? l("The fan goes up to level 7", "A ventilação vai até o nível 7")
                : target < 1 ? l("The lowest fan level is 1", "O nível mínimo da ventilação é 1") : ""
            if fan == s.fan {
                return already(l("fan already \(fan)", "ventilação já no \(fan)"),
                               !edge.isEmpty ? l("\(edge), and it is already there.", "\(edge), e já está nele.")
                                   : l("The fan is already at level \(fan).", "A ventilação já está no nível \(fan)."))
            }
            s.fan = fan
            Car.changed()
            return done(l("fan speed \(fan)", "ventilação no nível \(fan)"), ["fan_level": JSON(fan)],
                        !edge.isEmpty ? l("\(edge), so I set it to level \(fan).", "\(edge), então coloquei no nível \(fan).")
                            : l("I set the fan to level \(fan).", "Coloquei a ventilação no nível \(fan)."))
        },
        "set_airflow": { a in
            let m = str(a["mode"])
            if s.airflow == m {
                return already(l("airflow unchanged", "ar sem mudança"), l("The air already goes to \(enAir[m] ?? words(m)).", "O ar já vai para \(ptAirArt[m] ?? m)."))
            }
            s.airflow = m
            Car.changed()
            return done(l("air to \(words(m))", "ar para \(ptAir[m] ?? m)"), JObj(),
                        l("The air now goes to \(enAir[m] ?? words(m)).", "O ar agora vai para \(ptAirArt[m] ?? m)."))
        },
        "set_defrost": { a in
            let target = str(a["target"])
            let want = a["on"] != false
            let what = target == "rear" ? l("rear defogger", "desembaçador traseiro") : l("windshield defrost", "desembaçador do para-brisa")
            if s.defrost[target] == want {
                return already(l("\(what) already \(want ? "on" : "off")", "\(what) já \(want ? "ligado" : "desligado")"),
                               l("The \(what) is already \(want ? "on" : "off").", "O \(what) já está \(want ? "ligado" : "desligado")."))
            }
            s.defrost[target] = want
            Car.changed()
            return done("\(what) \(want ? l("on", "ligado") : l("off", "desligado"))", JObj(),
                        l("I turned the \(what) \(want ? "on" : "off").", "\(want ? "Liguei" : "Desliguei") o \(what)."))
        },
        "set_window": { a in
            let which = try positionsOf(a["window"], "window")
            let nn = nm(a["window"], "window")
            let pos = str(a["position"])
            let enState = ["open": "open", "close": "closed", "half": "half open", "crack": "open a crack"][pos] ?? pos
            let ptState = ["open": adj("abert", nn), "close": adj("fechad", nn), "half": "\(adj("abert", nn)) até a metade", "crack": "com uma fresta"][pos] ?? pos
            if which.allSatisfy({ s.windows[$0] == pos }) {
                return already(l("\(nn.text) already \(enState)", "\(nn.text) já \(ptState)"),
                               l("\(cap(nn.text)) \(be(nn, "en")) already \(enState).", "\(cap(nn.text)) já \(be(nn, "pt-BR")) \(ptState)."))
            }
            for k in which { s.windows[k] = pos }
            Car.changed()
            let say = l(
                ["open": "I opened \(nn.text).", "close": "I closed \(nn.text).", "half": "I opened \(nn.text) halfway.", "crack": "I opened \(nn.text) a crack."][pos]
                    ?? "\(cap(nn.text)): \(enState).",
                ["open": "Abri \(nn.text).", "close": "Fechei \(nn.text).", "half": "Abri \(nn.text) até a metade.", "crack": "Deixei \(nn.text) com uma fresta."][pos]
                    ?? "\(cap(nn.text)): \(ptState).")
            return done(l("\(nn.text) \(enState)", "\(nn.text) \(ptState)"), ["windows": JSON(which)], say)
        },
        "open_door": { a in
            let which = try positionsOf(a["door"], "door")
            let nn = nm(a["door"], "door")
            // Locked: the app asks; the model never unlocks on its own.
            let lockedNow = which.filter { s.doorLocks[$0] == true }
            if !lockedNow.isEmpty {
                // yes = unlock what is locked, then open what was asked
                let opening = call("open_door", a["door"])
                if lockedNow.count == 4 {
                    throw Refused(message: l("The car is locked. Should I unlock it?", "O carro está trancado. Quer que eu destranque?"),
                                  offer: [call("unlock_car"), opening])
                }
                let ln = lockedNow.count == 1 ? positionName(lockedNow[0], "door", lang) : nn
                throw Refused(
                    message: l("\(cap(ln.text)) \(be(ln, "en")) locked. Should I unlock \(ln.plural ? "them" : "it")?",
                               "\(cap(ln.text)) \(be(ln, "pt-BR")) \(adj("trancad", ln)). Quer que eu destranque?"),
                    offer: lockedNow.map { call("unlock_car", JSON($0)) } + [opening])
            }
            if which.allSatisfy({ s.doors[$0] == "open" }) {
                return already(l("\(nn.text) already open", "\(nn.text) já \(adj("abert", nn))"),
                               l("\(cap(nn.text)) \(be(nn, "en")) already open.", "\(cap(nn.text)) já \(be(nn, "pt-BR")) \(adj("abert", nn))."))
            }
            for k in which { s.doors[k] = "open" }
            Car.changed()
            return done(l("\(nn.text) open", "\(nn.text) \(adj("abert", nn))"), ["doors": JSON(which)], l("I opened \(nn.text).", "Abri \(nn.text)."))
        },
        "close_doors": { a in
            let which = try positionsOf(a["door"], "door")
            let nn = nm(a["door"], "door")
            if which.allSatisfy({ s.doors[$0] == "closed" }) {
                return already(l("\(nn.text) already closed", "\(nn.text) já \(adj("fechad", nn))"),
                               l("\(cap(nn.text)) \(be(nn, "en")) already closed.", "\(cap(nn.text)) já \(be(nn, "pt-BR")) \(adj("fechad", nn))."))
            }
            for k in which { s.doors[k] = "closed" }
            Car.changed()
            return done(l("\(nn.text) closed", "\(nn.text) \(adj("fechad", nn))"), ["doors": JSON(which)], l("I closed \(nn.text).", "Fechei \(nn.text)."))
        },
        // each door separately; no door / all = the whole car
        "lock_car": { a in try lockDoors(a["door"], true) },
        "unlock_car": { a in try lockDoors(a["door"], false) },
        "set_sunroof": { a in
            let action = str(a["action"])
            let enA = action == "close" ? "closed" : action == "tilt" ? "tilted" : "open"
            let ptA = action == "close" ? "fechado" : action == "tilt" ? "inclinado" : "aberto"
            if s.sunroof == action {
                return already(l("sunroof unchanged", "teto sem mudança"), l("The sunroof is already \(enA).", "O teto solar já está \(ptA)."))
            }
            s.sunroof = action
            Car.changed()
            return done(l("sunroof \(enA)", "teto solar \(ptA)"), JObj(),
                        l("I \(action == "close" ? "closed" : action == "tilt" ? "tilted" : "opened") the sunroof.",
                          "\(action == "close" ? "Fechei" : action == "tilt" ? "Inclinei" : "Abri") o teto solar."))
        },
        "set_sunshade": { a in
            s.sunshade = str(a["action"])
            Car.changed()
            return done(l("sunshade \(a["action"] == "close" ? "closed" : "open")", "cortina do teto \(a["action"] == "close" ? "fechada" : "aberta")"))
        },
        "set_trunk": { a in
            let which = str(a["which"])
            let action = str(a["action"])
            if which == "frunk" { s.frunk = action } else { s.trunk = action }
            Car.changed()
            return done(l("\(which) \(action == "close" ? "closed" : "open")",
                          "\(which == "frunk" ? "porta-malas dianteiro" : "porta-malas") \(action == "close" ? "fechado" : "aberto")"))
        },
        "set_charge_port": { a in
            s.chargePort = str(a["action"])
            Car.changed()
            return done(l("charging port \(a["action"] == "close" ? "closed" : "open")", "tampa de recarga \(a["action"] == "close" ? "fechada" : "aberta")"))
        },
        "rotate_screen": { a in
            let next = a["orientation"] != nil ? str(a["orientation"]) : (s.screen == "landscape" ? "portrait" : "landscape")
            s.screen = next
            Car.changed()
            return done(l("screen in \(next)", "tela na \(next == "portrait" ? "vertical" : "horizontal")"))
        },
        "set_seat_climate": { a in
            let st = a["seat"].map(str) ?? "driver"
            let feature = str(a["feature"])
            let level = str(a["level"])
            let current = feature == "ventilation" ? s.seatVentilation[st] : s.seatHeater[st]
            let enF = feature == "ventilation" ? "ventilation" : "heater"
            if current == level {
                let ptF0 = feature == "ventilation" ? "A ventilação" : "O aquecimento"
                return already(l("seat unchanged", "banco sem mudança"), level == "off"
                    ? l("The \(enF) in \(enSeat[st] ?? "null") is already off.",
                        "\(ptF0) do banco do \(ptSeat[st] ?? "null") já está \(feature == "ventilation" ? "desligada" : "desligado").")
                    : l("The \(enF) in \(enSeat[st] ?? "null") is already on \(level).", "\(ptF0) do banco do \(ptSeat[st] ?? "null") já está no \(ptLevel[level] ?? level)."))
            }
            if feature == "ventilation" { s.seatVentilation[st] = level } else { s.seatHeater[st] = level }
            Car.changed()
            let ptF = feature == "ventilation" ? "a ventilação" : "o aquecimento"
            return done(l("\(words(st)) seat \(enF) \(level)",
                          "\(feature == "ventilation" ? "ventilação" : "aquecimento") do banco do \(ptSeat[st] ?? "null") \(ptLevel[level] ?? level)"), JObj(),
                        level == "off" ? l("I turned off the \(enF) in \(enSeat[st] ?? "null").", "Desliguei \(ptF) do banco do \(ptSeat[st] ?? "null").")
                            : l("I set the \(enF) in \(enSeat[st] ?? "null") to \(level).", "Coloquei \(ptF) do banco do \(ptSeat[st] ?? "null") no \(ptLevel[level] ?? level)."))
        },
        "set_seat_massage": { a in
            s.massageSeat = a["seat"].map(str) ?? "driver"
            s.massageOn = a["on"] != false
            if a["mode"] != nil { s.massageMode = numOf(a["mode"]).map { Int($0) } ?? s.massageMode }
            Car.changed()
            return done(a["on"] == false ? l("seat massage off", "massagem desligada")
                : l("seat massage on\(a["mode"] != nil ? ", mode \(str(a["mode"]))" : "")", "massagem ligada\(a["mode"] != nil ? ", modo \(str(a["mode"]))" : "")"))
        },
        "set_steering_wheel_heater": { a in
            s.wheelHeater = a["on"] != false
            Car.changed()
            return done(l("steering wheel heater \(a["on"] == false ? "off" : "on")", "volante aquecido \(a["on"] == false ? "desligado" : "ligado")"))
        },
        "set_cabin_lights": { a in
            let on = a["on"] != false
            if a["light"] == "reading" {
                s.readingLights = on
                Car.changed()
                return done(l("reading lights \(on ? "on" : "off")", "luz de leitura \(on ? "acesa" : "apagada")"))
            }
            s.ambientOn = on
            if a["color"] != nil { s.ambientColor = str(a["color"]) }
            Car.changed()
            let color = a["color"] != nil && on ? ", \(str(a["color"]))" : ""
            return done(l("ambient lighting \(on ? "on" : "off")\(color)", "luz ambiente \(on ? "acesa" : "apagada")\(color)"))
        },
        "play_media": { a in
            // the driver's own words when the model copied the title wrong ("Perma Woman" for "Pretty Woman", MediaQuery)
            let q = groundMediaQuery(str(a["query"]), lastUserText)
            if q != str(a["query"]) { log("play_media query \"\(str(a["query"]))\" -> \"\(q)\" (the driver's words)") }
            s.media = q
            s.radio = nil
            s.muted = false
            Car.changed()
            return done(l("playing \(q)", "tocando \(q)"), JObj(), l("Playing \(q).", "Tocando \(q)."))
        },
        "tune_radio": { a in
            let band = str(a["band"])
            // FM said as digits ("1067", "985") arrives without the decimal point: 875-1080 can only mean 87.5-108.0 MHz.
            let fm = numOf(a["frequency"])
            let freq: JSON? = band != "am" && fm != nil && fm! >= 875 && fm! <= 1080 ? .num(fm! / 10) : a["frequency"]
            var f: Double?
            if freq != nil { f = band == "am" ? try range(freq, 520, 1710, "AM") : try range(freq, 87.5, 108, "FM") }
            let station = "\(band.uppercased())\(f != nil ? " \(n(f!))" : "")"
            s.radio = station
            s.media = nil
            s.source = "radio"
            Car.changed()
            return done(l("radio \(station)", "rádio \(station)"), JObj(), l("I tuned the radio to \(station).", "Sintonizei a rádio \(station)."))
        },
        "set_audio_source": { a in
            let src = str(a["source"])
            s.source = src
            Car.changed()
            let shown = src == "usb" ? "USB" : src
            return done(l("audio source \(src)", "fonte de áudio: \(src)"), JObj(), l("I switched the audio to \(shown).", "Mudei o áudio para \(shown)."))
        },
        "set_audio_focus": { a in
            let seat = str(a["seat"])
            s.audioFocus = seat
            Car.changed()
            return done(seat == "all" ? l("sound for everyone", "som para todos") : l("sound focused on \(words(seat))", "som focado no \(ptSeat[seat] ?? seat)"))
        },
        "set_volume": { a in
            var action = str(a["action"])
            let level = a["level"]
            var volume = s.volume
            // A step of the user's own size ("by 5", "2 notches"): change = the step (the agent core writes it from the user's words);
            // "up" with a level BELOW the current volume, or "down" with one ABOVE it, cannot be a target: it is the step.
            let amount = numOf(a["change"])
            let target = numOf(level)
            var step: Double?
            if action != "mute" && action != "unmute" {
                if let amount, !amount.isNaN, amount != 0 {
                    step = amount < 0 || action == "down" ? -abs(amount) : abs(amount)
                } else if let target, !target.isNaN, action == "up", target > 0, target < Double(volume) {
                    step = target
                } else if let target, !target.isNaN, action == "down", target > Double(volume) {
                    step = -target
                }
            }
            if let step {
                volume = Int(Swift.min(30, Swift.max(0, Double(s.volume) + step)).rounded())
                action = step > 0 ? "up" : "down"
            } else if action == "set" || (level != nil && action != "mute" && action != "unmute") {
                volume = Int(try range(level, 0, 30, l("Volume", "O volume")))
            } else if action == "up" {
                volume = Swift.min(30, Swift.max(0, s.volume + 3))
            } else if action == "down" {
                volume = Swift.min(30, Swift.max(0, s.volume - 3))
            }
            if action == "mute" && s.muted {
                return already(l("already muted", "já no mudo"), l("The sound is already muted.", "O som já está no mudo."))
            }
            if action == "unmute" && !s.muted {
                return already(l("sound already on", "som já ligado"), l("The sound is already on, volume \(s.volume).", "O som já está ligado, volume \(s.volume)."))
            }
            if step == nil && (action == "set" || (action != "up" && action != "down" && level != nil)) && volume == s.volume && !s.muted {
                return already(l("volume already \(volume)", "volume já em \(volume)"), l("The volume is already at \(volume).", "O volume já está em \(volume)."))
            }
            let muted = action == "mute" ? true : (action == "unmute" || action == "up" || action == "set") ? false : s.muted
            s.volume = volume
            s.muted = muted
            Car.changed()
            let say: String
            switch action {
            case "mute": say = l("I muted the sound.", "Deixei o som no mudo.")
            case "unmute": say = l("The sound is back, volume \(volume).", "O som voltou, volume \(volume).")
            case "up": say = l("I turned the volume up to \(volume).", "Aumentei o volume para \(volume).")
            case "down": say = l("I turned the volume down to \(volume).", "Abaixei o volume para \(volume).")
            default: say = l("I set the volume to \(volume).", "Coloquei o volume em \(volume).")
            }
            return done(muted ? l("muted", "som mudo") : "volume \(volume)", ["volume": JSON(volume), "muted": JSON(muted)], say)
        },
        "call_contact": { a in
            s.call = str(a["name"])
            Car.changed()
            return done(l("calling \(str(a["name"]))\(a["number_type"] != nil ? " (\(str(a["number_type"])))" : "")", "ligando para \(str(a["name"]))"))
        },
        "manage_call": { a in
            let action = str(a["action"])
            s.call = action == "answer" ? l("Incoming caller", "Chamada recebida") : nil
            Car.changed()
            let en = ["answer": "call answered", "decline": "call declined", "hang_up": "call ended"][action] ?? action
            let p = ["answer": "chamada atendida", "decline": "chamada recusada", "hang_up": "chamada encerrada"][action] ?? action
            return done(l(en, p))
        },
        "send_message": { a in
            done(l("message sent to \(str(a["contact"])): \"\(str(a["message"]))\"", "mensagem enviada para \(str(a["contact"])): \"\(str(a["message"]))\""))
        },
        "read_messages": { _ in
            Outcome(summary: l("read 2 unread messages", "2 mensagens lidas"), result: [
                "messages": [["from": "Daniel", "text": "Are we still on for dinner?"], ["from": "Mom", "text": "Call me when you can."]],
            ])
        },
        "get_vehicle_status": { a in
            let item = str(a["item"])
            let fuel = s.fuelPercent
            let fuelKm = Int((Double(fuel) * 5).rounded())
            let values: [String: JObj] = [
                "range": ["km": 312],
                "battery": ["percent": 76],
                "energy_consumption": ["km_per_liter": 12.4],
                "tire_pressure": ["front_left_psi": 32, "front_right_psi": 32, "rear_left_psi": 31, "rear_right_psi": 32],
                "warnings": ["warnings": []],
            ]
            let value: JObj = item == "fuel" ? ["percent": JSON(fuel), "km": JSON(fuelKm)] : (values[item] ?? JObj())
            let shown = [
                "range": l("312 km of range", "autonomia de 312 km"),
                "fuel": l("fuel \(fuel)%", "combustível em \(fuel)%"),
                "battery": l("battery 76%", "bateria em 76%"),
                "energy_consumption": l("12.4 km/l average", "média de 12,4 km/l"),
                "tire_pressure": l("tires 31–32 psi", "pneus entre 31 e 32 psi"),
                "warnings": l("no warnings", "nenhum alerta"),
            ][item] ?? item
            let say = [
                "range": l("You have about 312 km of range left.", "Você tem cerca de 312 km de autonomia."),
                "fuel": l("The tank is at \(fuel)%, about \(fuelKm) km.", "O tanque está em \(fuel)%, cerca de \(fuelKm) km."),
                "battery": l("The battery is at 76%.", "A bateria está em 76%."),
                "energy_consumption": l("Average consumption is 12.4 km per liter.", "O consumo médio é de 12,4 km por litro."),
                "tire_pressure": l("The tires are fine: 31 to 32 psi.", "Os pneus estão bem: entre 31 e 32 psi."),
                "warnings": l("No warning lights are on.", "Nenhuma luz de alerta acesa."),
            ][item]
            let result: JObj = ["item": JSON(item)] + value
            if let say { return answer(shown, result, say) }
            return Outcome(summary: shown, result: result)
        },
        "activate_scenario": { a in
            let mode = str(a["mode"])
            s.scenario = mode == "smoking" || mode == "rest" || mode == "rain" ? mode : "car_wash"
            switch mode {
            case "smoking":
                s.windows[s.steering == "right" ? "front_right" : "front_left"] = "crack"
                s.airflow = "face"
            case "rest":
                s.sunshade = "close"
                s.ambientOn = true
                s.ambientColor = "warm white"
                s.temperature["driver"] = 22
                s.temperature["passenger"] = 22
            default:
                s.windows = CarState.places("close")
                s.sunroof = "close"
            }
            Car.changed()
            let ptMode = ["smoking": "fumante", "rest": "descanso", "rain": "chuva", "car_wash": "lava-rápido"][mode] ?? mode
            return done(l("\(words(mode)) mode on", "modo \(ptMode) ativado"))
        },
    ]

    /// Whether car results carry their undo (agent core configure "undo"): set by the LLM service for models with undo.
    static var undoResults = false

    /// Car tools that only read (nothing to undo, and their failure is not "the last action").
    private static let readOnlyTools: Set<String> = ["get_vehicle_status", "get_trip_eta", "find_along_route"]

    private static let logger = Logger(subsystem: "io.davoice.caragent", category: "Car")

    /// Logs (os_log; replaced in tests).
    static var log: (String) -> Void = { msg in logger.info("\(msg, privacy: .public)") }

    /// Runs one tool call (the handler the agent calls); a reply when the app says the sentence itself. undoing: the agent runs a
    /// recorded restoring call ("desfaz"): same checks, a sentence that says it was undone, nothing recorded.
    static func run(_ name: String, _ args: JObj, undoing: Bool = false) -> ToolOutput {
        let runHandler = handlers[name]
        // Basic language: not tuned, so every state change is asked first and runs only after the user's yes
        let language = AppLanguage.current
        let basic = BasicLanguage.isBasic(language)
        do {
            guard let runHandler else { throw Refused(message: l("Sorry, this car doesn't have that function.", "Desculpe, este carro não tem essa função.")) }
            if s.driving && (notWhileDriving[name]?(args) == true) {
                throw Refused(message: basic ? BasicLanguage.driving(language) : l("I can't do that while the car is moving.", "Não posso fazer isso com o carro em movimento."))
            }
            if basic && !undoing && !readOnlyTools.contains(name) && !BasicLanguage.takeConfirmed(name, args) {
                let asked = BasicLanguage.addPending([["name": JSON(name), "arguments": .obj(args)]])
                let question = BasicLanguage.confirmQuestion([["name": JSON(name), "arguments": .obj(args)]], language)
                log("ASK \(name) \(Json.stringify(args)) (basic \(language)): \(question)")
                SpeechComposer.noteCarSay(name, question, false)
                // the offer holds every call asked in this request (the core keeps one offer per request): one yes runs them all
                return .reply(result: ["ok": false, "refused": "waiting for the user to confirm", "confirm": true, "offer": ["calls": JSON(asked)]], say: question)
            }
            // vehicle policy: an undo never unlocks the car while it moves
            if undoing && name == "unlock_car" && s.driving {
                throw Refused(message: l("I can't unlock the doors while the car is moving.", "Não posso destrancar as portas com o carro em movimento."))
            }
            let before = undoResults && !undoing ? carSnapshot(s) : nil
            let out = try runHandler(args)
            Car.record(name, args, out.summary)
            log("\(name) \(Json.stringify(args)) -> \(out.summary)")
            var result = out.result
            // an offer of a successful result (find_along_route): the tuned languages only (a Basic language's yes needs its own question)
            let offerCalls = asObj(result["offer"])["calls"]?.array
            if offerCalls != nil && (basic || undoing) { result.remove("offer") }
            let offerNames = offerCalls != nil && !basic && !undoing ? offerCalls!.map { str(asObj($0)["name"]) } : nil
            if let before, let undo = carRestoreCalls(before, carSnapshot(s)) { result["undo"] = undo }
            var say = out.say
            if undoing, let s0 = say { say = l("Undone. \(s0)", "Desfeito. \(s0)") }
            // Basic language: the user just confirmed this exact action, so a short "done" in their language; lookups say their answer
            if basic {
                say = readOnlyTools.contains(name) ? (BasicLanguage.answer(name, args, language, s.destination, s.fuelPercent) ?? say) : BasicLanguage.done(language)
            }
            // what kind of sentence it is: only an action that changed the car gets the friendly words (SpeechComposer)
            let kind = readOnlyTools.contains(name) ? "answer" : result["already"] == true ? "already" : "did"
            if let say {
                SpeechComposer.noteCarSay(name, say, !undoing, args: args, kind: kind, offer: offerNames)
                return .reply(result: .obj(["ok": true] + result), say: say)
            }
            if let status = result["status"]?.string, status.hasPrefix("Done: ") {
                let said = undoing ? l("Undone. \(cap(out.summary)).", "Desfeito. \(cap(out.summary)).") : "\(cap(out.summary))."
                SpeechComposer.noteCarSay(name, said, !undoing, args: args, kind: kind)
                return .reply(result: .obj(["ok": true] + result), say: said)
            }
            return .value(.obj(["ok": true] + result))
        } catch let r as Refused {
            Car.record(name, args, r.message, ok: false, blocked: r.message)
            log("REFUSED \(name) \(Json.stringify(args)): \(r.message)")
            // Said by the app, turn ends: the model gets no chance to "fix" it with another action. Nothing changed in the car.
            let text = cap(r.message)
            // undo: a state-changing call that did not go through is still the last action, so "undo" right after it says nothing was
            // done instead of restoring an older action ({"ok": false} + "undo": false)
            let failedUndo = undoResults && !undoing && !readOnlyTools.contains(name)
            var offer = r.offer
            var refusal = re("[.?!]$").has(text) ? text : l("I didn't do that: \(r.message).", "Não fiz isso: \(r.message).")
            if basic {
                // the tool's own sentences are English / Portuguese: a refusal with an offer becomes the question for that offer
                if let o = offer, !o.isEmpty, !undoing {
                    offer = BasicLanguage.addPending(o)
                    refusal = BasicLanguage.confirmQuestion(offer!, language)
                } else {
                    refusal = r.message == BasicLanguage.driving(language) ? r.message : BasicLanguage.cannot(language)
                }
            }
            let hasOffer = !(offer ?? []).isEmpty && !undoing
            SpeechComposer.noteCarSay(name, refusal, false, offer: hasOffer ? offer!.map { str($0["name"]) } : nil)
            var result: JObj = ["ok": false, "refused": JSON(r.message)]
            if failedUndo { result["undo"] = false }
            if hasOffer { result["offer"] = ["calls": JSON(offer!)] }
            return .reply(result: .obj(result), say: refusal)
        } catch {
            // the handlers only throw Refused
            return .reply(result: ["ok": false, "refused": JSON("\(error)")], say: l("I didn't do that.", "Não fiz isso."))
        }
    }

    // ---- definitions ----------------------------------------------------------------------------------------------------------

    /// Which tool descriptions the model sees: a model must get the wording it was trained with. h3d = the Automotive Agent's.
    private static let wordingFiles = ["v1": "car/carToolDefinitions.json", "h3d": "car/carToolDefinitions.h3d.json"]
    private static var loaded: [String: JObj] = [:]

    /// Loads the definition files and the Basic-language sentences (read: a resource path -> its text).
    static func load(_ read: (String) throws -> String) throws {
        for (k, path) in wordingFiles { loaded[k] = try Json.obj(try read(path)) }
        try BasicLanguage.load(try read("car/basic_languages.json"))
    }

    /// The car tools for the agent: the demo's profile (each wording's own) or the whole catalog.
    static func tools(profile: String = "vw_demo", wording: String = "v1") -> [ToolDefinition] {
        let file = loaded[wording] ?? loaded["v1"]!
        let keep: Set<String>? = profile == "all" ? nil : Set(asList(asObj(file["profiles"])["vw_demo"]).map { str($0) })
        return asList(file["tools"]).map { asObj($0) }.filter { keep == nil || keep!.contains(str($0["name"])) }.map { t in
            let name = str(t["name"])
            return ToolDefinition(name: name, description: str(t["description"]), inputSchema: asObj(t["inputSchema"]),
                                  execution: t["execution"]?.object) { args, context in run(name, args, undoing: context["undo"] == true) }
        }
    }

    /// Every car tool name (any wording): these run on the phone (no "online" filler).
    static var names: Set<String> { Set(loaded.values.flatMap { f in asList(f["tools"]).map { str(asObj($0)["name"]) } }) }

    /// Tests: a fresh turn state.
    static func resetForTests() {
        lastFound = nil
        trip = (24, 18)
        lastUserText = ""
    }
}
