import SwiftUI

// The live top-down car (the same drawing as the other car apps' car drawing), in the design's 260 x 460 viewBox, front at the top: the
// left of the drawing is the car's left side. Doors, windows, sunroof, trunk / frunk, charge port, lock, seat heating (amber) /
// ventilation (blue), wheel heater, defrosters, ambient light, the fan's air, audio focus waves; a refused action's part blinks amber.

let carViewBoxW: CGFloat = 260
let carViewBoxH: CGFloat = 460
let carAspect: CGFloat = 254 / 450

private let windowLevel: [String: CGFloat] = ["open": 1, "half": 0.5, "crack": 0.2, "close": 0]
private let levelAlpha: [String: Double] = ["low": 0.35, "medium": 0.5, "high": 0.65]
private let seatRect: [(String, CGFloat, CGFloat, CGFloat)] = [
    ("front_left", 74, 194, 52), ("front_right", 142, 194, 52), ("rear_left", 74, 262, 50), ("rear_right", 142, 262, 50),
]
private let windowBar: [(String, CGFloat, CGFloat, CGFloat)] = [
    ("front_left", 55, 170, 70), ("front_right", 200, 170, 70), ("rear_left", 55, 250, 66), ("rear_right", 200, 250, 66),
]

/// x, y, height, rotation (degrees) around (pivotX, pivotY)
private struct DoorGeom {
    let x: CGFloat, y: CGFloat, h: CGFloat, deg: CGFloat, px: CGFloat, py: CGFloat
}

private let doorGeom: [String: DoorGeom] = [
    "front_left": DoorGeom(x: 44, y: 168, h: 72, deg: 38, px: 51, py: 168), "front_right": DoorGeom(x: 209, y: 168, h: 72, deg: -38, px: 209, py: 168),
    "rear_left": DoorGeom(x: 44, y: 248, h: 70, deg: 38, px: 51, py: 248), "rear_right": DoorGeom(x: 209, y: 248, h: 70, deg: -38, px: 209, py: 248),
]
private let doorOrder = ["front_left", "front_right", "rear_left", "rear_right"]

private let ambient: [(String, Color)] = [
    ("blue|azul", Color(hex: 0x60A5FA)), ("red|vermelh", Color(hex: 0xF87171)), ("purple|violet|roxo|lilás|lilas", Color(hex: 0xC084FC)),
    ("green|verde", Color(hex: 0x34D399)), ("orange|laranja", Color(hex: 0xFB923C)), ("pink|rosa", Color(hex: 0xF472B6)),
    ("yellow|amarel", Color(hex: 0xFACC15)), ("warm|quente", Color(hex: 0xFDE68A)), ("white|branc", Color(hex: 0xE5E7EB)),
]

func ambientColor(_ color: String) -> Color { ambient.first { re($0.0, ignoreCase: true).has(color) }?.1 ?? Color(hex: 0x2DD4BF) }

private func seatPos(_ seat: String, _ steering: String) -> String {
    switch seat {
    case "driver": return steering == "right" ? "front_right" : "front_left"
    case "passenger": return steering == "right" ? "front_left" : "front_right"
    default: return seat
    }
}

/// The part of the car a refused tool call was about: "trunk" | "frunk" | "sunroof" | "chargePort" | "lock" | doors / windows.
private func blockedPart(_ action: CarAction?, _ steering: String) -> (String, [String])? {
    guard let action, !action.ok else { return nil }
    let t = action.tool
    let a = action.args
    if t.contains("trunk") { return (a["target"] == "frunk" || a["which"] == "frunk" ? "frunk" : "trunk", []) }
    if t.contains("sunroof") { return ("sunroof", []) }
    if t.contains("charge") { return ("chargePort", []) }
    if t.contains("lock") { return ("lock", []) }
    let whereTo = resolvePositions(a["position"] ?? a["target"] ?? a["door"] ?? a["window"], steering) ?? []
    if t.contains("door") { return ("doors", whereTo) }
    if t.contains("window") { return ("windows", whereTo) }
    return nil
}

struct CarDrawing: View {
    let state: CarState
    let latest: CarAction?
    let width: CGFloat
    let version: Int
    @State private var blinkStart: Date?

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            Canvas { ctx, size in
                let scale = size.width / carViewBoxW
                ctx.scaleBy(x: scale, y: scale)
                let blink = blinkOpacity(now)
                let wave = CGFloat(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8)
                drawCar(&ctx, blink, wave)
            }
        }
        .frame(width: width, height: width * carViewBoxH / carViewBoxW)
        .accessibilityElement()
        .accessibilityLabel("Car seen from above. \(latest.map { "Last action: \($0.summary)" } ?? "No action yet").")
        .onChange(of: latest?.id) { _ in if let l = latest, !l.ok { blinkStart = Date() } }
        .onAppear { if let l = latest, !l.ok { blinkStart = Date() } }
    }

    /// Three amber pulses after a refused action: 1 -> 0.35 -> 1, three times (3 s), then steady.
    private func blinkOpacity(_ now: Date) -> Double {
        guard let start = blinkStart else { return 0 }
        let t = min(1, now.timeIntervalSince(start) / 3)
        if t >= 1 { return 1 }
        return 0.35 + 0.65 * (0.5 + 0.5 * cos(t * 3 * 2 * .pi))
    }

    private func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }

    private func door(_ ctx: inout GraphicsContext, _ pos: String, _ fill: Color, _ stroke: Color) {
        guard let d = doorGeom[pos] else { return }
        var c = ctx
        c.translateBy(x: d.px, y: d.py)
        c.rotate(by: .degrees(Double(d.deg)))
        c.translateBy(x: -d.px, y: -d.py)
        let r = rr(d.x, d.y, 7, d.h, 3)
        c.fill(r, with: .color(fill))
        c.stroke(r, with: .color(stroke), lineWidth: 1.5)
    }

    private func quad(_ points: [(CGFloat, CGFloat)]) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: points[0].0, y: points[0].1))
        p.addQuadCurve(to: CGPoint(x: points[2].0, y: points[2].1), control: CGPoint(x: points[1].0, y: points[1].1))
        return p
    }

    private func drawCar(_ ctx: inout GraphicsContext, _ blinkOpacity: Double, _ wave: CGFloat) {
        let s = state
        let steering = s.steering
        let blocked = blockedPart(latest, steering)
        let focusSeat: String? = s.call != nil ? seatPos("driver", steering)
            : (["driver", "passenger", "rear_left", "rear_right"].contains(s.audioFocus) ? seatPos(s.audioFocus, steering) : nil)
        // wheels and mirrors
        for (x, y) in [(38.0, 76.0), (210.0, 76.0), (38.0, 346.0), (210.0, 346.0)] as [(CGFloat, CGFloat)] {
            ctx.fill(rr(x, y, 12, 58, 4), with: .color(Color(hex: 0x050706)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: 35, y: 145, width: 18, height: 10)), with: .color(Color(hex: 0x2C3331)))
        ctx.fill(Path(ellipseIn: CGRect(x: 207, y: 145, width: 18, height: 10)), with: .color(Color(hex: 0x2C3331)))
        // body
        var body = Path()
        body.move(to: CGPoint(x: 88, y: 14))
        body.addQuadCurve(to: CGPoint(x: 172, y: 14), control: CGPoint(x: 130, y: 2))
        body.addQuadCurve(to: CGPoint(x: 208, y: 70), control: CGPoint(x: 206, y: 24))
        body.addLine(to: CGPoint(x: 211, y: 384))
        body.addQuadCurve(to: CGPoint(x: 168, y: 452), control: CGPoint(x: 211, y: 444))
        body.addLine(to: CGPoint(x: 92, y: 452))
        body.addQuadCurve(to: CGPoint(x: 49, y: 384), control: CGPoint(x: 49, y: 444))
        body.addLine(to: CGPoint(x: 52, y: 70))
        body.addQuadCurve(to: CGPoint(x: 88, y: 14), control: CGPoint(x: 54, y: 24))
        body.closeSubpath()
        ctx.fill(body, with: .linearGradient(Gradient(colors: [Color(hex: 0x1B2321), Color(hex: 0x3B4542), Color(hex: 0x1B2321)]),
                                            startPoint: CGPoint(x: 49, y: 0), endPoint: CGPoint(x: 211, y: 0)))
        ctx.stroke(body, with: .color(Color(hex: 0x6B7470)), lineWidth: 1.5)
        // headlights / tail lights
        let round = StrokeStyle(lineWidth: 4, lineCap: .round)
        ctx.stroke(quad([(64, 36), (78, 22), (102, 18)]), with: .color(C.mint), style: round)
        ctx.stroke(quad([(196, 36), (182, 22), (158, 18)]), with: .color(C.mint), style: round)
        let tail = StrokeStyle(lineWidth: 3, lineCap: .round)
        ctx.stroke(quad([(62, 438), (84, 448), (104, 449)]), with: .color(Color(hex: 0xF87171, alpha: 0.8)), style: tail)
        ctx.stroke(quad([(198, 438), (176, 448), (156, 449)]), with: .color(Color(hex: 0xF87171, alpha: 0.8)), style: tail)
        // frunk
        var frunk = Path()
        frunk.move(to: CGPoint(x: 70, y: 40))
        frunk.addQuadCurve(to: CGPoint(x: 190, y: 40), control: CGPoint(x: 130, y: 22))
        frunk.addLine(to: CGPoint(x: 192, y: 116))
        frunk.addLine(to: CGPoint(x: 68, y: 116))
        frunk.closeSubpath()
        if s.frunk == "open" { ctx.fill(frunk, with: .color(Color(hex: 0x34D399, alpha: 0.22))) }
        ctx.stroke(frunk, with: .color(s.frunk == "open" ? C.mint : C.titanium), lineWidth: 1.6)
        // windshield
        let glass = GraphicsContext.Shading.linearGradient(Gradient(colors: [Color(hex: 0x2A4A40), Color(hex: 0x0F1C18)]),
                                                           startPoint: CGPoint(x: 0, y: 120), endPoint: CGPoint(x: 0, y: 160))
        var ws = Path()
        ws.addLines([CGPoint(x: 70, y: 120), CGPoint(x: 190, y: 120), CGPoint(x: 180, y: 160), CGPoint(x: 80, y: 160)])
        ws.closeSubpath()
        ctx.fill(ws, with: glass)
        ctx.stroke(ws, with: .color(C.titanium), lineWidth: 1)
        if s.defrost["windshield"] == true {
            for (y, cy) in [(132.0, 126.0), (142.0, 136.0), (152.0, 146.0)] as [(CGFloat, CGFloat)] {
                ctx.stroke(quad([(84, y), (130, cy), (176, y)]), with: .color(Color(hex: 0xFB923C)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }
        // cabin (ambient light on its rim)
        let amb = s.ambientOn ? ambientColor(s.ambientColor) : nil
        ctx.fill(rr(64, 162, 132, 162, 14), with: .color(Color(hex: 0x0A100E)))
        ctx.stroke(rr(64, 162, 132, 162, 14), with: .color(amb ?? Color(hex: 0x2C3331)), lineWidth: amb != nil ? 3 : 1)
        if s.airflow == "face" && s.fan >= 5 {
            for x in [96.0, 164.0] as [CGFloat] {
                var y: CGFloat = 166
                while y < 188 {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: x, y: min(y + 3, 188)))
                    ctx.stroke(p, with: .color(Color(hex: 0x7DD3FC)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    y += 7
                }
            }
        }
        let wheelX: CGFloat = steering == "right" ? 164 : 96
        ctx.stroke(Path(ellipseIn: CGRect(x: wheelX - 12, y: 166, width: 24, height: 24)), with: .color(s.wheelHeater ? C.warning : Color(hex: 0x59625F)), lineWidth: 4)
        // seats
        for (pos, x, y, h) in seatRect {
            let seat = ["driver", "passenger", "rear_left", "rear_right"].first { seatPos($0, steering) == pos } ?? pos
            let heat = s.seatHeater[seat]
            let vent = s.seatVentilation[seat]
            let color: Color = heat != nil && heat != "off" ? C.warning.opacity(levelAlpha[heat!] ?? 0.6)
                : vent != nil && vent != "off" ? C.vent.opacity(levelAlpha[vent!] ?? 0.5) : Color(hex: 0x26322E)
            let box = rr(x, y, 44, h, 10)
            ctx.fill(box, with: .color(color))
            ctx.stroke(box, with: .color(C.olive), lineWidth: 1)
        }
        // sunroof
        let roof = rr(114, 198, 32, 104, 8)
        ctx.fill(roof, with: .color(s.sunroof == "open" ? Color(hex: 0x34D399, alpha: 0.12) : Color(hex: 0x1E3C32, alpha: 0.75)))
        ctx.stroke(roof, with: .color(s.sunroof == "close" ? C.titanium : C.mint),
                   style: StrokeStyle(lineWidth: 1.5, dash: s.sunroof == "tilt" ? [4, 3] : []))
        // windows: a bar filled by how far each one is open
        for (pos, x, y, h) in windowBar {
            ctx.fill(rr(x, y, 5, h, 2.5), with: .color(Color(hex: 0x2A3632)))
            let level = windowLevel[s.windows[pos] ?? "close"] ?? 0
            if level > 0 { ctx.fill(rr(x, y, 5, (h * level).rounded(), 2.5), with: .color(C.mint)) }
        }
        // open doors
        for pos in doorOrder where s.doors[pos] == "open" { door(&ctx, pos, Color(hex: 0x34D399, alpha: 0.25), C.mint) }
        // rear window, rear defroster, trunk, charge port, lock
        var rear = Path()
        rear.addLines([CGPoint(x: 80, y: 328), CGPoint(x: 180, y: 328), CGPoint(x: 188, y: 352), CGPoint(x: 72, y: 352)])
        rear.closeSubpath()
        ctx.fill(rear, with: glass)
        ctx.stroke(rear, with: .color(C.titanium), lineWidth: 1)
        if s.defrost["rear"] == true {
            for (x1, x2, y) in [(84.0, 176.0, 336.0), (80.0, 180.0, 344.0)] as [(CGFloat, CGFloat, CGFloat)] {
                var p = Path()
                p.move(to: CGPoint(x: x1, y: y))
                p.addLine(to: CGPoint(x: x2, y: y))
                ctx.stroke(p, with: .color(Color(hex: 0xFB923C)), lineWidth: 1.4)
            }
        }
        var trunk = Path()
        trunk.move(to: CGPoint(x: 68, y: 356))
        trunk.addLine(to: CGPoint(x: 192, y: 356))
        trunk.addLine(to: CGPoint(x: 196, y: 420))
        trunk.addQuadCurve(to: CGPoint(x: 64, y: 420), control: CGPoint(x: 130, y: 440))
        trunk.closeSubpath()
        if s.trunk == "open" { ctx.fill(trunk, with: .color(Color(hex: 0x34D399, alpha: 0.22))) }
        ctx.stroke(trunk, with: .color(s.trunk == "open" ? C.mint : C.titanium), lineWidth: 1.8)
        ctx.fill(rr(47, 370, 7, 16, 2), with: .color(s.chargePort == "open" ? C.mint : Color(hex: 0x2C3331)))
        if s.locked || s.doorLocks.values.contains(true) {
            ctx.fill(rr(120, 384, 20, 16, 3), with: .color(C.mint))
            var shackle = Path()
            shackle.move(to: CGPoint(x: 124, y: 384))
            shackle.addLine(to: CGPoint(x: 124, y: 379))
            shackle.addArc(center: CGPoint(x: 130, y: 379), radius: 6, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            shackle.addLine(to: CGPoint(x: 136, y: 384))
            ctx.stroke(shackle, with: .color(C.mint), lineWidth: 2.5)
        }
        // a refused action's part, blinking amber
        if let blocked, blinkOpacity > 0 {
            let bf = C.warning.opacity(0.3 * blinkOpacity)
            let bs = C.warning.opacity(blinkOpacity)
            func both(_ p: Path) {
                ctx.fill(p, with: .color(bf))
                ctx.stroke(p, with: .color(bs), lineWidth: 2)
            }
            switch blocked.0 {
            case "trunk": both(trunk)
            case "frunk": both(frunk)
            case "sunroof": both(roof)
            case "chargePort": both(rr(45, 368, 11, 20, 3))
            case "lock": both(rr(116, 372, 28, 32, 5))
            case "doors": for pos in blocked.1 where doorGeom[pos] != nil { door(&ctx, pos, bf, bs) }
            case "windows":
                for pos in blocked.1 {
                    if let w = windowBar.first(where: { $0.0 == pos }) { both(rr(w.1 - 1, w.2, 7, w.3, 3)) }
                }
            default: break
            }
        }
        // audio focus / a call: two waves around the seat
        if let focusSeat, let r = seatRect.first(where: { $0.0 == focusSeat }) {
            let c = CGPoint(x: r.1 + 22, y: r.2 + 26)
            for phase in [wave, (wave + 0.5).truncatingRemainder(dividingBy: 1)] {
                // fast-out-slow-in, roughly
                let v = 1 - pow(1 - phase, 3)
                let radius = 34 * (0.8 + 0.7 * v)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(C.mint.opacity(0.9 * Double(1 - v))), lineWidth: 1.5)
            }
        }
    }
}
