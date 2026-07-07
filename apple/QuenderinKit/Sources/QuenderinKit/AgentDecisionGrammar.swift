import Foundation

/// The GBNF grammar for the agent's decision JSON — the decoder-level twin of the desktop's
/// `ACTION_JSON_SCHEMA` idea: instead of asking a small model to please emit valid JSON and
/// scraping what comes back (parse-nudge, retry, stall), the sampler masks every token that
/// cannot continue this grammar, so a decision **cannot** be prose. Matches exactly the union
/// `AgentDecisionParser` accepts: `{"tool":…,"input":…}` | `{"plan":[…]}` | `{"answer":…}`.
///
/// Engines that support GBNF (`LlamaEngine`) apply it when `GenerationOptions.gbnfGrammar` is
/// set; engines that don't (the mock, ported engines) ignore the field, and the loop's
/// parse-nudge fallback still covers them.
///
/// Built as joined LINES so the Kotlin twin can hold a byte-identical constant — both platforms
/// pin the same SHA-256 in their tests, so any drift breaks a build instead of shipping.
public enum AgentDecisionGrammar {
    public static let gbnf: String = [
        #"root ::= ws ( tool | plan | answer ) ws"#,
        #"tool ::= "{" ws "\"tool\"" ws ":" ws string ws "," ws "\"input\"" ws ":" ws string ws "}""#,
        #"plan ::= "{" ws "\"plan\"" ws ":" ws "[" ws tool ( ws "," ws tool )* ws "]" ws "}""#,
        #"answer ::= "{" ws "\"answer\"" ws ":" ws string ws "}""#,
        #"string ::= "\"" char* "\"""#,
        #"char ::= [^"\\\x00-\x1F] | "\\" escape"#,
        #"escape ::= ["\\/bfnrt] | "u" hex hex hex hex"#,
        #"hex ::= [0-9a-fA-F]"#,
        #"ws ::= [ \t\n\r]*"#,
    ].joined(separator: "\n")
}
