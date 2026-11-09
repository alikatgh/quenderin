import Foundation

/// Explicit model selection, adapted from Turnstone 1.9.
///
/// A named model stays named. Missing, unreadable, incompatible, and
/// memory-blocked selections wait with a reason instead of being replaced.
/// No explicit id still means the first-run recommender may choose.
/// This type does not touch the disk or run a model. `experimentalSource` is
/// source integration, not tested inference and not store availability.
public enum ModelAvailability: String, Sendable, Equatable {
    case present, missing, unreadable, incompatible, blocked
}

public enum ModelEvidence: String, Sendable, Equatable {
    case ordinary
    case experimentalSource
}

public enum ModelHoldDecision: Sendable, Equatable {
    case recommend
    case use(modelId: String, evidence: ModelEvidence, notice: String)
    case wait(modelId: String, availability: ModelAvailability, message: String)
}

public enum ModelSelectionHold {
    public static let experimentalSourceNotice =
        "Experimental engine support. This selection is source integration, not tested inference, and it is not a store release."

    public static func message(modelId: String, availability: ModelAvailability) -> String {
        let why: String
        switch availability {
        case .missing: why = "is not on this device"
        case .unreadable: why = "cannot be read"
        case .incompatible: why = "does not run in this build"
        case .blocked: why = "does not fit the current memory gate"
        case .present: why = "is ready"
        }
        return "\"\(modelId)\" \(why). This choice stays selected and was not replaced. Choose another model to continue."
    }

    public static func decide(explicitModelId: String?, availability: ModelAvailability, evidence: ModelEvidence) -> ModelHoldDecision {
        let modelId = explicitModelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if modelId.isEmpty { return .recommend }
        if availability == .present {
            let notice = evidence == .experimentalSource ? experimentalSourceNotice : ""
            return .use(modelId: modelId, evidence: evidence, notice: notice)
        }
        let detail = message(modelId: modelId, availability: availability)
        let full = evidence == .experimentalSource ? detail + " " + experimentalSourceNotice : detail
        return .wait(modelId: modelId, availability: availability, message: full)
    }
}
