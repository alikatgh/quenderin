package ai.quenderin.app

import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.printToString

/** Only used by the network-isolated hosted journeys, whose content is synthetic. */
internal fun ComposeTestRule.awaitJourneyTag(tag: String) {
    try {
        waitUntil(15_000) { onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty() }
    } catch (timeout: ComposeTimeoutException) {
        val trees = listOf(false, true).joinToString("\n") { unmerged ->
            val tree = runCatching {
                onAllNodes(isRoot(), useUnmergedTree = unmerged).printToString(maxDepth = 12)
            }.getOrElse { "Unavailable (${it.javaClass.simpleName})" }
            val bytes = tree.toByteArray(Charsets.UTF_8)
            val bounded = if (bytes.size <= 7_500) tree
                else String(bytes, 0, 7_497, Charsets.UTF_8) + "..."
            "${if (unmerged) "Unmerged" else "Merged"} semantics:\n$bounded"
        }
        throw AssertionError("Timed out waiting for journey tag '$tag'.\n$trees", timeout)
    }
}
