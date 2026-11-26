import Foundation
import XCTest
@testable import CarAgent

// Test helpers: the app's resources and the shared fixtures (CarAgentTests/fixtures, kept identical to the React Native car app's
// __tests__/fixtures, the Flutter car app's test/fixtures and the Android car app's src/test/resources/fixtures).

final class TestSupport {
    private static var loaded = false

    /// A file of the app's Resources (the tests run inside the app, so they are in the main bundle).
    static func asset(_ path: String) throws -> String {
        let url = Bundle.main.bundleURL.appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func load() throws {
        if loaded { return }
        try CarTools.load { try asset($0) }
        try AgentPack.load { try asset($0) }
        CarTools.log = { _ in }
        loaded = true
    }

    static func fixtureText(_ name: String) throws -> String {
        let url = Bundle(for: TestSupport.self).bundleURL.appendingPathComponent("fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func fixture(_ name: String) throws -> JSON { try Json.parse(try fixtureText(name)) }

    /// The React Native car app's copy, when the repositories sit side by side (nil otherwise).
    static func rnFixture(_ name: String) -> String? {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = here.appendingPathComponent("../../../ReactNative_DaVoice/example_car_agent/__tests__/fixtures/\(name)").standardized
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The demo's starting car with the case's changes (only what differs from the start is in the fixture).
    static func carWith(_ changes: JObj) -> CarState {
        let s = CarState()
        func strings(_ v: JSON) -> [String: String] { var m: [String: String] = [:]; for (k, x) in asObj(v) { m[k] = str(x) }; return m }
        for (k, v) in changes {
            switch k {
            case "windows": s.windows = strings(v)
            case "doors": s.doors = strings(v)
            case "doorLocks": var m: [String: Bool] = [:]; for (d, x) in asObj(v) { m[d] = x == true }; s.doorLocks = m
            case "locked": s.locked = v == true
            case "sunroof": s.sunroof = str(v)
            case "seatHeater": s.seatHeater = strings(v)
            case "seatVentilation": s.seatVentilation = strings(v)
            case "temperature":
                let t = asObj(v)
                for z in ["driver", "passenger", "rear"] { if let d = t[z]?.double { s.temperature[z] = d } }
                if let u = t["unit"]?.string { s.unit = u }
            case "volume": s.volume = Int(v.double ?? 0)
            case "muted": s.muted = v == true
            case "fan": s.fan = Int(v.double ?? 0)
            case "media": s.media = v.string
            case "radio": s.radio = v.string
            case "destination": s.destination = v.string
            default: XCTFail("fixture state \"\(k)\" is not mapped")
            }
        }
        return s
    }
}

/// "the reply / the text" check of a TurnInput against a fixture's expect.
func turnMatches(_ got: TurnInput, _ want: JObj) -> Bool {
    if want.has("reply") { return got.reply == want["reply"]?.string && got.text == nil }
    return got.text == want["text"]?.string && got.reply == nil
}
