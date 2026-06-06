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
}
