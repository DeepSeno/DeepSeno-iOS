import SwiftUI

enum DeepSenoTheme {
    // Background colors
    static let bgPrimary = Color(hex: 0x09090b)
    static let bgSecondary = Color(hex: 0x18181b)
    static let bgTertiary = Color(hex: 0x27272a)

    // Text colors
    static let textPrimary = Color(hex: 0xfafafa)
    static let textSecondary = Color(hex: 0xa1a1aa)
    static let textTertiary = Color(hex: 0x71717a)

    // Accent colors
    static let accentGreen = Color(hex: 0x10b981)
    static let accentRed = Color(hex: 0xef4444)
    static let accentAmber = Color(hex: 0xf59e0b)
    static let accentBlue = Color(hex: 0x3b82f6)

    // -- Typography hierarchy --
    // Hero: large timer display
    static let timerFont = Font.system(size: 64, weight: .ultraLight, design: .rounded)

    // Titles & headlines
    static let titleFont = Font.system(.title2, design: .rounded).weight(.semibold)
    static let headlineFont = Font.system(.headline, design: .rounded).weight(.semibold)

    // Body & readable text
    static let bodyFont = Font.system(.body, design: .default)
    static let captionFont = Font.system(.caption, design: .default)

    // Monospace for data, timestamps, filenames
    static let monoFont = Font.system(.caption, design: .monospaced)
    static let monoBodyFont = Font.system(.body, design: .monospaced)

    // Section header style
    static let sectionFont = Font.system(.caption2, design: .default).weight(.semibold)

    // -- Gradients --
    static let accentGradient = LinearGradient(
        colors: [accentGreen, accentBlue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let waveformGradient = LinearGradient(
        colors: [accentGreen, accentGreen.opacity(0.6)],
        startPoint: .bottom,
        endPoint: .top
    )

    // Subtle border color for glass cards
    static let glassBorder = Color.white.opacity(0.06)
    static let glassBorderLight = Color.white.opacity(0.1)
}

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Glass Card Modifier

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 12
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(DeepSenoTheme.bgSecondary.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(DeepSenoTheme.glassBorder, lineWidth: 1)
            )
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(GlassCard(cornerRadius: 10, padding: 12))
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 12, padding: CGFloat = 14) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, padding: padding))
    }

    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}
