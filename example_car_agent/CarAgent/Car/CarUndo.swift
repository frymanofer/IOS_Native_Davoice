import Foundation

// Undo for the simulated car (agent core configure "undo"; port of the other car apps' undo): every state-changing car call returns, next
// to its result, how to put the car back exactly as it was before the call: {"undo": {"calls": [...], "previous": {...}}}, or
// {"undo": false} when that can't be done (a new destination, a radio station). The agent keeps it (never shows it to the model) and,
// on "desfaz" / "undo that", runs those calls through these same tools, so every check still applies.

private let undoPositions = ["front_left", "front_right", "rear_left", "rear_right"]
private let undoSeats = ["driver", "passenger", "rear_left", "rear_right"]

/// A copy of the parts of the car an action can change (CarState is changed in place).
func carSnapshot(_ s: CarState) -> JObj {
    var temperature = asObj(JSON(s.temperature))
    temperature["unit"] = JSON(s.unit)
    return [
        "temperature": .obj(temperature),
        "fan": JSON(s.fan),
        "airflow": JSON(s.airflow),
        "defrost": JSON(s.defrost),
        "windows": JSON(s.windows),
        "doors": JSON(s.doors),
        "doorLocks": JSON(s.doorLocks),
        "sunroof": JSON(s.sunroof),
        "sunshade": JSON(s.sunshade),
        "seatHeater": JSON(s.seatHeater),
        "seatVentilation": JSON(s.seatVentilation),
        "volume": JSON(s.volume),
        "muted": JSON(s.muted),
        "wheelHeater": JSON(s.wheelHeater),
        // no way back for these (no "cancel the route" / "previous station" tool in the demo)
        "irreversible": [
            "destination": JSON(s.destination), "avoid": JSON(s.avoid), "radio": JSON(s.radio), "media": JSON(s.media),
            "source": JSON(s.source), "audioFocus": JSON(s.audioFocus), "call": JSON(s.call), "scenario": JSON(s.scenario),
            "trunk": JSON(s.trunk), "frunk": JSON(s.frunk), "chargePort": JSON(s.chargePort), "screen": JSON(s.screen),
            "massage": [JSON(s.massageSeat), JSON(s.massageOn), JSON(s.massageMode)],
            "ambient": [JSON(s.ambientOn), JSON(s.ambientColor)], "readingLights": JSON(s.readingLights),
        ],
    ]
}

/// What changed between two snapshots, as the calls that restore before: {calls, previous}; .bool(false) = something changed that
/// can't be restored; nil = nothing changed.
func carRestoreCalls(_ before: JObj, _ after: JObj) -> JSON? {
    func changed(_ k: String) -> Bool { Json.stringify(before.raw(k) ?? .null) != Json.stringify(after.raw(k) ?? .null) }
    if changed("irreversible") { return .bool(false) }
    var calls: [JSON] = []
    var previous = JObj()
    func m(_ k: String, _ s: JObj) -> JObj { asObj(s[k]) }
    func call(_ name: String, _ args: JObj) -> JSON { ["name": JSON(name), "arguments": .obj(args)] }
    func perPosition(_ k: String, _ make: (String, JSON?) -> JSON) {
        let b = m(k, before)
        let a = m(k, after)
        let changedPos = undoPositions.filter { Json.stringify(b[$0] ?? .null) != Json.stringify(a[$0] ?? .null) }
        if changedPos.isEmpty { return }
        if changedPos.count == 4 && undoPositions.allSatisfy({ b[$0] == b["front_left"] }) {
            calls.append(make("all", b["front_left"]))
        } else {
            for p in changedPos { calls.append(make(p, b[p])) }
        }
    }

    if changed("temperature") {
        let t = m("temperature", before)
        let ta = m("temperature", after)
        previous["temperature"] = .obj(t)
        if t["driver"] == t["passenger"] && t["passenger"] == t["rear"] {
            calls.append(call("set_temperature", ["temperature": t["driver"] ?? .null, "unit": t["unit"] ?? .null]))
        } else {
            if t["driver"] != ta["driver"] || t["passenger"] != ta["passenger"] || t["unit"] != ta["unit"] {
                calls.append(call("set_dual_zone_temperature",
                                  ["driver": t["driver"] ?? .null, "passenger": t["passenger"] ?? .null, "unit": t["unit"] ?? .null]))
            }
            if t["rear"] != ta["rear"] {
                calls.append(call("set_temperature", ["temperature": t["rear"] ?? .null, "zone": "rear", "unit": t["unit"] ?? .null]))
            }
        }
    }
    if changed("fan") {
        previous["fan"] = before["fan"]
        calls.append(call("set_fan_speed", ["level": before["fan"] ?? .null]))
    }
    if changed("airflow") {
        previous["airflow"] = before["airflow"]
        calls.append(call("set_airflow", ["mode": before["airflow"] ?? .null]))
    }
    if changed("defrost") {
        previous["defrost"] = before["defrost"]
        for target in ["windshield", "rear"] where m("defrost", before)[target] != m("defrost", after)[target] {
            calls.append(call("set_defrost", ["target": JSON(target), "on": m("defrost", before)[target] ?? .null]))
        }
    }
    if changed("windows") {
        previous["windows"] = before["windows"]
        perPosition("windows") { w, v in call("set_window", ["window": JSON(w), "position": v ?? .null]) }
    }
    if changed("doors") {
        previous["doors"] = before["doors"]
        perPosition("doors") { d, v in call(v == "open" ? "open_door" : "close_doors", ["door": JSON(d)]) }
    }
    if changed("doorLocks") {
        previous["doorLocks"] = before["doorLocks"]
        perPosition("doorLocks") { d, v in call(v == true ? "lock_car" : "unlock_car", ["door": JSON(d)]) }
    }
    if changed("sunroof") {
        previous["sunroof"] = before["sunroof"]
        calls.append(call("set_sunroof", ["action": before["sunroof"] ?? .null]))
    }
    if changed("sunshade") {
        previous["sunshade"] = before["sunshade"]
        calls.append(call("set_sunshade", ["action": before["sunshade"] ?? .null]))
    }
    for k in ["seatHeater", "seatVentilation"] where changed(k) {
        previous[k] = before[k]
        for seat in undoSeats where m(k, before)[seat] != m(k, after)[seat] {
            calls.append(call("set_seat_climate", ["seat": JSON(seat), "feature": JSON(k == "seatHeater" ? "heater" : "ventilation"),
                                                   "level": m(k, before)[seat] ?? .null]))
        }
    }
    if changed("volume") || changed("muted") {
        previous["volume"] = before["volume"]
        previous["muted"] = before["muted"]
        if before["volume"] != after["volume"] { calls.append(call("set_volume", ["action": "set", "level": before["volume"] ?? .null])) }
        if before["muted"] == true && (after["muted"] != true || before["volume"] != after["volume"]) {
            calls.append(call("set_volume", ["action": "mute"]))
        } else if before["muted"] != true && after["muted"] == true {
            calls.append(call("set_volume", ["action": "unmute"]))
        }
    }
    if changed("wheelHeater") {
        previous["wheelHeater"] = before["wheelHeater"]
        calls.append(call("set_steering_wheel_heater", ["on": before["wheelHeater"] ?? .null]))
    }
    if calls.isEmpty { return nil }
    return ["calls": .arr(calls), "previous": .obj(previous)]
}
