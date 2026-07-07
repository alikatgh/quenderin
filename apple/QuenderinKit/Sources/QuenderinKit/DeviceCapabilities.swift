import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(EventKit)
import EventKit
#endif

/// T1 device PERCEPTION for the store apps — the phone agent's senses (owner sign-off
/// 2026-07-07; docs/PRODUCT.md revised in the same change: mobile moves from T0-only to
/// T0–T1). Read-only by declaration, consent-gated by the same spine as everything else,
/// and each OS permission (calendar) prompts through the system dialog on first use —
/// the Shortcuts model. NOTHING here writes; T2+ device automation stays desktop-only.

// MARK: - Clipboard (works on iOS and macOS alike)

/// The pasteboard seam — production reads UIPasteboard/NSPasteboard; tests inject a string.
public protocol PasteboardReader: Sendable {
    func readText() -> String?
}

public struct SystemPasteboard: PasteboardReader {
    public init() {}
    public func readText() -> String? {
        #if canImport(UIKit)
        return UIPasteboard.general.string
        #elseif canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }
}

/// T1: read the clipboard — "use what I just copied", the highest-signal context a device
/// holds. (iOS shows its own paste banner on access — the system's transparency, kept.)
public struct DeviceClipboardReadCapability: Capability {
    public let name = "device.clipboard.read"
    public let purpose = "Read the text currently on the clipboard. No input."
    public let tier = CapabilityTier.readOnly
    public let blastRadius = BlastRadius.read(resource: "the clipboard")
    private let pasteboard: any PasteboardReader
    private let maxChars: Int

    public init(pasteboard: any PasteboardReader = SystemPasteboard(), maxChars: Int = 4000) {
        self.pasteboard = pasteboard
        self.maxChars = maxChars
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        ActionPreview(summary: "Would read the text currently on your clipboard (read-only).", mutates: false)
    }

    public func run(_ input: String) async throws -> String {
        guard let text = pasteboard.readText(), !text.isEmpty else {
            return "The clipboard is empty (or holds no text)."
        }
        return text.count > maxChars ? String(text.prefix(maxChars)) + "\n[…clipboard truncated]" : text
    }
}

// MARK: - Calendar (EventKit — native on iOS AND macOS, permission-prompted by the OS)

/// The calendar seam: production wraps EventKit (with its system permission prompt);
/// tests inject canned events. Read-only by construction — the seam can't write.
public protocol CalendarReader: Sendable {
    /// Today's events as "(title, start-time string)" pairs, or nil when the user denied access.
    func todaysEvents() async -> [(title: String, time: String)]?
}

#if canImport(EventKit)
public struct EventKitCalendarReader: CalendarReader {
    public init() {}

    public func todaysEvents() async -> [(title: String, time: String)]? {
        let store = EKEventStore()
        let granted: Bool
        if #available(iOS 17.0, macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        guard granted else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = start.addingTimeInterval(24 * 3600 - 1)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return store.events(matching: predicate).map { event in
            (title: event.title ?? "(untitled)", time: formatter.string(from: event.startDate))
        }
    }
}
#endif

/// T1: today's calendar, natively via EventKit — the OS permission dialog is the grant,
/// on top of the capability consent toggle. (The macOS AppleScript twin `mac.calendar.today`
/// remains in the desktop lab; EventKit is the better citizen on both Apple platforms.)
public struct CalendarTodayDeviceCapability: Capability {
    public let name = "device.calendar.today"
    public let purpose = "List the titles and times of today's calendar events. No input."
    public let tier = CapabilityTier.readOnly
    public let blastRadius = BlastRadius.read(resource: "your calendar (today)")
    private let reader: any CalendarReader

    public init(reader: any CalendarReader) {
        self.reader = reader
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        ActionPreview(summary: "Would read today's calendar events (read-only).", mutates: false)
    }

    public func run(_ input: String) async throws -> String {
        guard let events = await reader.todaysEvents() else {
            return "Calendar access wasn't granted — allow it in the system Settings to use this."
        }
        if events.isEmpty { return "No events on your calendar today." }
        return events.map { "\($0.title) @ \($0.time)" }.joined(separator: "\n")
    }
}

// MARK: - Device status (battery + free storage — the "can I even do this here?" senses)

/// The status seam — production reads UIDevice/host stats; tests inject numbers.
public protocol DeviceStatusReader: Sendable {
    /// Battery level 0…1, or nil when unknown (desktops, simulators without battery).
    func batteryLevel() -> Double?
    /// Free disk bytes on the app's volume, or nil when unknown.
    func freeDiskBytes() -> Int64?
}

public struct SystemDeviceStatus: DeviceStatusReader {
    public init() {}

    public func batteryLevel() -> Double? {
        #if canImport(UIKit) && !os(tvOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Double(level) : nil
        #else
        return nil
        #endif
    }

    public func freeDiskBytes() -> Int64? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let values = try? url?.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity
    }
}

/// T1: battery + free storage in one glance — lets the agent answer "can this phone even
/// hold that model / survive this task?" honestly.
public struct DeviceStatusCapability: Capability {
    public let name = "device.status"
    public let purpose = "Report the battery level and free storage of this device. No input."
    public let tier = CapabilityTier.readOnly
    public let blastRadius = BlastRadius.read(resource: "battery and storage levels")
    private let status: any DeviceStatusReader

    public init(status: any DeviceStatusReader = SystemDeviceStatus()) {
        self.status = status
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        ActionPreview(summary: "Would read the battery level and free storage (read-only).", mutates: false)
    }

    public func run(_ input: String) async throws -> String {
        var parts: [String] = []
        if let battery = status.batteryLevel() {
            parts.append("Battery: \(Int((battery * 100).rounded()))%")
        }
        if let free = status.freeDiskBytes() {
            parts.append(String(format: "Free storage: %.1f GB", Double(free) / 1_000_000_000))
        }
        return parts.isEmpty ? "Couldn't read the device status here." : parts.joined(separator: " · ")
    }
}
