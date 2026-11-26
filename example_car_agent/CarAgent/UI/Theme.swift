import SwiftUI
import UIKit

// The "emerald" design tokens: the same values as the React Native, Flutter and Android example_car_agent's theme.
enum C {
    static let bg = Color(hex: 0x060908)
    static let panel = Color(hex: 0x080B0A)
    static let carbon = Color(hex: 0x26342F)
    static let carbon2 = Color(hex: 0x101513)
    static let tile = Color(hex: 0x2B3D36)
    static let tileBorder = Color(hex: 0x34D399, alpha: 0.75)
    static let controlBorder = Color(hex: 0x8C9995)
    static let panelTop = Color(hex: 0x0D1411)
    static let titanium = Color(hex: 0x4B5552)
    static let olive = Color(hex: 0x3A4D3F)
    static let emerald = Color(hex: 0x10B981)
    static let mint = Color(hex: 0x34D399)
    static let mintLight = Color(hex: 0x6EE7B7)
    static let mintPale = Color(hex: 0xD1FAE5)
    static let text = Color(hex: 0xF9FAFB)
    static let text2 = Color(hex: 0xAAB2BA)
    static let tag = Color(hex: 0xD1D5DB)
    static let onPrimary = Color(hex: 0x04140D)
    static let warning = Color(hex: 0xF59E0B)
    static let warning2 = Color(hex: 0xFBBF24)
    static let vent = Color(hex: 0x60A5FA)
    /// The card that carries the screen's main message.
    static let messageCard = Color(hex: 0x1E2B26)
    static let selected = Color(hex: 0x1C4636)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

let primaryGradient = LinearGradient(colors: [Color(hex: 0x34D399), Color(hex: 0x10B981)], startPoint: .top, endPoint: .bottom)
let panelGradient = LinearGradient(stops: [.init(color: Color(hex: 0x0D1411), location: 0), .init(color: Color(hex: 0x060908), location: 0.38),
                                           .init(color: Color(hex: 0x020303), location: 1)], startPoint: .top, endPoint: .bottom)

/// Inter, as in the other apps (Resources/fonts, listed in Info.plist).
func inter(_ size: CGFloat, _ weight: Font.Weight) -> Font {
    let name: String
    switch weight {
    case .medium: name = "Inter-Medium"
    case .semibold: name = "Inter-SemiBold"
    case .bold: name = "Inter-Bold"
    case .heavy, .black: name = "Inter-ExtraBold"
    default: name = "Inter-Regular"
    }
    return UIFont(name: name, size: size) != nil ? .custom(name, size: size) : .system(size: size, weight: weight)
}

/// An image of the app's Resources/images folder.
func bundleImage(_ name: String) -> Image {
    if let path = Bundle.main.path(forResource: name, ofType: nil, inDirectory: "images") ?? Bundle.main.path(forResource: name, ofType: nil),
       let ui = UIImage(contentsOfFile: path) {
        return Image(uiImage: ui)
    }
    return Image(systemName: "car")
}
