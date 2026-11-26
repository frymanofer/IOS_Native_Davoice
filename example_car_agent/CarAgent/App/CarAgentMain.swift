import SwiftUI

/// DaVoice: AI Car Voice Agent (native iOS). The one window shows the app flow (CarAgentApp) through RootView.
@main
struct CarAgentMain: App {
    @StateObject private var app = CarAgentMain.makeApp()

    /// The unit tests run inside the app: they get the app's resources, not its voice engines.
    private static var underTests: Bool { NSClassFromString("XCTestCase") != nil }

    @MainActor private static func makeApp() -> CarAgentApp { CarAgentApp() }

    var body: some Scene {
        WindowGroup {
            if Self.underTests {
                Text("Running tests")
            } else {
                RootView(app: app)
            }
        }
    }
}
