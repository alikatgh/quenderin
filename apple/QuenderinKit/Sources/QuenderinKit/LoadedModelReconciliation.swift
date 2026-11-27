import Foundation

/// Outcome of reconciling onboarding UI state when a manual model switch cannot acquire the
/// exclusive engine lease (e.g. lease wait timed out or was cancelled while an external owner
/// such as the Local API held the engine).
/// Pure Foundation + deterministic -> unit-testable on Linux.
public enum LoadedModelRecoveryDecision: Sendable, Equatable {
    /// Publish `.ready` for the model that is actually loaded in the engine.
    /// `rememberActiveID` is `true` when the engine's actual loaded model differs from the
    /// pre-switch UI snapshot so relaunch persistence tracks the real loaded model.
    case publishReady(modelID: String, rememberActiveID: Bool)
    /// No model is loaded and the manual switch was cancelled; return to model selection.
    case returnToChoice
    /// No resolvable model is loaded and the manual switch failed (e.g. timed out).
    case fail
}

public enum LoadedModelReconciliation {
    /// Decides which UI phase to publish after manual model-switch lease acquisition fails.
    ///
    /// Always trusts the engine's actual loaded model ID over a stale pre-install `.ready(A)`
    /// snapshot so an external switch (for example, Local API loading B while `isInstalling`
    /// suppressed live UI synchronization) never leaves the UI displaying A while B is loaded.
    public static func decideOnLeaseFailure(
        actualLoadedID: String?,
        previousReadyModelID: String?,
        wasCancelled: Bool,
        canResolve: (String) -> Bool
    ) -> LoadedModelRecoveryDecision {
        if let actualLoadedID, !actualLoadedID.isEmpty, canResolve(actualLoadedID) {
            return .publishReady(
                modelID: actualLoadedID,
                rememberActiveID: actualLoadedID != previousReadyModelID
            )
        }
        if wasCancelled {
            return .returnToChoice
        }
        return .fail
    }
}
