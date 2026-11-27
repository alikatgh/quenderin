import Foundation

/// Compile-time feature flags for gated capabilities.
/// Pure Foundation — twin of Kotlin `FeatureFlags`.
public enum FeatureFlags {
    /// Routes still-image attachments in the main chat composer through the local vision engine.
    ///
    /// Keep `false` until a physical-device full-weight pass is recorded in `docs/VISION_IN_CHAT.md`:
    /// - Physical iPhone (>= 8 GB) and Apple-silicon Mac with MiniCPM-V 4.7 1B (model + mmproj,
    ///   SHA-256 verified) linked against the pinned vision runtime (`QUENDERIN_VISION_LLAMA`,
    ///   revision `e8fd209c975c80aa7fb36a8423571ff3b1b7e955`).
    /// - Correct answers on 5 fixed images (photo, screenshot, receipt, chart, handwriting).
    /// - Recorded peak memory (no jetsam) and time-to-answer.
    /// - Mid-answer cancellation works, low-memory device shows the existing refusal, and app quit
    ///   during vision does not crash.
    /// - Android equivalent verified on Galaxy S23.
    public static let visionInChat = false

    /// Returns `true` only when the feature flag is enabled, the pinned native vision runtime is
    /// linked/available, and a verified vision model is installed.
    public static func visionInChatAvailable(
        flag: Bool = visionInChat,
        runtimeAvailable: Bool,
        modelInstalled: Bool
    ) -> Bool {
        flag && runtimeAvailable && modelInstalled
    }
}
