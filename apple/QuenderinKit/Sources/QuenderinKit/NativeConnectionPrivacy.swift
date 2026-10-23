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

extension NativeConnectionProfile: NativeConnectionPrivateValue {}
extension NativeConversationBinding: NativeConnectionPrivateValue {}
extension ProviderSelection: NativeConnectionPrivateValue {}
extension ProviderDocument: NativeConnectionPrivateValue {}
extension ProviderToolCall: NativeConnectionPrivateValue {}
extension ProviderMessage: NativeConnectionPrivateValue {}
extension NativeConversationEnvelope: NativeConnectionPrivateValue {}
extension PendingRemoteCommand: NativeConnectionPrivateValue {}
extension RemoteEventIdentity: NativeConnectionPrivateValue {}
extension RemoteApproval: NativeConnectionPrivateValue {}
extension RemoteSessionState: NativeConnectionPrivateValue {}
