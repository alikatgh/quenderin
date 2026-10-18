package ai.quenderin.core

/** Mandatory Jais reasoning remains private, including split/unfinished delimiters. */
class JaisOutputFilter(private val emit: (String) -> Unit) {
    private var pending = ""
    private var hidden = true
    private var stopped = false
    private val closers = listOf("</ifm|think>", "</ifm|think_faster>", "</ifm|think_fast>")
    private val openers = listOf("<ifm|think>", "<ifm|think_faster>", "<ifm|think_fast>")
    private val ends = listOf("<|ifm|im_end|>", "<|ifm|im_start|>", "<|end_of_text|>")

    fun accept(text: String) {
        if (stopped) return
        pending += text
        while (pending.isNotEmpty()) {
            val tokens = (if (hidden) closers else openers) + ends
            val found = tokens.map { it to pending.indexOf(it) }.filter { it.second >= 0 }.minByOrNull { it.second }
            if (found != null) {
                val (token, index) = found
                if (!hidden && index > 0) emit(pending.substring(0, index))
                pending = pending.substring(index + token.length)
                if (token in ends) { stopped = true; pending = ""; return }
                hidden = !hidden
            } else {
                var held = 0
                for (token in tokens) for (count in 1 until token.length) {
                    if (pending.endsWith(token.take(count))) held = maxOf(held, count)
                }
                if (!hidden && pending.length > held) emit(pending.dropLast(held))
                pending = pending.takeLast(held)
                return
            }
        }
    }
    fun finish() { pending = ""; stopped = true }
    companion object {
        fun finalText(wire: String): String {
            val output = StringBuilder()
            val filter = JaisOutputFilter { output.append(it) }
            filter.accept(wire); filter.finish()
            return output.toString().trim()
        }
    }
}
