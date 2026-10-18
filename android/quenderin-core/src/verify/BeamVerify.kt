package ai.quenderin.core

/** Host-only: the exact shipped parser/catalog/memory policy, no native library or weights. */
fun main() {
    val beam = ModelCatalog.entry("beam-1.0-501b-a23b-ud-iq2-xxs")!!
    ModelArtifacts.validate(beam)
    check(beam.artifacts.size == 4)
    check(beam.downloadBytes == 133885310500L && ModelRuntimeSupport.isVerifiedBeamManifest(beam))
    check(!ModelRuntimeSupport.isVerifiedBeamManifest(beam.copy(artifacts = beam.artifacts.take(1))))
    check(!ModelRuntimeSupport.supports(beam)) // no compiled capability on this host
    check(!MemoryFitness.check(beam, 159.0, 159.0, prismRuntimeAvailable = true, beamRuntimeAvailable = true).canLoad)
    check(MemoryFitness.check(beam, 256.0, 256.0, prismRuntimeAvailable = true, beamRuntimeAvailable = true).canLoad)
    check(!MemoryFitness.check(beam, 512.0, 512.0, prismRuntimeAvailable = true, beamRuntimeAvailable = false).canLoad)
    val wire = "<|channel|>analysis<|message|>private<|end|><|start|>assistant<|channel|>final<|message|>Hello 🌲<|return|>leak"
    for (split in 0..wire.length) {
        val out = StringBuilder(); val filter = BeamOutputFilter { out.append(it) }
        filter.accept(wire.substring(0, split)); filter.accept(wire.substring(split)); filter.finish()
        check(out.toString() == "Hello 🌲")
    }
    check(BeamOutputFilter.finalText("<|channel|>final to=tool<|message|>leak").isEmpty())
    check(BeamOutputFilter.finalText("x".repeat(2048)).isEmpty())
    val eosWire = "{\"memories\":[\"a < b\"]}<eos:6124c78e>hidden"
    for (split in 0..eosWire.length) {
        val output = StringBuilder(); val stop = HyMemoryStopFilter { output.append(it) }
        stop.accept(eosWire.substring(0, split)); stop.accept(eosWire.substring(split)); stop.finish()
        check(output.toString() == "{\"memories\":[\"a < b\"]}")
    }
    check(HyMemoryNativeInferencePort("", { Long.MAX_VALUE }).unavailableReason != null)
    println("PASS: Beam complete catalog, capability/memory gates and final-only split streaming")
}
