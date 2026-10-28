import SwiftUI

/// A colour theme for LiveWallpaper's own windows: a soft gradient behind the content and a matching
/// highlight colour. It's drawn once (no animation), so it costs nothing while the window is open.
enum ColorTheme: String, CaseIterable, PrefValue {
    case plain, aurora, sunset, ocean, forest, candy, ember, midnight

    var title: String { rawValue.capitalized }

    /// 3×3 mesh colours, top-left to bottom-right (nil for Plain).
    var colors: [Color]? {
        func c(_ hex: UInt32) -> Color { Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
        let hexes: [UInt32]
        switch self {
        case .plain: return nil
        case .aurora: hexes = [0x2DD4BF, 0x22C55E, 0x6366F1, 0x0EA5E9, 0x14B8A6, 0x8B5CF6, 0x4F46E5, 0x7C3AED, 0xA855F7]
        case .sunset: hexes = [0xFBBF24, 0xF97316, 0xF43F5E, 0xFB923C, 0xEC4899, 0xA855F7, 0xE11D48, 0x9333EA, 0x6D28D9]
        case .ocean: hexes = [0x67E8F9, 0x38BDF8, 0x0EA5E9, 0x22D3EE, 0x2563EB, 0x1D4ED8, 0x0891B2, 0x1E40AF, 0x1E3A8A]
        case .forest: hexes = [0xBEF264, 0x84CC16, 0x10B981, 0x65A30D, 0x059669, 0x0F766E, 0x15803D, 0x047857, 0x134E4A]
        case .candy: hexes = [0xF9A8D4, 0xF472B6, 0xC084FC, 0xFBCFE8, 0xD8B4FE, 0x93C5FD, 0xE879F9, 0xA78BFA, 0x60A5FA]
        case .ember: hexes = [0xFDE047, 0xFACC15, 0xF97316, 0xFB923C, 0xEA580C, 0xDC2626, 0xF59E0B, 0xB91C1C, 0x7F1D1D]
        case .midnight: hexes = [0x4338CA, 0x312E81, 0x1E1B4B, 0x3730A3, 0x1E293B, 0x0F172A, 0x581C87, 0x1E1B4B, 0x020617]
        }
        return hexes.map(c)
    }

    /// The highlight colour that goes with it (used while Accent colour is System).
    var tint: Color? {
        switch self {
        case .plain: nil
        case .aurora: Color(red: 0.08, green: 0.72, blue: 0.65)
        case .sunset: Color(red: 0.93, green: 0.28, blue: 0.6)
        case .ocean: Color(red: 0.15, green: 0.39, blue: 0.92)
        case .forest: Color(red: 0.02, green: 0.59, blue: 0.41)
        case .candy: Color(red: 0.75, green: 0.42, blue: 0.95)
        case .ember: Color(red: 0.92, green: 0.35, blue: 0.05)
        case .midnight: Color(red: 0.39, green: 0.4, blue: 0.95)
        }
    }

    /// The gradient itself, full strength (swatches) — the window background softens it.
    @ViewBuilder var gradient: some View {
        if let colors {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.6, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: colors)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

extension Prefs {
    /// The highlight colour in use: the chosen accent, else the theme's, else macOS's.
    var tint: Color? { accent.color ?? colorTheme.tint }
}

/// The theme's gradient behind a window's content, toned down so text stays readable.
struct ThemeBackground: View {
    let theme: ColorTheme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if theme != .plain {
            theme.gradient
                .opacity(scheme == .dark ? 0.5 : 0.35)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

/// A row of round swatches, like System Settings' accent colours. (A pop-up menu can't show colours:
/// macOS draws every symbol in a menu in plain white.)
struct SwatchPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let fill: (Value) -> AnyShapeStyle
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Circle()
                        .fill(fill(option))
                        .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                        .frame(width: size, height: size)
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.7) : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(title(option))
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Theme cards: a small gradient preview with its name.
struct ThemePicker: View {
    @Binding var selection: ColorTheme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
            ForEach(ColorTheme.allCases, id: \.self) { theme in
                let selected = theme == selection
                Button { selection = theme } label: {
                    VStack(spacing: 5) {
                        theme.gradient
                            .frame(height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.appAccent : .clear, lineWidth: 2))
                        Text(theme.title).font(.caption).foregroundStyle(selected ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(theme.title) theme")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

extension Color {
    /// The app's highlight colour (Accent colour, else the theme's, else macOS's). Unlike
    /// `Color.accentColor`, this follows the colour chosen in Settings.
    @MainActor static var appAccent: Color { Prefs.shared.tint ?? .accentColor }
}
