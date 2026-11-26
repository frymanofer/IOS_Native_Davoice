import SwiftUI

// The setup screens (the other apps' redesign: language, voice, speaker, wake word) and the screen switch.

struct RootView: View {
    @ObservedObject var app: CarAgentApp

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            switch app.stage {
            case .language: LanguageScreen(app: app)
            case .download: DownloadScreen(app: app)
            case .preparing:
                PanelScreen(title: "Getting ready") {
                    ProgressView().tint(C.mint).frame(maxWidth: .infinity)
                    Centered(text: app.message)
                }
            case .voice: VoiceScreen(app: app)
            case .speaker: SpeakerScreen(app: app)
            case .enroll: EnrollScreen(app: app)
            case .wake: WakeWordScreen(app: app)
            case .car: CarScreen(app: app)
            }
        }
        .preferredColorScheme(.dark)
        #if DEBUG
        .onAppear { Autopilot.startIfAsked(app) }
        #endif
    }
}

private struct LanguageScreen: View {
    @ObservedObject var app: CarAgentApp
    var body: some View {
        ZStack {
            bundleImage("hood_background.jpg").resizable().scaledToFill().opacity(0.35).ignoresSafeArea()
            PanelScreen(title: "Choose your language", subtitle: "The car agent listens and answers in this language. Its voice downloads the first time.") {
                if !app.message.isEmpty { Text(app.message).font(inter(13, .medium)).foregroundColor(C.warning2) }
                ForEach(appLanguageInfos.filter { !$0.hidden }, id: \.id) { l in
                    let missing = app.packs.missingBytes(l.id)
                    Tile(title: l.label, detail: missing > 0 ? "Download \(missing / 1_000_000) MB" : "Ready", selected: l.id == app.language) {
                        app.chooseLanguage(l.id)
                    }
                }
            }
        }
    }
}

private struct DownloadScreen: View {
    @ObservedObject var app: CarAgentApp
    var body: some View {
        let total = max(app.downloadTotal, 1)
        PanelScreen(title: "Downloading the voice", subtitle: appLanguageInfo(app.language).label) {
            ProgressBar(fraction: Double(app.downloadDone) / Double(total))
            Centered(text: "\(app.downloadDone / 1_000_000) / \(app.downloadTotal / 1_000_000) MB")
        }
    }
}

private struct VoiceScreen: View {
    @ObservedObject var app: CarAgentApp
    var body: some View {
        PanelScreen(title: "Choose a voice", subtitle: "Tap a voice to hear it.") {
            ForEach(app.voices, id: \.self) { v in Tile(title: v, selected: v == app.voice) { app.chooseVoice(v) } }
        } footer: {
            PrimaryButton(label: "Continue") { app.continueFromVoice() }
        }
    }
}

private struct SpeakerScreen: View {
    @ObservedObject var app: CarAgentApp
    var body: some View {
        PanelScreen(title: "Speaker verification",
                    subtitle: "With a voice signature the car agent opens and unlocks doors only for your voice, and the wake word answers only you.") {
            if !app.message.isEmpty { Text(app.message).font(inter(13, .medium)).foregroundColor(C.warning2) }
            if app.svHasSaved { Tile(title: "Use my saved signature", detail: "Recorded earlier on this phone") { app.useSavedSpeaker() } }
            Tile(title: "Create a new signature", detail: "Read \(VoiceConfig.svOnboardingSampleCount) short sentences") { app.createSpeaker() }
            Tile(title: "Skip", detail: "Anyone can use the car agent") { app.skipSpeaker() }
        }
    }
}

private struct EnrollScreen: View {
    @ObservedObject var app: CarAgentApp
    var body: some View {
        let n = VoiceConfig.svOnboardingSampleCount
        let i = max(0, min(app.svCollected, app.svSentences.count - 1))
        PanelScreen(title: "Read this aloud", subtitle: "Sample \(min(app.svCollected + 1, n)) of \(n)") {
            ProgressBar(fraction: Double(app.svCollected) / Double(n))
            Text(app.svSentences.indices.contains(i) ? app.svSentences[i] : "").font(inter(22, .bold)).foregroundColor(C.text)
                .lineSpacing(6).padding(.top, 12)
            Centered(text: "Speak in your normal voice.")
        }
    }
}

private struct WakeWordScreen: View {
    @ObservedObject var app: CarAgentApp
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack { Circle().fill(C.carbon2); Emblem(size: 150) }.frame(width: 180, height: 180)
            Text("Say “\(VoiceConfig.wakePhrase)”").font(inter(30, .heavy)).foregroundColor(C.text).multilineTextAlignment(.center)
            Text(app.message).font(inter(15, .medium)).foregroundColor(C.text2).multilineTextAlignment(.center)
            let lang = appLanguageInfo(app.language).label.components(separatedBy: " (")[0]
            Text("\(app.voice) · \(lang)\(app.driverOnly ? " · your voice only" : "")").font(inter(13, .medium)).foregroundColor(C.tag)
            ModelStatusView(app: app)
            SecondaryButton(label: "Start without the wake word") { app.enterCar() }.padding(.top, 8)
            Spacer()
        }
        .padding(24)
    }
}

/// The on-device model's download / loading (it continues in the background).
struct ModelStatusView: View {
    @ObservedObject var app: CarAgentApp
    var body: some View {
        let s = app.modelStatus
        if !s.isEmpty && s != "Ready" {
            VStack(alignment: .leading, spacing: 6) {
                Text("DaVoice Automotive Agent: \(s)").font(inter(13, .semibold)).foregroundColor(s.hasPrefix("Failed") ? C.warning2 : C.mint)
                if s.hasPrefix("Downloading") { ProgressBar(fraction: app.modelProgress) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
