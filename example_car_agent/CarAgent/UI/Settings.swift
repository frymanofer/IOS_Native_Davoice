import SwiftUI

// The settings sheet (the same controls and words as the other apps): the conversation mode (ConversationSettingsPanel), the model,
// Local confidence (ConfidenceControls) and the privacy policy. The sheet edits a draft; nothing changes in the app until Save.

/// The app's privacy policy (as the React Native car agent's PrivacyPolicyLink).
private let privacyPolicyURL = URL(string: "https://davoice.io/privacy/car-agent")!

struct SettingsSheet: View {
    @ObservedObject var app: CarAgentApp
    let close: () -> Void
    @State private var conversation: ConversationSettings
    @State private var confidence: ConfidenceSettings
    @Environment(\.openURL) private var openURL

    init(app: CarAgentApp, close: @escaping () -> Void) {
        self.app = app
        self.close = close
        _conversation = State(initialValue: app.conversationSettings)
        _confidence = State(initialValue: app.confidence)
    }

    var body: some View {
        let dirty = conversation != app.conversationSettings || confidence != app.confidence
        ZStack(alignment: .top) {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture(perform: close)
            VStack(spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(text: "CONVERSATION")
                        ConversationSettingsPanel(value: $conversation, wakePhrase: VoiceConfig.wakePhrase)
                        Rectangle().fill(C.titanium).frame(height: 1)
                        SectionTitle(text: "MODEL")
                        SettingRow(label: "Model", value: "\(CarModel.displayName)\(!app.modelStatus.isEmpty && app.modelStatus != "Ready" ? " · \(app.modelStatus)" : "")")
                        ConfidenceControls(value: $confidence, disabled: app.working)
                        Rectangle().fill(C.titanium).frame(height: 1)
                        SectionTitle(text: "ABOUT")
                        SettingRow(label: "Privacy policy", value: "davoice.io/privacy/car-agent", action: "Open") { openURL(privacyPolicyURL) }
                    }
                }
                HStack(spacing: 10) {
                    SecondaryButton(label: "Cancel", action: close)
                    PrimaryButton(label: "Save", enabled: dirty) {
                        if conversation != app.conversationSettings { app.changeConversation(conversation) }
                        if confidence != app.confidence { app.changeConfidence(confidence) }
                        close()
                    }
                }
            }
            .padding(16)
            .background(C.panel).clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.titanium, lineWidth: 1))
            .padding(.horizontal, 12).padding(.top, 112).padding(.bottom, 24)
        }
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View { Text(text).font(inter(11, .bold)).foregroundColor(C.mint).kerning(2) }
}

private struct Label2: View {
    let text: String
    var body: some View { Text(text).font(inter(14, .bold)).foregroundColor(C.text) }
}

private struct Caption: View {
    let text: String
    var body: some View { Text(text).font(inter(12, .medium)).foregroundColor(C.text2) }
}

private struct Segments: View {
    let options: [(String, String)]
    let selected: String
    let label: String
    var enabled = true
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.0) { key, text in
                let on = key == selected
                Button { onSelect(key) } label: {
                    Text(text).font(inter(13, on ? .bold : .medium)).foregroundColor(on ? C.text : C.text2).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 40).padding(.horizontal, 4)
                        .background(on ? C.selected : C.carbon).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? C.mint : C.controlBorder, lineWidth: on ? 2 : 1))
                }
                .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.5)
                .accessibilityLabel("\(label): \(text)").accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

private struct ChoiceRow: View {
    let label: String
    let detail: String
    let choices: [Choice]
    let value: Int
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label2(text: label)
            Segments(options: choices.map { ("\($0.value)", $0.label) }, selected: "\(value)", label: label) { onSelect(Int($0) ?? value) }
            Caption(text: detail)
        }
        .padding(.top, 14)
    }
}

/// Take turns or interrupt, wake word or just talk, and each mode's timeouts.
struct ConversationSettingsPanel: View {
    @Binding var value: ConversationSettings
    let wakePhrase: String

    var body: some View {
        let w = value.wakeWordMode
        let f = value.freeMode
        VStack(alignment: .leading, spacing: 6) {
            Label2(text: "Turns")
            Segments(options: [("turns", "Take turns"), ("interrupt", "Interrupt")], selected: value.interrupt ? "interrupt" : "turns", label: "Turns") {
                value.interrupt = $0 == "interrupt"
            }
            Caption(text: value.interrupt ? "Talk over the agent to stop it. Uses echo cancellation (AEC)." : "Listening pauses while the agent answers.")
            Label2(text: "Start each request with").padding(.top, 8)
            Segments(options: [("wake", "Wake word"), ("free", "Just talk")], selected: value.wakeWord ? "wake" : "free", label: "Start each request with") {
                value.wakeWord = $0 == "wake"
            }
            Caption(text: value.wakeWord ? "Say “\(wakePhrase)” before a request. When the agent asks a question, answer without it."
                : "After the first wake word, just talk: no wake word needed.")
            if value.wakeWord {
                ChoiceRow(label: "End of speech", detail: "Silence that ends your request", choices: endOfSpeechChoices, value: w.endOfSpeechMs) { value.wakeWordMode.endOfSpeechMs = $0 }
                ChoiceRow(label: "Listen after the wake word", detail: "Then back to the wake word", choices: listenChoices, value: w.listenMs) { value.wakeWordMode.listenMs = $0 }
                ChoiceRow(label: "Follow-up without the wake word",
                          detail: w.followUpMs > 0 ? "After a question from the agent, how long it waits for your answer" : "The wake word before every request, even after a question",
                          choices: followUpChoices, value: w.followUpMs) { value.wakeWordMode.followUpMs = $0 }
                ChoiceRow(label: "Pre-fetch", detail: w.preFetchMs > 0 ? "Keeps words said right after the wake word" : "Wait for the recognizer after the wake word",
                          choices: preFetchChoices, value: w.preFetchMs) { value.wakeWordMode.preFetchMs = $0 }
                if !value.interrupt {
                    Toggle(isOn: Binding(get: { value.wakeWordMode.stopWord }, set: { value.wakeWordMode.stopWord = $0 })) {
                        VStack(alignment: .leading) {
                            Label2(text: "Wake word stops the agent")
                            Caption(text: "“\(wakePhrase)” while it talks, then your request")
                        }
                    }
                    .tint(C.emerald).padding(.top, 14)
                }
            } else {
                ChoiceRow(label: "End of speech", detail: "Silence that ends your request", choices: endOfSpeechChoices, value: f.endOfSpeechMs) { value.freeMode.endOfSpeechMs = $0 }
                ChoiceRow(label: "Stop listening after", detail: f.idleMs > 0 ? "Then say “\(wakePhrase)” or tap the microphone" : "Listening stays on",
                          choices: idleChoices, value: f.idleMs) { value.freeMode.idleMs = $0 }
            }
        }
    }
}

/// Local confidence: ON / OFF, the threshold (0.00 .. 1.00 in 0.05 steps, "0.90 / 90%") and what a command below it becomes. OFF keeps
/// today's behaviour; the safety checks apply either way.
struct ConfidenceControls: View {
    @Binding var value: ConfidenceSettings
    let disabled: Bool

    var body: some View {
        let off = !value.enabled
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $value.enabled) {
                VStack(alignment: .leading) {
                    Label2(text: "Local confidence")
                    Caption(text: value.enabled ? "On · \(formatThreshold(value.threshold))" : "Off")
                }
            }
            .tint(C.emerald).disabled(disabled)
            HStack {
                Slider(value: Binding(get: { snapThreshold(value.threshold) }, set: { value.threshold = snapThreshold($0) }), in: 0...1, step: confidenceStep)
                    .tint(C.mint).disabled(disabled).accessibilityLabel("Confidence threshold")
                Text(formatThreshold(value.threshold)).font(inter(13, .bold)).foregroundColor(C.text).frame(width: 92, alignment: .trailing)
            }
            .opacity(off ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 6) {
                Caption(text: "Below the threshold:")
                Segments(options: confidenceFallbacks.map { ($0, confidenceFallbackLabels[$0]!) }, selected: value.fallback, label: "Below the threshold",
                         enabled: !disabled) { value.fallback = $0 }
                Caption(text: confidenceFallbackDetails[value.fallback] ?? "")
            }
            .opacity(off ? 0.45 : 1)
        }
    }
}

/// A labelled row with an action button.
struct SettingRow: View {
    let label: String
    let value: String
    var action: String?
    var onTap: () -> Void = {}

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(label).font(inter(14, .semibold)).foregroundColor(C.text)
                Text(value).font(inter(12, .regular)).foregroundColor(C.text2).lineLimit(2)
            }
            Spacer()
            if let action {
                Button(action: onTap) {
                    Text(action).font(inter(14, .semibold)).foregroundColor(C.mint).padding(.horizontal, 16).frame(minHeight: 44)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.mint.opacity(0.5), lineWidth: 1))
                }
            }
        }
    }
}
