#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    // Code-block token colors (MarkdownText syntax highlighting).
    let codeKeyword: Color
    let codeString: Color
    let codeComment: Color
    let codeNumber: Color

    // The palette is DERIVED FROM THE BRAND ARTWORK (brand/icon-square-1024.png), not from a
    // SaaS template: teal #52939A = her braids/eyes/choker, copper #EDA04F = the "Q" and the
    // warm braid strands, warm paper + leather in the light theme. Sampled 2026-07-03
    // (scripts/generate_icons.py's source image); change the art → resample, don't guess.
    static let dark = QuenderinPalette(
        background: Color(hex: 0x0B0F10),
        surface: Color(hex: 0x141A1B),
        surfaceVariant: Color(hex: 0x1C2426),
        onSurface: Color(hex: 0xE8EDEA),
        onSurfaceVariant: Color(hex: 0x93A19E),
        primary: Color(hex: 0x52939A),
        userBubble: Color(hex: 0x245A62),
        onUserBubble: Color(hex: 0xEAF6F4),
        userTimestamp: Color(hex: 0xA8CDD1),
        assistantBubble: Color(hex: 0x1C2426),
        onAssistantBubble: Color(hex: 0xE8EDEA),
        assistantTimestamp: Color(hex: 0x798682),
        status: Color(hex: 0x37C98B),
        statusText: Color(hex: 0x8FE8C4),
        dayDivider: Color(hex: 0x171E1F),
        onDayDivider: Color(hex: 0x8C9996),
        codeKeyword: Color(hex: 0xC792EA),
        codeString: Color(hex: 0xC3E88D),
        codeComment: Color(hex: 0x7A8682),
        codeNumber: Color(hex: 0xEDA04F)
    )

    static let light = QuenderinPalette(
        background: Color(hex: 0xF5F4EF),
        surface: Color(hex: 0xFFFFFF),
        surfaceVariant: Color(hex: 0xE9E7DE),
        onSurface: Color(hex: 0x1C2224),
        onSurfaceVariant: Color(hex: 0x5D6B68),
        primary: Color(hex: 0x2E7680),
        userBubble: Color(hex: 0x2E7680),
        onUserBubble: Color(hex: 0xFFFFFF),
        userTimestamp: Color(hex: 0xC9E4E6),
        assistantBubble: Color(hex: 0xFFFFFF),
        onAssistantBubble: Color(hex: 0x1C2224),
        assistantTimestamp: Color(hex: 0x97A4A1),
        status: Color(hex: 0x0E9E6B),
        statusText: Color(hex: 0x0B7E57),
        dayDivider: Color(hex: 0xE7E5DC),
        onDayDivider: Color(hex: 0x77837F),
        codeKeyword: Color(hex: 0x8E44AD),
        codeString: Color(hex: 0x448C27),
        codeComment: Color(hex: 0x97A4A1),
        codeNumber: Color(hex: 0xB4632A)
    )

    static func of(_ scheme: ColorScheme) -> QuenderinPalette { scheme == .dark ? dark : light }
}

/// What this device is called in user-facing copy — the same QuenderinKit UI now ships on the
/// Mac (QuenderinMac target), where "runs on your phone" reads wrong.
var deviceNoun: String {
    #if os(macOS)
    return "Mac"
    #else
    return "phone"
    #endif
}

extension View {
    /// The app's "chrome" surface — Liquid Glass on OS 26+ (compiled with the 26 SDK),
    /// ultra-thin material on earlier systems. Chrome only (composer, pills, overlays):
    /// per Apple's Liquid Glass guidance the CONTENT layer (bubbles, text) stays opaque.
    @ViewBuilder func glassChrome<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    /// Interactive glass (buttons): reacts to presses on OS 26+, tinted fill below.
    @ViewBuilder func glassChromeInteractive<S: Shape>(in shape: S, fallbackTint: Color) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(fallbackTint, in: shape)
        }
    }
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

/// Visual identity for a model FAMILY — a monogram + brand-inspired gradient keyed off the catalog
/// id. Deliberately NOT the providers' official logos: those are trademarks with their own usage
/// terms (and App Review flags third-party marks), so a colored monogram carries the recognition
/// legally. `nil` / unknown ids fall back to the Quenderin "Q" brand orb.
enum ModelFamily {
    /// True when `id` names no known family — the avatar shows the app's own identity
    /// (the elf mascot) instead of a family monogram. NOT the same as monogram == "Q":
    /// Qwen's monogram is also "Q" but Qwen is a real family, never the brand fallback.
    static func isBrand(_ id: String?) -> Bool {
        guard let id else { return true }
        return !["llama", "qwen", "deepseek", "mistral", "gemma", "phi"].contains { id.hasPrefix($0) }
    }

    /// (monogram, gradient top, gradient bottom)
    static func identity(for id: String?) -> (String, Color, Color) {
        guard let id else { return ("Q", Color(hex: 0x52939A), Color(hex: 0x1C4E5D)) }   // brand teal (elf artwork)
        if id.hasPrefix("llama") { return ("L", Color(hex: 0x2E8BFF), Color(hex: 0x0353C7)) }      // Meta blue
        if id.hasPrefix("qwen") { return ("Q", Color(hex: 0x7B61FF), Color(hex: 0x3B2FC9)) }       // Qwen violet
        if id.hasPrefix("deepseek") { return ("D", Color(hex: 0x6B85FE), Color(hex: 0x2C4BDF)) }   // DeepSeek blue
        if id.hasPrefix("mistral") { return ("M", Color(hex: 0xFF8205), Color(hex: 0xE0400A)) }    // Mistral orange
        if id.hasPrefix("gemma") { return ("G", Color(hex: 0x4285F4), Color(hex: 0x9B72CB)) }      // Gemini blue→purple
        if id.hasPrefix("phi") { return ("P", Color(hex: 0x30A2FF), Color(hex: 0x005A9E)) }        // Microsoft blue
        return ("Q", Color(hex: 0x52939A), Color(hex: 0x1C4E5D))
    }
}

/// The Quenderin mascot (the elf from the app icon) as a circular avatar image, loaded once from
/// the package bundle. `nil` if the resource is missing — callers fall back to the monogram orb.
@MainActor
let brandAvatar: Image? = {
    guard let url = Bundle.module.url(forResource: "brand-avatar", withExtension: "png") else { return nil }
    #if os(macOS)
    guard let img = NSImage(contentsOf: url) else { return nil }
    return Image(nsImage: img)
    #else
    guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
    return Image(uiImage: img)
    #endif
}()

/// The model rendered as a chat "contact". Twin of Android's ModelAvatar.
/// With a `modelID`, a known family wears its monogram + brand colors; without one (or for an
/// unknown family) the app's own identity shows — the elf mascot from the official icon.
struct ModelAvatar: View {
    var size: CGFloat = 40
    var modelID: String? = nil
    var body: some View {
        let (monogram, top, bottom) = ModelFamily.identity(for: modelID)
        if ModelFamily.isBrand(modelID), let brandAvatar {
            brandAvatar
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(LinearGradient(
                    colors: [top, bottom],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: size, height: size)
                .overlay(
                    Text(monogram)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                )
        }
    }
}
#endif
