import Foundation

/// These domain values can hold private conversations and provider reasoning.
/// Their explicit Codable representation is for protected local persistence;
/// ordinary descriptions, debug logging and reflected dumps are not exports.
protocol NativeConnectionPrivateValue: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {}

extension NativeConnectionPrivateValue {
    public var description: String { String(describing: Self.self) + "(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}
