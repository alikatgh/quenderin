/// Connection slots for one listener, managed by the server on its main actor.
struct LocalAPIAdmission<ID: Hashable> {
    enum Decision: Equatable {
        case admit
        case sendRejection
        case cancel
    }

    private enum Slot: Equatable {
        case preAuth
        case authorized
        case rejecting
    }

    // Limit unfinished or rejected headers to half the existing 16-slot budget so
    // stalled header reads leave room for requests that have passed the guard.
    private let preAuthLimit = 8
    private let totalLimit = 16
    private var slots: [ID: Slot] = [:]

    var preAuthCount: Int { slots.values.filter { $0 == .preAuth }.count }
    var totalCount: Int { slots.count }

    mutating func admit(_ id: ID) -> Decision {
        guard slots[id] == nil, totalCount < totalLimit else { return .cancel }
        if preAuthCount < preAuthLimit {
            slots[id] = .preAuth
            return .admit
        }
        // Allow one short rejection write at a time, within the total cap.
        guard !slots.values.contains(.rejecting) else { return .cancel }
        slots[id] = .rejecting
        return .sendRejection
    }

    mutating func promote(_ id: ID) {
        guard slots[id] == .preAuth else { return }
        slots[id] = .authorized
    }

    mutating func release(_ id: ID) {
        slots.removeValue(forKey: id)
    }
}
