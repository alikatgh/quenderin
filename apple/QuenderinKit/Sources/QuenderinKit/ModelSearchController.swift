import Foundation
import Combine

/// Drives the open Hugging Face model search for the Models page. Debounced, cancellable, and
/// superseding (a newer query's result never loses a race to a slower older one), over the
/// `ModelSearchProviding` seam so the whole state machine is unit-tested with a canned provider —
/// no live network. macOS/iOS only; off the cross-platform parity surface.
@MainActor
public final class ModelSearchController: ObservableObject {
    /// The top-level search state. `empty` is a *successful* search with no matches (distinct from
    /// `idle`, before any search, and `error`, a failed call) so the UI can say the right thing.
    public enum Phase: Equatable {
        case idle
        case searching
        case results([HFModelHit])
        case empty
        case error(String)
    }

    /// Per-repo quant loading — lazy, one call per expanded row, cached after it lands.
    public enum QuantPhase: Equatable {
        case loading
        case loaded([HFQuant])
        case error(String)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var query: String = ""
    @Published public private(set) var quants: [String: QuantPhase] = [:]

    private let provider: ModelSearchProviding
    private let debounceNanos: UInt64
    private var searchTask: Task<Void, Never>?
    private var searchToken = 0

    public init(provider: ModelSearchProviding = HuggingFaceAPI(), debounceNanos: UInt64 = 350_000_000) {
        self.provider = provider
        self.debounceNanos = debounceNanos
    }

    /// Run a search for `raw` (typically bound to the field's text). Under 2 characters resets to idle
    /// so a single keystroke never hammers the Hub. Each call cancels the previous in-flight search.
    public func search(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        query = q
        searchTask?.cancel()
        // Bump the token on EVERY reset, including this early idle exit — otherwise a provider that
        // ignores cancellation could finish an in-flight "qw" search and overwrite the .idle we set
        // when the field was cut back to "q" (its token would still match). Superseding is by token,
        // not just Task.cancel(), so every state reset must invalidate older tasks.
        searchToken += 1
        guard q.count >= 2 else { phase = .idle; return }
        let token = searchToken
        phase = .searching
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debounceNanos)   // debounce keystrokes
            if Task.isCancelled { return }
            do {
                let hits = try await self.provider.search(q)
                guard !Task.isCancelled, self.searchToken == token else { return }   // cancelled or superseded
                self.phase = hits.isEmpty ? .empty : .results(hits)
            } catch {
                if Task.isCancelled { return }
                guard self.searchToken == token else { return }
                self.phase = .error("Couldn't reach Hugging Face. Check your connection and try again.")
            }
        }
    }

    /// Load a repo's downloadable GGUF quants when its row expands. Cached; smallest (most-runnable
    /// on modest hardware) first. Idempotent — a second call while loading or after loaded is a no-op.
    public func loadQuants(for repo: String) {
        switch quants[repo] {
        case .loading, .loaded: return
        default: break
        }
        quants[repo] = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let qs = try await self.provider.quants(in: repo)
                    .filter { $0.sizeBytes > 0 }
                    .sorted { $0.sizeBytes < $1.sizeBytes }
                self.quants[repo] = .loaded(qs)
            } catch {
                self.quants[repo] = .error("Couldn't load this model's files. Try again.")
            }
        }
    }

    /// Reset to the pristine state — clears the field, results, and any loaded quants.
    public func clear() {
        searchTask?.cancel()
        searchToken += 1
        query = ""
        phase = .idle
        quants = [:]
    }
}
