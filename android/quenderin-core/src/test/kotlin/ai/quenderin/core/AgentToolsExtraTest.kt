package ai.quenderin.core

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The shared ASCII/Unicode digit contract for the pure-compute agent tools, pinned with the same
 * vectors as the Swift `AgentToolsExtraTests` on Apple. A digit is one Unicode category-Nd
 * character and contributes its DECIMAL VALUE; characters that merely have a numeric value
 * (superscript ², fractions, Roman numerals) are not digits.
 *
 * Runs under the Gradle build (`./gradlew :quenderin-core:test`). The dependency-free
 * `src/verify/CoreVerify.kt` harness pins the unit `5²` case; the date-offset and Nd-value vectors
 * live here so the shared contract has one owner per suite.
 */
class AgentToolsExtraTest {

    private val units = UnitConverterTool()
    private val date = DateCalcTool()

    @Test fun superscriptIsNotPartOfTheNumber() {
        // ² is category-No, NOT Nd. It stays unit text on both platforms, so Android and iOS report
        // the same cross-dimension error instead of one of them reading "5²" as a number.
        assertEquals(
            "Can't convert ² m to ft — they measure different things.",
            units.run("5² m to ft"),
        )
    }

    @Test fun unicodeDecimalDigitsParseByValue() {
        // Arabic-Indic ٥ and fullwidth ５ are both category Nd; each reads as 5.
        assertEquals("5 km = 5000 m", units.run("\u0665 km to m"))
        assertEquals("5 km = 5000 m", units.run("\uFF15 km to m"))
    }

    @Test fun ordinaryAsciiInputIsUnchanged() {
        assertEquals("5 m = 16.4042 ft", units.run("5 m to ft"))
        assertEquals("1 km = 1000 m", units.run("1 km to m"))
        assertEquals("90 min = 1.5 h", units.run("90 min to h"))
    }

    @Test fun dateOffsetUsesTheSameDigitClassAsUnits() {
        // Regression: the iOS twin read the offset with Character.isNumber, appended the superscript
        // and then failed Int("5²"), rejecting an offset Android read as 5 days. Both read 2026-06-13.
        assertEquals("2026-06-13", date.run("2026-06-08 plus 5² days"))
        assertEquals("2026-06-13", date.run("2026-06-08 plus \u0665 days"))
    }

    @Test fun supplementaryPlaneDecimalDigitsParseByValue() {
        // U+1D7DD MATHEMATICAL DOUBLE-STRUCK DIGIT FIVE is one Nd scalar but a UTF-16 surrogate
        // pair, so a Char-by-Char scan used to drop it while Swift read 5. The code-point scan must
        // match Swift for both tools.
        assertEquals("5 km = 5000 m", units.run("\uD835\uDFDD km to m"))
        assertEquals("2026-06-13", date.run("2026-06-08 plus \uD835\uDFDD days"))
    }

    @Test fun ordinaryDateMathIsUnchanged() {
        assertEquals("2026-09-06", date.run("2026-06-08 plus 90 days"))
        assertEquals("2026-06-08", date.run("2026-06-25 minus 17 days"))
        assertEquals("2026-03-01", date.run("2026-03-01 plus 0 days"))
        assertEquals("200 days", date.run("days between 2026-06-08 and 2026-12-25"))
    }
}
