#if DEBUG
import Foundation

/// Debug builds only: drives the app flow without touching the screen, for checking it on a simulator or a phone from the command line.
///
///     xcrun simctl launch --console-pty booted io.davoice.caragent.ios -autopilot "Open the driver window" "Lock the car"
///
/// Picks English, skips speaker verification, waits for the on-device model, opens the car screen and sends each request as typed
/// text (the same path as the debug text box). Every step prints one "[AUTOPILOT]" line.
@MainActor
enum Autopilot {
    static func startIfAsked(_ app: CarAgentApp) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-autopilot") else { return }
        let requests = args[(i + 1)...].filter { !$0.hasPrefix("-") }
        Task { await run(app, Array(requests)) }
    }

    private static func say(_ s: String) {
        print("[AUTOPILOT] \(s)")
        fflush(stdout)
    }

    private static func waitUntil(_ what: String, timeout: TimeInterval, _ ok: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        say("TIMEOUT waiting for \(what)")
        return false
    }

    private static func run(_ app: CarAgentApp, _ requests: [String]) async {
        say("start; requests: \(requests)")
        app.chooseLanguage("en")
        guard await waitUntil("the voice screen", timeout: 900, { app.stage == .voice || app.stage == .language && !app.message.isEmpty }) else { return }
        if app.stage != .voice {
            say("FAILED: \(app.message)")
            return
        }
        say("voices: \(app.voices), voice \(app.voice)")
        app.continueFromVoice()
        app.skipSpeaker()
        say("stage wake; model: \(app.modelStatus)")
        var last = ""
        guard await waitUntil("the model", timeout: 1800, {
            if app.modelStatus != last {
                last = app.modelStatus
                if !last.hasPrefix("Downloading") || last.hasSuffix("0%") { say("model: \(last)") }
            }
            return app.modelStatus == "Ready" || app.modelStatus.hasPrefix("Failed")
        }) else { return }
        if app.modelStatus != "Ready" {
            say("FAILED: \(app.modelStatus)")
            return
        }
        app.enterCar()
        _ = await waitUntil("the car screen", timeout: 10) { app.stage == .car }
        for r in requests {
            say("request: \(r)")
            app.sendText(r)
            _ = await waitUntil("the turn to start", timeout: 5) { app.working }
            _ = await waitUntil("the reply", timeout: 120) { !app.working }
            let action = Car.actions.last.map { "\($0.tool) \(Json.stringify($0.args)) -> \($0.ok ? "" : "BLOCKED ")\($0.summary)" } ?? "none"
            say("reply: \(app.reply) | last action: \(action) | \(app.lastTurn.outcome ?? "") \(app.lastTurn.score)")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        say("done")
    }
}
#endif
