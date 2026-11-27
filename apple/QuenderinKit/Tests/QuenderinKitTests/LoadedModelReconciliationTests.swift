import XCTest
@testable import QuenderinKit

final class LoadedModelReconciliationTests: XCTestCase {
    func testExternalSwitchDuringTimedOutManualSwitchPublishesActualModelAndRemembersIt() {
        let known: Set<String> = ["model-a", "model-b"]
        let decision = LoadedModelReconciliation.decideOnLeaseFailure(
            actualLoadedID: "model-b",
            previousReadyModelID: "model-a",
            wasCancelled: false,
            canResolve: { known.contains($0) }
        )
        XCTAssertEqual(decision, .publishReady(modelID: "model-b", rememberActiveID: true))
    }

    func testUnchangedLoadedModelOnTimeoutPreservesReadyWithoutRewritingActiveID() {
        let known: Set<String> = ["model-a"]
        let decision = LoadedModelReconciliation.decideOnLeaseFailure(
            actualLoadedID: "model-a",
            previousReadyModelID: "model-a",
            wasCancelled: false,
            canResolve: { known.contains($0) }
        )
        XCTAssertEqual(decision, .publishReady(modelID: "model-a", rememberActiveID: false))
    }

    func testUnloadedEngineNeverRepublishesStaleReadyModel() {
        let decisionTimeout = LoadedModelReconciliation.decideOnLeaseFailure(
            actualLoadedID: nil,
            previousReadyModelID: "model-a",
            wasCancelled: false,
            canResolve: { $0 == "model-a" }
        )
        XCTAssertEqual(decisionTimeout, .fail)

        let decisionCancelled = LoadedModelReconciliation.decideOnLeaseFailure(
            actualLoadedID: nil,
            previousReadyModelID: "model-a",
            wasCancelled: true,
            canResolve: { $0 == "model-a" }
        )
        XCTAssertEqual(decisionCancelled, .returnToChoice)
    }

    func testUnresolvableLoadedIDOrExternalLoadFromRecommendedHandledCleanly() {
        let unresolvable = LoadedModelReconciliation.decideOnLeaseFailure(
            actualLoadedID: "unknown-model",
            previousReadyModelID: "model-a",
            wasCancelled: false,
            canResolve: { $0 == "model-a" }
        )
        XCTAssertEqual(unresolvable, .fail)

        let fromRecommended = LoadedModelReconciliation.decideOnLeaseFailure(
            actualLoadedID: "model-b",
            previousReadyModelID: nil,
            wasCancelled: false,
            canResolve: { $0 == "model-b" }
        )
        XCTAssertEqual(fromRecommended, .publishReady(modelID: "model-b", rememberActiveID: true))
    }
}
