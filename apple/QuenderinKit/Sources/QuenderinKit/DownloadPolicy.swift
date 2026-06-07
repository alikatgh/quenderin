import Foundation

public enum NetworkStatus: Sendable, Equatable {
    case wifi
    case cellular
    case none
}

/// Whether a large model download may proceed on the current connection.
/// A multi-GB pull on cellular can cost real money and stall — default to
/// Wi-Fi-only, and never start with no connection.
public enum DownloadPolicy: Sendable, Equatable {
    case wifiOnly
    case wifiOrCellular

    public func allows(_ status: NetworkStatus) -> Bool {
        switch (self, status) {
        case (_, .none): return false
        case (.wifiOnly, .cellular): return false
        default: return true
        }
    }

    /// Why a download is being held back, in the user's words — or nil if allowed.
    public func reason(for status: NetworkStatus) -> String? {
        guard !allows(status) else { return nil }
        switch status {
        case .none:
            return "No internet connection. Connect to Wi-Fi to download your model before going offline."
        case .cellular:
            return "You're on cellular. This model is large — connect to Wi-Fi, or allow cellular downloads in settings."
        case .wifi:
            return nil
        }
    }
}

#if canImport(Network)
import Network

/// Live network status via `NWPathMonitor`. Device-coupled (real connectivity),
/// so it isn't unit-tested; `DownloadPolicy` is the tested decision layer.
public final class LiveNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.quenderin.network")
    private let lock = NSLock()
    private var _status: NetworkStatus = .none

    public var status: NetworkStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let status: NetworkStatus
            if path.status == .satisfied {
                status = path.usesInterfaceType(.cellular) ? .cellular : .wifi
            } else {
                status = .none
            }
            self?.lock.lock(); self?._status = status; self?.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
#endif
