#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class HyMemoryController: ObservableObject {
    @Published public var conversation = ""
    @Published public var selected: Set<UUID> = []
    @Published public private(set) var proposals: [HyMemoryProposal] = []
    @Published public private(set) var busy = false
    @Published public private(set) var installed = false
    @Published public private(set) var progress: Double?
    @Published public private(set) var status = "Choose a conversation. Nothing is saved automatically."
    @Published public private(set) var failure: String?
    private let inference: any HyMemoryInferencePort
    private let installer: HyMemoryInstaller
    private let store: HyApprovedMemoryStore
    private let budget: @Sendable () -> ImageResourceBudget
    private let suspendForSpecialist: @Sendable () async throws -> SpecialistInferenceLease
    private var job: Task<Void, Never>?
    public init(inference: any HyMemoryInferencePort, installer: HyMemoryInstaller = HyMemoryInstaller(), store: HyApprovedMemoryStore = .shared, budget: @escaping @Sendable () -> ImageResourceBudget = { .current() }, suspendForSpecialist: @escaping @Sendable () async throws -> SpecialistInferenceLease = { throw HyMemoryError.invalid("The app has not supplied exclusive specialist engine coordination.") }) {
        self.inference = inference; self.installer = installer; self.store = store; self.budget = budget
        self.suspendForSpecialist = suspendForSpecialist
    }
    public var blockReason: String? {
        inference.unavailableReason ?? (budget().availableMemoryBytes < HyMemory.minimumMemoryBytes ? "Requires at least 32 GiB of available app memory for the complete specialist." : nil)
    }
    public var runtimeUnavailableReason: String? { inference.unavailableReason }
    public func refresh() { Task { installed = await installer.isInstalled() } }
    public func cancel() { job?.cancel(); Task { await inference.cancel() } }
    private func run(_ message: String, seconds: UInt64, work: @escaping @MainActor () async throws -> Void) {
        guard job == nil else { return }; busy = true; failure = nil; status = message
        job = Task {
            let timer = Task { try await Task.sleep(nanoseconds: seconds * 1_000_000_000); self.cancel() }
            defer { timer.cancel(); busy = false; progress = nil; job = nil }
            do { try await work() }
            catch is CancellationError { status = "Operation cancelled. Your conversation and existing memories are kept." }
            catch { failure = String(error.localizedDescription.prefix(2048)); status = "Operation did not finish. You can retry." }
        }
    }
    public func install() {
        guard blockReason == nil else { failure = blockReason; return }
        run("Installing and verifying the complete pinned specialist…", seconds: 3600) { [self] in
            _ = try await installer.install(budget: budget()) { [weak self] fraction in Task { @MainActor in self?.progress = fraction } }
            installed = true; status = "Pinned specialist installed. The answer model is unchanged."
        }
    }
    public func propose() {
        guard installed, runtimeUnavailableReason == nil else { failure = runtimeUnavailableReason ?? "Install the specialist first."; return }
        let input = conversation
        run("Verifying the specialist and extracting proposals…", seconds: 60) { [self] in
            let prompt = try HyMemory.prompt(input), lease = try await suspendForSpecialist()
            let result: Result<[String], Error>
            do {
                try Task.checkCancellation(); let artifact = try await installer.verify(budget: budget())
                let stream = try await inference.generate(HyMemoryInferenceRequest(artifact: artifact, prompt: prompt))
                var output = "", bytes = 0
                for try await chunk in stream {
                    try Task.checkCancellation(); bytes += chunk.utf8.count
                    guard bytes <= 65_536 else { throw HyMemoryError.invalid("Hy-Memory exceeded its bounded proposal budget.") }; output += chunk
                }
                try Task.checkCancellation(); result = .success(try HyMemory.parse(output))
            } catch { result = .failure(error) }
            let port = inference
            do { try await Task.detached { await port.cancel(); try await lease.resume() }.value }
            catch { throw HyMemoryError.invalid("The specialist stopped, but the previous text model could not be restored. Retry text-model setup. \(String(error.localizedDescription.prefix(512)))") }
            try Task.checkCancellation(); proposals = try result.get().map { HyMemoryProposal(text: $0) }; selected = []
            status = proposals.isEmpty ? "No suitable explicit facts were proposed. Nothing was saved." : "Review each proposal. Every proposal starts unchecked."
        }
    }
    public func approve() {
        let chosen = selected
        guard !chosen.isEmpty, chosen.isSubset(of: Set(proposals.map(\.id))) else { return }
        run("Saving only the selected proposals…", seconds: 60) { [self] in
            for index in proposals.indices where chosen.contains(proposals[index].id) && !proposals[index].saved {
                try Task.checkCancellation(); try await store.save(proposals[index]); proposals[index].saved = true
            }
            selected = []; status = "Selected proposals saved to the private approved-memory bank."
        }
    }
}

public struct HyMemoryView: View {
    @ObservedObject private var controller: HyMemoryController
    public init(controller: HyMemoryController) { self.controller = controller }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hy-Memory proposals").font(.headline)
            Text("A separate local memory writer. Paste only the conversation to review, then approve individual facts before saving.").font(.callout).foregroundStyle(.secondary)
            Text("Experimental community conversion · Apache-2.0 · 18,236,702,240 bytes · 32 GiB available-memory floor. Model inference is unvalidated. Expert width 768 follows pinned conversion metadata; files are never patched.").font(.caption).foregroundStyle(.secondary)
            if let reason = controller.blockReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
            Button(controller.installed ? "Verify installed specialist" : "Install Hy-Memory specialist (18.24 GB)") { controller.install() }.disabled(controller.busy || controller.blockReason != nil)
            if let progress = controller.progress { ProgressView("Specialist installation", value: progress) }
            Text("Selected conversation").font(.subheadline)
            TextEditor(text: $controller.conversation).frame(minHeight: 120).accessibilityLabel("Selected conversation").disabled(controller.busy)
                .onChange(of: controller.conversation) { value in if value.utf8.count > 8192 { controller.conversation = String(value.prefix(8192)); } }
            Text("\(controller.conversation.utf8.count) / 8,192 UTF-8 bytes. No automatic conversation collection.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Preview memory proposals") { controller.propose() }.disabled(controller.busy || !controller.installed || controller.runtimeUnavailableReason != nil || controller.conversation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.conversation.utf8.count > 8192)
                if controller.busy { Button("Cancel") { controller.cancel() } }
            }
            ForEach(controller.proposals) { proposal in
                Toggle(isOn: Binding(get: { controller.selected.contains(proposal.id) }, set: { value in if value { controller.selected.insert(proposal.id) } else { controller.selected.remove(proposal.id) } })) {
                    VStack(alignment: .leading) { Text(proposal.text); if proposal.saved { Text("Saved").font(.caption).foregroundStyle(.secondary) } }
                }.disabled(controller.busy || proposal.saved)
            }
            if !controller.proposals.isEmpty { Button("Save \(controller.selected.count) selected memories") { controller.approve() }.disabled(controller.busy || controller.selected.isEmpty) }
            Text(controller.status).font(.callout).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
            if let failure = controller.failure { Text(failure).font(.callout).foregroundStyle(.red) }
        }.onAppear { controller.refresh() }.onDisappear { controller.cancel() }
    }
}
#endif
