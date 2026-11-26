import Foundation

// A simulated car for the DaVoice Car demo (port of the React Native / Flutter / Android example_car_agent's car state): the agent's car
// tools change this state, and the car screen shows what the AI understood and which tool it used. Nothing here talks to a real vehicle.

final class CarState {
    var destination: String?
    var avoid: [String] = []

    /// Temperatures per zone (driver / passenger / rear) and the unit ('celsius' | 'fahrenheit').
    var temperature: [String: Double] = ["driver": 21, "passenger": 21, "rear": 21]
    var unit = "celsius"
    var fan = 3
    var airflow = "face"
    var defrost: [String: Bool] = ["windshield": false, "rear": false]

    /// Which side the steering wheel is on (driver / passenger are resolved from it). Brazil: left.
    var steering = "left"

    /// By place: front_left / front_right / rear_left / rear_right. Windows: open | close | half | crack; doors: open | closed.
    var windows = CarState.places("close")
    var doors = CarState.places("closed")

    /// Every door locked (the car); doorLocks has each door.
    var locked = false
    var doorLocks: [String: Bool] = ["front_left": false, "front_right": false, "rear_left": false, "rear_right": false]
    var sunroof = "close"
    var sunshade = "open"
    var trunk = "close"
    var frunk = "close"
    var chargePort = "close"
    var screen = "landscape"
    var seatHeater = CarState.seats("off")
    var seatVentilation = CarState.seats("off")
    var massageSeat = "driver"
    var massageOn = false
    var massageMode = 1
    var wheelHeater = false
    var ambientOn = false
    var ambientColor = "white"
    var readingLights = false
    var media: String?
    var radio: String?
    var source = "streaming"
    var audioFocus = "all"
    var volume = 12
    var muted = false
    var call: String?
    var scenario: String?

    /// Moving: the app refuses what isn't allowed while driving (the screen's Parked / Driving switch).
    var driving = false
    var fuelPercent = 62

    static func places(_ v: String) -> [String: String] { ["front_left": v, "front_right": v, "rear_left": v, "rear_right": v] }
    static func seats(_ v: String) -> [String: String] { ["driver": v, "passenger": v, "rear_left": v, "rear_right": v] }
}

/// One tool call the AI made: what the car screen shows.
struct CarAction: Identifiable {
    let id: Int
    let tool: String
    let args: JObj
    /// What the car did, in words.
    let summary: String
    var ok = true
    /// Set when the app refused it (vehicle state, value range): nothing was changed.
    var blocked: String?
}

/// The one simulated car. Listeners hear every change (the screen redraws).
enum Car {
    private(set) static var state = CarState()
    private(set) static var actions: [CarAction] = []
    private static var nextId = 1
    private static var listeners: [Int: () -> Void] = [:]
    private static var nextListener = 0

    /// Calls l on every change; returns the call that stops it.
    @discardableResult
    static func listen(_ l: @escaping () -> Void) -> () -> Void {
        let id = nextListener
        nextListener += 1
        listeners[id] = l
        return { listeners[id] = nil }
    }

    static func changed() { for l in listeners.values { l() } }

    static func record(_ tool: String, _ args: JObj, _ summary: String, ok: Bool = true, blocked: String? = nil) {
        actions.append(CarAction(id: nextId, tool: tool, args: args, summary: summary, ok: ok, blocked: blocked))
        nextId += 1
        if actions.count > 20 { actions.removeFirst() }
        changed()
    }

    static func setDriving(_ driving: Bool) {
        state.driving = driving
        changed()
    }

    /// The steering-wheel side (vehicle configuration); driver / passenger follow it.
    static func setSteering(_ steering: String) {
        state.steering = steering
        changed()
    }

    static func reset() {
        let keep = state
        state = CarState()
        state.driving = keep.driving
        state.steering = keep.steering
        actions.removeAll()
        changed()
    }

    /// Tests: a car in this state.
    static func replaceState(_ s: CarState) {
        state = s
        actions.removeAll()
    }
}
