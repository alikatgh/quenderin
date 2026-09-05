import Foundation

public extension ModelCatalog {
    /// Every model paired with whether it fits a device of `ram` GB — the data
    /// behind a Tier-2 "choose a different model" screen, which grays out the
    /// ones that can't load.
    static func optionsWithFitness(
        forTotalRAMGB ram: Double
    ) -> [(model: ModelEntry, fitness: MemoryCheckResult)] {
        models.map { model in
            (model: model, fitness: MemoryFitness.check(model: model, totalGB: ram, freeGB: ram))
        }
    }

    /// The iPhone twin: every model paired with the SAME per-app-budget fitness the recommendation
    /// screen used (`IPhoneModelSelector.fitness`), so the picker can never contradict it.
    static func optionsWithFitness(
        for device: IOSDeviceProfile
    ) -> [(model: ModelEntry, fitness: MemoryCheckResult)] {
        models.map { model in
            (model: model, fitness: IPhoneModelSelector.fitness(of: model, for: device))
        }
    }
}
