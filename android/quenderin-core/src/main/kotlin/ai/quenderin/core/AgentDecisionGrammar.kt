package ai.quenderin.core

/**
 * The GBNF grammar for the agent's decision JSON — BYTE-IDENTICAL twin of Swift
 * `AgentDecisionGrammar` (both platforms pin the same SHA-256 in their checks, so any drift
 * breaks a build instead of shipping). Matches exactly the union [AgentDecisionParser] accepts:
 * `{"tool":…,"input":…}` | `{"plan":[…]}` | `{"answer":…}`.
 *
 * Consumed by the native engine once the JNI grows a grammar parameter (the iOS engine already
 * applies it via `llama_sampler_init_grammar`); until then this constant IS the contract that
 * wiring will use — kept in core so the twins can't diverge in the meantime. Escaped regular
 * strings, not raw: several grammar lines END with a quote, which collides with raw-string
 * `\"\"\"` terminators.
 */
object AgentDecisionGrammar {
    val GBNF: String = listOf(
        "root ::= ws ( tool | plan | answer ) ws",
        "tool ::= \"{\" ws \"\\\"tool\\\"\" ws \":\" ws string ws \",\" ws \"\\\"input\\\"\" ws \":\" ws string ws \"}\"",
        "plan ::= \"{\" ws \"\\\"plan\\\"\" ws \":\" ws \"[\" ws tool ( ws \",\" ws tool )* ws \"]\" ws \"}\"",
        "answer ::= \"{\" ws \"\\\"answer\\\"\" ws \":\" ws string ws \"}\"",
        "string ::= \"\\\"\" char* \"\\\"\"",
        "char ::= [^\"\\\\\\x00-\\x1F] | \"\\\\\" escape",
        "escape ::= [\"\\\\/bfnrt] | \"u\" hex hex hex hex",
        "hex ::= [0-9a-fA-F]",
        "ws ::= [ \\t\\n\\r]*",
    ).joinToString("\n")

    /**
     * The ACTION-FIRST grammar: `tool | plan` only, no `answer`. Used on the FIRST step of an
     * ActionIntent goal so a weak model can't bail with `{"answer":"I can't…"}` on a task it has
     * the tools for — deterministic, not a nudge. All safety gates still apply; step 2+ use the
     * full grammar. Byte-identical twin of Swift `AgentDecisionGrammar.gbnfActionFirst`.
     */
    val GBNF_ACTION_FIRST: String = listOf(
        "root ::= ws ( tool | plan ) ws",
        "tool ::= \"{\" ws \"\\\"tool\\\"\" ws \":\" ws string ws \",\" ws \"\\\"input\\\"\" ws \":\" ws string ws \"}\"",
        "plan ::= \"{\" ws \"\\\"plan\\\"\" ws \":\" ws \"[\" ws tool ( ws \",\" ws tool )* ws \"]\" ws \"}\"",
        "string ::= \"\\\"\" char* \"\\\"\"",
        "char ::= [^\"\\\\\\x00-\\x1F] | \"\\\\\" escape",
        "escape ::= [\"\\\\/bfnrt] | \"u\" hex hex hex hex",
        "hex ::= [0-9a-fA-F]",
        "ws ::= [ \\t\\n\\r]*",
    ).joinToString("\n")
}
