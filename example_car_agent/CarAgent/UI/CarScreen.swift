import SwiftUI

// The car agent's screen (the same layout as the other car apps' car screen): header with Parked / Driving, a status banner, the car seen
// from above with temperatures / fan / fuel / volume / doors beside it, the last message card (what was heard, what ran, the reply, the
// model's score when held back), the microphone line (tap to talk) and, in debug builds, suggestion chips and a text box, and the
// settings sheet behind the gear (conversation mode, model, Local confidence).

private let suggestionsEn = ["Open the driver window", "I'm cold", "Open the sunroof", "Take me home", "Call Ana", "Open the trunk", "Set the AC to 19",
                             "Ambient light blue", "Open the rear left door", "Lock the car", "Play Anitta", "How much fuel do I have?",
                             "Defrost the windshield", "Volume 20"]
private let suggestionsPt = ["Abre o vidro do motorista", "Tô com frio", "Abre o teto", "Me leva pra casa", "Liga pra Ana", "Abre o porta-malas",
                             "Coloca o ar em 19", "Luz ambiente azul", "Abre a porta traseira esquerda", "Tranca o carro", "Toca Anitta",
                             "Quanto tem de combustível?", "Desembaça o vidro", "Volume 20"]

private func banner(_ s: CarState) -> (String, String)? {
    if let c = s.call { return ("Calling \(c)", "Phone") }
    if let d = s.destination { return ("→ \(d)", s.avoid.isEmpty ? "Navigation" : "avoid \(s.avoid.joined(separator: ", "))") }
    if let r = s.radio { return ("♪ \(r)", "Radio") }
    if let m = s.media { return ("♪ \(m)", s.source) }
    if let sc = s.scenario { return ("\(sc.replacingOccurrences(of: "_", with: " ")) mode", "") }
    return nil
}

#if DEBUG
private let debugBuild = true
#else
private let debugBuild = false
#endif

struct CarScreen: View {
    @ObservedObject var app: CarAgentApp
    @State private var settingsOpen = false
    @State private var text = ""

    var body: some View {
        let _ = app.carVersion // redraw on every car change
        let s = Car.state
        let actions = Car.actions
        let latest = actions.last
        let openDoors = s.doors.values.filter { $0 == "open" }.count
        let doorsLabel = openDoors > 0 ? "\(openDoors) open" : s.locked ? "Locked" : s.doorLocks.values.contains(true) ? "Part locked" : "Unlocked"
        let blocked = latest != nil && !latest!.ok
        let title = app.working ? "Working…" : app.ignored ? "Ignored" : latest.map { "\(blocked ? "Blocked: " : "")\(cap($0.summary))" } ?? "Ready"
        let pool = app.language == "pt-BR" ? suggestionsPt : suggestionsEn
        let k = (actions.count * 3) % pool.count
        let chips = (0..<3).map { pool[(k + $0) % pool.count] }

        ZStack {
            VStack(spacing: 0) {
                header(s)
                Rectangle().fill(C.mint).frame(height: 1)
                HStack(spacing: 8) {
                    if let pop = banner(s) {
                        HStack(spacing: 10) {
                            Circle().fill(C.mint).frame(width: 8, height: 8)
                            Text(pop.0).font(inter(13, .semibold)).foregroundColor(C.text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            if !pop.1.isEmpty { Text(pop.1).font(inter(12, .regular)).foregroundColor(C.text2).lineLimit(1) }
                        }
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(C.mint.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.mint, lineWidth: 1))
                    } else {
                        Spacer()
                    }
                    IconBox(label: "Reset car and chat") {
                        Car.reset()
                        app.resetChat()
                    } content: { Image(systemName: "arrow.counterclockwise").foregroundColor(C.text) }
                    IconBox(label: "Settings: conversation, model and local confidence") { settingsOpen = true } content: {
                        Image(systemName: "gearshape.fill").foregroundColor(C.text)
                    }
                }
                .padding(.horizontal, 12).padding(.top, 6).frame(height: 50)
                // the car and the stats beside it
                GeometryReader { g in
                    let sideW = max(76, g.size.width * 0.2)
                    let carW = min(g.size.height * carAspect, g.size.width - sideW * 2)
                    ZStack(alignment: .top) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 18) {
                                Stat(label: "Driver", value: "\(Json.num(s.temperature["driver"] ?? 21))°", big: true)
                                Stat(label: "Fan", value: "\(s.fan)", unit: " / 7")
                                Stat(label: "Fuel", value: "\(s.fuelPercent)%")
                            }
                            .frame(width: sideW, alignment: .leading)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 18) {
                                Stat(label: "Passenger", value: "\(Json.num(s.temperature["passenger"] ?? 21))°", big: true, end: true)
                                Stat(label: "Volume", value: s.muted ? "Muted" : "\(s.volume)", sub: s.radio != nil ? "Radio" : s.source, end: true)
                                Stat(label: "Doors", value: doorsLabel, color: openDoors > 0 || s.locked ? C.mint : nil, end: true)
                            }
                            .frame(width: sideW, alignment: .trailing)
                        }
                        .padding(.horizontal, 10).padding(.top, 24)
                        if carW > 0 {
                            CarDrawing(state: s, latest: latest, width: carW, version: app.carVersion)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .padding(.top, 4)
                // the last message
                VStack(alignment: .leading, spacing: 3) {
                    if !app.heard.isEmpty { Text("“\(app.heard)”").font(inter(13, .medium)).foregroundColor(C.text2).lineLimit(1) }
                    Text(title).font(inter(17, .heavy)).foregroundColor(blocked && !app.working ? C.warning2 : .white).lineLimit(1)
                    if !app.reply.isEmpty && !app.ignored { Text(app.reply).font(inter(14, .medium)).foregroundColor(Color(hex: 0xA7F3D0)).lineLimit(2) }
                    if !app.working && app.lastTurn.low {
                        Text("Held back · \(app.lastTurn.score.isEmpty ? "low score" : app.lastTurn.score)").font(inter(12, .medium)).foregroundColor(C.warning2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(C.messageCard).clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(blocked ? C.warning.opacity(0.8) : (latest != nil || !app.heard.isEmpty) ? C.mint : Color(hex: 0x1F2B27),
                                                                    lineWidth: 1.5))
                .padding(.horizontal, 12).padding(.top, 6)
                ModelStatusView(app: app).padding(.horizontal, 12).padding(.top, 6)
                // what the microphone is doing and what to say
                let asleep = app.conversationPhase == .asleep
                Button { app.tapToTalk() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mic").foregroundColor(asleep ? C.text2 : C.mint)
                        Text(conversationHint(app.conversationPhase, VoiceConfig.wakePhrase, app.conversationSettings.wakeWord))
                            .font(inter(15, .medium)).foregroundColor(C.tag).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 14).frame(height: 56)
                    .background(Color(hex: 0x1A2622)).clipShape(Capsule())
                    .overlay(Capsule().stroke(asleep ? C.titanium : C.mint, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(!conversationTapEnabled(app.conversationPhase))
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, debugBuild ? 0 : 16)
                if debugBuild { debugInput(chips) }
            }
            if settingsOpen { SettingsSheet(app: app) { settingsOpen = false } }
        }
    }

    private func header(_ s: CarState) -> some View {
        HStack(spacing: 8) {
            Button { app.leaveCar() } label: { Image(systemName: "chevron.left").foregroundColor(C.text).frame(width: 44, height: 44) }
                .accessibilityLabel("Back")
            Emblem(size: 32)
            Text("Car Agent").font(inter(15, .bold)).foregroundColor(C.text).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                ForEach([false, true], id: \.self) { driving in
                    let on = s.driving == driving
                    Button { Car.setDriving(driving) } label: {
                        Text(driving ? "Driving" : "Parked").font(inter(13, .semibold)).foregroundColor(on ? C.onPrimary : C.tag)
                            .padding(.horizontal, 11).frame(height: 38)
                            .background(on ? C.emerald : Color.clear).clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(3).background(C.carbon).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0x2A3632), lineWidth: 1))
        }
        .padding(.horizontal, 10).frame(height: 56)
    }

    private func debugInput(_ chips: [String]) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.self) { c in
                    Button { app.sendText(c) } label: {
                        Text(c).font(inter(12, .semibold)).foregroundColor(.white).lineLimit(1).padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 40).background(C.carbon).clipShape(Capsule())
                            .overlay(Capsule().stroke(C.mint.opacity(0.75), lineWidth: 1))
                    }
                    .buttonStyle(.plain).disabled(app.working)
                }
            }
            HStack(spacing: 8) {
                TextField("What the driver says…", text: $text)
                    .font(inter(15, .regular)).foregroundColor(C.text).disabled(app.working)
                    .submitLabel(.send).onSubmit(send)
                    .accessibilityLabel("What the driver says")
                Button(action: send) {
                    Image(systemName: "arrow.right").foregroundColor(C.onPrimary).frame(width: 44, height: 44).background(primaryGradient).clipShape(Circle())
                }
                .accessibilityLabel("Send")
            }
            .padding(.leading, 14).padding(.trailing, 6).frame(height: 56)
            .background(Color(hex: 0x1A2622)).clipShape(Capsule())
            .overlay(Capsule().stroke(C.mint, lineWidth: 1.5))
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 16)
    }

    private func send() {
        let t = text.trimmed
        if t.isEmpty { return }
        app.sendText(t)
        text = ""
    }
}

private struct Stat: View {
    let label: String
    let value: String
    var unit: String?
    var sub: String?
    var big = false
    var color: Color?
    var end = false

    var body: some View {
        VStack(alignment: end ? .trailing : .leading, spacing: 1) {
            Text(label.uppercased()).font(inter(10, .bold)).foregroundColor(C.text2).kerning(1.2)
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text(value).font(inter(big ? 28 : 18, .bold)).foregroundColor(color ?? C.text).lineLimit(1).minimumScaleFactor(0.6)
                if let unit { Text(unit).font(inter(12, .regular)).foregroundColor(C.text2) }
            }
            if let sub { Text(sub).font(inter(11, .regular)).foregroundColor(C.text2).lineLimit(1) }
        }
    }
}

private struct IconBox<Content: View>: View {
    let label: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content().frame(width: 44, height: 44).background(C.carbon).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0x2A3632), lineWidth: 1))
        }
        .accessibilityLabel(label)
    }
}
