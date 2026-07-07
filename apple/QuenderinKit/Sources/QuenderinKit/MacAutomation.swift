import Foundation

/// The macOS automation seam — the door to "anything possible in macOS" (the sharpened mission;
/// docs/AGENT_AUTONOMY_PLAN.md). AppleScript / Apple Events is the richest surface: it scripts
/// Mail, Calendar, Notes, Reminders, Finder, Safari — and capabilities are built on THIS seam
/// (not raw osascript calls) so they're testable with a fake and, crucially, so no capability
/// ever hands the model a "run arbitrary script" hole: each composes a BOUNDED, typed AppleScript
/// template with escaped inputs. Twin of the TypeScript `MacAutomation` seam the desktop lab
/// proved this library on — behavior is ported 1:1, template for template.
public protocol MacAutomation: Sendable {
    /// Run an AppleScript and return its stdout. Throws `MacAutomationError` on failure.
    func runAppleScript(_ script: String) async throws -> String
    /// Whether this machine can run AppleScript at all.
    var available: Bool { get }
}

public enum MacAutomationError: Error, Sendable, Equatable {
    case notMac
    case timeout
    case script(message: String)
}

/// Escape a value for safe embedding inside an AppleScript double-quoted string literal. The
/// input is LLM-produced while steered by untrusted content — it must never break out of the
/// literal. Runs of control chars (newlines/tabs) become ONE space so a value can't smuggle in
/// extra AppleScript statements; then backslash and double-quote are escaped. Twin of the TS
/// `escapeAppleScriptString` (same order, same semantics).
public func escapeAppleScriptString(_ value: String) -> String {
    var out = ""
    out.reserveCapacity(value.count)
    var inControlRun = false
    for scalar in value.unicodeScalars {
        if scalar.value <= 0x1F || scalar.value == 0x7F {
            if !inControlRun { out.append(" ") }
            inControlRun = true
            continue
        }
        inControlRun = false
        switch scalar {
        case "\\": out.append("\\\\")
        case "\"": out.append("\\\"")
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out
}

#if os(macOS)
/// The real implementation: `osascript -e <script>` via `Process` — the script is an argv
/// element, never parsed by a shell. Combined with `escapeAppleScriptString` for interpolated
/// values, that closes both injection layers (shell + AppleScript-string), exactly like the
/// desktop lab's execFile-based twin.
public final class OsascriptAutomation: MacAutomation {
    private let timeoutSeconds: Double

    public init(timeoutSeconds: Double = 20) {
        self.timeoutSeconds = timeoutSeconds
    }

    public var available: Bool { true }

    public func runAppleScript(_ script: String) async throws -> String {
        let timeout = timeoutSeconds
        return try await withCheckedThrowingContinuation { continuation in
            // Off the cooperative pool: osascript can block for seconds (permission prompts,
            // a busy target app) and must never pin a Swift-concurrency thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: MacAutomationError.script(message: error.localizedDescription))
                    return
                }

                // Watchdog: a hung osascript (e.g. an unanswered Automation prompt after the user
                // walked away) is terminated and surfaced as a timeout, not an eternal await.
                var timedOut = false
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        timedOut = true
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Read BEFORE waitUntilExit — draining the pipes first avoids the classic
                // full-pipe-buffer deadlock on large outputs.
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                if timedOut {
                    continuation.resume(throwing: MacAutomationError.timeout)
                    return
                }
                if process.terminationStatus != 0 {
                    let message = String(decoding: errData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: MacAutomationError.script(message: message.isEmpty ? "osascript exited \(process.terminationStatus)" : message))
                    return
                }
                let output = String(decoding: outData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: output)
            }
        }
    }
}
#endif
