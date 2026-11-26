import Foundation

// Windows and doors by place (port of the other car apps' positions): front_left / front_right / rear_left / rear_right, the relative
// driver / passenger (resolved from the car's steering-wheel side, never assumed), the sides front / rear / left / right, and all.
// Pure functions (the language is a parameter).

let positions = ["front_left", "front_right", "rear_left", "rear_right"]

/// The physical positions a target means in this car, or nil for a value the car doesn't know.
func resolvePositions(_ target: JSON?, _ steering: String) -> [String]? {
    let t: String = {
        guard let target, target != "" else { return "all" }
        return str(target)
    }()
    let driver = steering == "right" ? "front_right" : "front_left"
    let passenger = steering == "right" ? "front_left" : "front_right"
    switch t {
    case "all": return positions
    case "driver": return [driver]
    case "passenger": return [passenger]
    case "front": return ["front_left", "front_right"]
    case "rear": return ["rear_left", "rear_right"]
    case "left": return ["front_left", "rear_left"]
    case "right": return ["front_right", "rear_right"]
    default: return positions.contains(t) ? [t] : nil
    }
}

/// How the reply names it: the user's own words for the target (driver stays "the driver's window", not a place).
struct PositionName {
    let text: String
    let plural: Bool
    let fem: Bool
}

private let enOne = [
    "driver": "the driver's", "passenger": "the passenger", "front_left": "the front left", "front_right": "the front right",
    "rear_left": "the rear left", "rear_right": "the rear right",
]
private let enMany = ["all": "all the", "front": "the front", "rear": "the rear", "left": "the left", "right": "the right"]
private let ptPlace = [
    "front_left": ["dianteiro esquerdo", "dianteira esquerda"], "front_right": ["dianteiro direito", "dianteira direita"],
    "rear_left": ["traseiro esquerdo", "traseira esquerda"], "rear_right": ["traseiro direito", "traseira direita"],
]
private let ptSide = ["front": "da frente", "rear": "de trás", "left": "do lado esquerdo", "right": "do lado direito"]

/// obj is 'window' or 'door'; lang 'en' or 'pt-BR'.
func positionName(_ target: JSON?, _ obj: String, _ lang: String) -> PositionName {
    let t: String = {
        guard let target, target != "" else { return "all" }
        return str(target)
    }()
    let fem = lang == "pt-BR" && obj == "door"
    if lang != "pt-BR" {
        if let many = enMany[t] { return PositionName(text: "\(many) \(obj)s", plural: true, fem: fem) }
        return PositionName(text: "\(enOne[t] ?? "the") \(obj)", plural: false, fem: fem)
    }
    let noun = obj == "door" ? "porta" : "vidro"
    if t == "all" { return PositionName(text: fem ? "todas as portas" : "todos os vidros", plural: true, fem: fem) }
    if let side = ptSide[t] { return PositionName(text: "\(fem ? "as" : "os") \(noun)s \(side)", plural: true, fem: fem) }
    if t == "driver" || t == "passenger" {
        return PositionName(text: "\(fem ? "a" : "o") \(noun) do \(t == "driver" ? "motorista" : "passageiro")", plural: false, fem: fem)
    }
    if let place = ptPlace[t] { return PositionName(text: "\(fem ? "a" : "o") \(noun) \(place[fem ? 1 : 0])", plural: false, fem: fem) }
    return PositionName(text: "\(fem ? "a" : "o") \(noun)", plural: false, fem: fem)
}

func positionName(_ target: String, _ obj: String, _ lang: String) -> PositionName { positionName(.str(target), obj, lang) }

/// pt-BR adjective agreement: adj("fechad", n) -> fechado / fechada / fechados / fechadas.
func adj(_ stem: String, _ n: PositionName) -> String { stem + (n.fem ? "a" : "o") + (n.plural ? "s" : "") }

/// "is" / "are", "está" / "estão".
func be(_ n: PositionName, _ lang: String) -> String { lang != "pt-BR" ? (n.plural ? "are" : "is") : (n.plural ? "estão" : "está") }
