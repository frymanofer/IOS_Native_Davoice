import SwiftUI

// The shared look of the setup screens (the other apps' redesign chrome): the emblem header, a panel with a title and a primary button
// at the bottom.

struct Emblem: View {
    var size: CGFloat = 72
    var body: some View {
        bundleImage("davoice_emblem.png").resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
            .accessibilityLabel("DaVoice")
    }
}

struct PanelScreen<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Emblem(size: 64)
                Text("DaVoice: AI Car Voice Agent").font(inter(13, .bold)).foregroundColor(C.mint).kerning(2)
            }
            .padding(.top, 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(inter(22, .heavy)).foregroundColor(C.text)
                if let subtitle {
                    Text(subtitle).font(inter(14, .medium)).foregroundColor(C.text2).lineSpacing(4).padding(.top, 6)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { content() }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 14)
                footer().padding(.top, 12)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(panelGradient)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(C.titanium, lineWidth: 1))
            .padding(16)
        }
    }
}

extension PanelScreen where Footer == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.footer = { EmptyView() }
    }
}

struct PrimaryButton: View {
    let label: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(inter(16, .bold)).foregroundColor(C.onPrimary).frame(maxWidth: .infinity, minHeight: 52)
                .background(primaryGradient).clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!enabled).opacity(enabled ? 1 : 0.5)
    }
}

struct SecondaryButton: View {
    let label: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(inter(15, .semibold)).foregroundColor(C.text).frame(maxWidth: .infinity, minHeight: 48)
                .background(C.carbon).clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.controlBorder, lineWidth: 1))
        }
        .disabled(!enabled).opacity(enabled ? 1 : 0.5)
    }
}

/// A selectable tile (a language, a voice, an option).
struct Tile: View {
    let title: String
    var detail: String?
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(inter(15, .semibold)).foregroundColor(C.text)
                if let detail { Text(detail).font(inter(12, .medium)).foregroundColor(C.text2) }
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(selected ? C.selected : C.tile).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? C.mint : C.tileBorder, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A thin progress bar (0..1).
struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(C.titanium)
                RoundedRectangle(cornerRadius: 4).fill(C.mint).frame(width: g.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 8)
    }
}

struct Centered: View {
    let text: String
    var body: some View {
        Text(text).font(inter(15, .medium)).foregroundColor(C.text2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }
}
