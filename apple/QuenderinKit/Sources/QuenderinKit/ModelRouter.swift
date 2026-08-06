import Foundation

/// What kind of work a prompt is asking for — the router's classification target.
/// String raw values are the cross-platform contract (see shared/router-parity-vectors.json).
public enum TaskKind: String, Sendable, Equatable {
    case coding, reasoning, multilingual, general
}

/// The router's pick: which installed model should answer, and the one-line human reason
/// the UI shows (transparency is the brand — a router that explains itself).
public struct RouteDecision: Sendable, Equatable {
    public let modelID: String
    public let task: TaskKind
    public let reason: String

    public init(modelID: String, task: TaskKind, reason: String) {
        self.modelID = modelID
        self.task = task
        self.reason = reason
    }
}

/// Picks the best INSTALLED model for a prompt: classify the task (cheap, deterministic
/// heuristics — no regex, no ML), then choose the largest model of the preferred family
/// that fits the device's memory right now.
///
/// Deliberately boring implementation: plain substring/character scans, because the SAME
/// logic is hand-ported to Kotlin (`ai.quenderin.core.ModelRouter`) and regex/Unicode-class
/// semantics are exactly where Swift and Kotlin silently diverge (8 of 11 bugs in the
/// 2026-06-26 cross-platform audit). Contract pinned by shared/router-parity-vectors.json +
/// scripts/check_router_parity.py (CI).
///
/// Routing happens at CONVERSATION boundaries and is surfaced as a SUGGESTION — never a
/// silent mid-conversation swap (that would quietly re-prefill the transcript on another
/// model; see docs/BRAND.md on honest intelligence).
public enum ModelRouter {

    // MARK: Classification

    static let codingMarkers = [
        "```", "def ", "func ", "fun ", "class ", "import ", "print(", "console.log",
        "function", "compile", "refactor", "debug", "stack trace", "exception",
        "regex", "sql", "python", "javascript", "typescript", "swift", "kotlin",
        "rust", "c++", "segfault", "null pointer", "unit test", "api endpoint", "write code",
    ]

    static let reasoningMarkers = [
        "step by step", "step-by-step", "prove ", "proof", "solve ", "puzzle",
        "logic", "deduce", "how many ", "if x", "therefore", "riddle", "chain of thought",
        "reason through", "think through", "math problem",
        "по шагам", "докажи", "реши ", "загадк", "сколько будет",
    ]

    static let translateMarkers = [
        "translate", "translation", "in spanish", "in french",
        "in german", "in japanese", "in chinese", "into english",
        // Russian-first (Cyrillic already trips multilingual via nonLatin share; these help mixed scripts).
        "переведи", "перевод", "на английский", "на русский", "на испанский",
    ]

    /// Classify a prompt. Priority when several match: coding > multilingual > reasoning >
    /// general — a Chinese coding question should still get the coding model.
    public static func classify(_ prompt: String) -> TaskKind {
        let lower = prompt.lowercased()
        if codingMarkers.contains(where: { lower.contains($0) }) { return .coding }
        if nonLatinLetterShare(prompt) > 0.3 || translateMarkers.contains(where: { lower.contains($0) }) {
            return .multilingual
        }
        if reasoningMarkers.contains(where: { lower.contains($0) }) { return .reasoning }
        return .general
    }

    /// Share of LETTERS outside basic Latin (plus Latin-1/Extended, so accented European
    /// text stays "latin"). Scans unicode scalars — same code-point semantics both platforms.
    static func nonLatinLetterShare(_ s: String) -> Double {
        var letters = 0
        var nonLatin = 0
        for scalar in s.unicodeScalars {
            guard scalar.properties.isAlphabetic else { continue }
            letters += 1
            if scalar.value > 0x24F { nonLatin += 1 }   // beyond Latin Extended-B
        }
        guard letters > 0 else { return 0 }
        return Double(nonLatin) / Double(letters)
    }

    // MARK: Family preference per task (order matters — first installed+fitting wins)

    static func preferredFamilies(for task: TaskKind) -> [String] {
        switch task {
        case .coding:       return ["qwen25-coder", "deepseek-r1", "qwen3", "llama", "mistral", "gemma4", "gemma3", "phi4"]
        case .reasoning:    return ["deepseek-r1", "qwen3", "llama", "mistral", "gemma4", "gemma3", "phi4", "qwen25-coder"]
        case .multilingual: return ["qwen3", "gemma4", "gemma3", "llama", "mistral", "deepseek-r1", "phi4", "qwen25-coder"]
        case .general:      return ["llama", "mistral", "qwen3", "gemma4", "gemma3", "phi4", "deepseek-r1", "qwen25-coder"]
        }
    }

    static func taskLabel(_ task: TaskKind, languageCode: String? = nil) -> String {
        let lang = languageCode?.lowercased()
        switch lang {
        case "ru":
            switch task {
            case .coding: return "вопрос по коду"
            case .reasoning: return "задача по шагам"
            case .multilingual: return "многоязычный запрос"
            case .general: return "общий вопрос"
            }
        case "ko":
            switch task {
            case .coding: return "코딩 질문"
            case .reasoning: return "단계별 문제"
            case .multilingual: return "다국어 프롬프트"
            case .general: return "일반 질문"
            }
        case "ja":
            switch task {
            case .coding: return "コーディングの質問"
            case .reasoning: return "段階的な問題"
            case .multilingual: return "多言語のプロンプト"
            case .general: return "一般的な質問"
            }
        case "zh":
            switch task {
            case .coding: return "编程问题"
            case .reasoning: return "分步问题"
            case .multilingual: return "多语言提示"
            case .general: return "一般问题"
            }
        default:
            switch task {
            case .coding: return "a coding question"
            case .reasoning: return "a step-by-step problem"
            case .multilingual: return "a multilingual prompt"
            case .general: return "a general question"
            }
        }
    }

    private static func reasonBestFit(task: TaskKind, label: String, languageCode: String?) -> String {
        let t = taskLabel(task, languageCode: languageCode)
        switch languageCode?.lowercased() {
        case "ru": return "\(t) — \(label) лучше всего подходит из установленных"
        case "ko": return "\(t) — 설치된 것 중 \(label)가 가장 적합합니다"
        case "ja": return "\(t) — インストール済みでは\(label)が最適です"
        case "zh": return "\(t) — 已安装中 \(label) 最合适"
        default: return "\(t) — \(label) is the best fit you have installed"
        }
    }

    private static func reasonLargest(task: TaskKind, label: String, languageCode: String?) -> String {
        let t = taskLabel(task, languageCode: languageCode)
        switch languageCode?.lowercased() {
        case "ru": return "\(t) — \(label) самая крупная из установленных"
        case "ko": return "\(t) — 설치된 것 중 \(label)가 가장 큽니다"
        case "ja": return "\(t) — インストール済みでは\(label)が最大です"
        case "zh": return "\(t) — 已安装中 \(label) 最大"
        default: return "\(t) — \(label) is the largest model you have installed"
        }
    }

    // MARK: Routing

    /// Live-device convenience: same free-RAM convention as `MemoryFitness.check(for:)`
    /// (iOS doesn't reliably expose free memory, so total is the budget).
    public static func route(prompt: String, installed: [ModelEntry], languageCode: String? = nil) -> RouteDecision? {
        let total = HardwareProbe.current().totalRAMGB
        let code = languageCode ?? Locale.current.language.languageCode?.identifier
        return route(prompt: prompt, installed: installed, totalRAMGB: total, freeRAMGB: total, languageCode: code)
    }

    /// The best installed model for this prompt on this device, or nil when nothing is
    /// installed. Within a family, prefers the LARGEST variant that can load right now.
    /// Classification is language-independent (parity-tested); [RouteDecision.reason] may localize.
    public static func route(
        prompt: String,
        installed: [ModelEntry],
        totalRAMGB: Double,
        freeRAMGB: Double,
        languageCode: String? = nil
    ) -> RouteDecision? {
        guard !installed.isEmpty else { return nil }
        let task = classify(prompt)
        let loadable = installed.filter {
            MemoryFitness.check(model: $0, totalGB: totalRAMGB, freeGB: freeRAMGB).canLoad
        }
        let pool = loadable.isEmpty ? installed : loadable

        for family in preferredFamilies(for: task) {
            let candidates = pool.filter { $0.id.hasPrefix(family) }
            if let best = candidates.max(by: { $0.paramsBillions < $1.paramsBillions }) {
                return RouteDecision(
                    modelID: best.id,
                    task: task,
                    reason: reasonBestFit(task: task, label: best.label, languageCode: languageCode)
                )
            }
        }
        // No preferred family installed at all: largest loadable anything.
        let best = pool.max(by: { $0.paramsBillions < $1.paramsBillions })!
        return RouteDecision(
            modelID: best.id,
            task: task,
            reason: reasonLargest(task: task, label: best.label, languageCode: languageCode)
        )
    }
}
