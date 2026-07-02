#if canImport(SwiftUI)
import SwiftUI

/// The app's design tokens — the SwiftUI twin of Android's `QuenderinColors` / `QuenderinShapes`.
/// One source of truth for chat bubble colors, the live status accent, and the speaker-tail bubble
/// shapes, so every screen reads the same palette. Dark-first (the app's primary experience) with a
/// light variant; pick with `QuenderinPalette.of(colorScheme)`.
struct QuenderinPalette {
    let background: Color
    let surface: Color
    let surfaceVariant: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let primary: Color
    let userBubble: Color
    let onUserBubble: Color
    let userTimestamp: Color
    let assistantBubble: Color
    let onAssistantBubble: Color
    let assistantTimestamp: Color
    let status: Color
    let statusText: Color
    let dayDivider: Color
    let onDayDivider: Color

    static let dark = QuenderinPalette(
        background: Color(hex: 0x0B0B10),
        surface: Color(hex: 0x16161D),
        surfaceVariant: Color(hex: 0x1E1E27),
        onSurface: Color(hex: 0xE9E7F2),
        onSurfaceVariant: Color(hex: 0x9C99AE),
        primary: Color(hex: 0x8B83FF),
        userBubble: Color(hex: 0x5D54C4),
        onUserBubble: Color(hex: 0xF4F2FF),
        userTimestamp: Color(hex: 0xC4BFF0),
        assistantBubble: Color(hex: 0x1E1E27),
        onAssistantBubble: Color(hex: 0xE9E7F2),
        assistantTimestamp: Color(hex: 0x78758A),
        status: Color(hex: 0x37C98B),
        statusText: Color(hex: 0x8FE8C4),
        dayDivider: Color(hex: 0x1B1B23),
        onDayDivider: Color(hex: 0x8B889C)
    )

    static let light = QuenderinPalette(
        background: Color(hex: 0xF6F5FB),
        surface: Color(hex: 0xFFFFFF),
        surfaceVariant: Color(hex: 0xEDEBF5),
        onSurface: Color(hex: 0x1A1A22),
        onSurfaceVariant: Color(hex: 0x66647A),
        primary: Color(hex: 0x635BFF),
        userBubble: Color(hex: 0x635BFF),
        onUserBubble: Color(hex: 0xFFFFFF),
        userTimestamp: Color(hex: 0xDAD7FA),
        assistantBubble: Color(hex: 0xFFFFFF),
        onAssistantBubble: Color(hex: 0x1A1A22),
        assistantTimestamp: Color(hex: 0x9A98AC),
        status: Color(hex: 0x0E9E6B),
        statusText: Color(hex: 0x0E7E56),
        dayDivider: Color(hex: 0xE9E7F2),
        onDayDivider: Color(hex: 0x7A7889)
    )

    static func of(_ scheme: ColorScheme) -> QuenderinPalette { scheme == .dark ? dark : light }
}

/// Bubble shape: 18pt corners except the "tail" corner (4pt) toward the speaker (iOS 16+ / macOS 13+).
struct BubbleShape: Shape {
    let mine: Bool
    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 18, small: CGFloat = 4
        return UnevenRoundedRectangle(
            topLeadingRadius: big,
            bottomLeadingRadius: mine ? big : small,
            bottomTrailingRadius: mine ? small : big,
            topTrailingRadius: big
        ).path(in: rect)
    }
}

extension Color {
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// The model rendered as a chat "contact": a gradient orb with a monogram. Twin of Android's ModelAvatar.
struct ModelAvatar: View {
    var size: CGFloat = 40
    var body: some View {
        Circle()
            .fill(LinearGradient(
                colors: [Color(hex: 0x8A82E6), Color(hex: 0x4F46B8)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .frame(width: size, height: size)
            .overlay(
                Text("Q")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}
#endif
