package ai.quenderin.core

import java.time.LocalDate
import java.time.temporal.ChronoUnit
import kotlin.math.abs

// Additional offline, pure-logic agent tools — the Kotlin twins of iOS
// AgentToolsExtra.swift. Every entry point tolerates LLM-generated garbage and
// returns a message rather than throwing; the planner's input is never trusted.

// --- Unit conversion ---

/** Converts between common units fully offline — length, temperature, mass, volume, speed.
 *  Parses "20 km to mi", "30 C in F", "5 kg to lb". */
class UnitConverterTool : Capability {
    override val name = "units"
    override val purpose = "Convert units, e.g. \"20 km to mi\", \"30 C to F\", \"5 kg to lb\", \"2 hours to minutes\"."
    override fun run(input: String): String {
        val req = UnitConverter.parse(input)
            ?: return "Couldn't read a conversion from \"$input\". Try \"20 km to mi\"."
        val result = UnitConverter.convert(req.value, req.from, req.to)
            ?: return "Can't convert ${req.from} to ${req.to} — they measure different things."
        return "${UnitConverter.format(req.value)} ${req.from} = ${UnitConverter.format(result)} ${req.to}"
    }
}

/** Offline unit engine: linear units convert through a per-dimension base unit; temperature
 *  is affine and handled on its own. Unknown / cross-dimension requests return null. */
object UnitConverter {
    data class Request(val value: Double, val from: String, val to: String)

    // canonical unit -> (dimension, factor to the dimension's base unit)
    private val linear: Map<String, Pair<String, Double>> = mapOf(
        "m" to ("len" to 1.0), "km" to ("len" to 1000.0), "cm" to ("len" to 0.01), "mm" to ("len" to 0.001),
        "mi" to ("len" to 1609.344), "ft" to ("len" to 0.3048), "in" to ("len" to 0.0254), "yd" to ("len" to 0.9144),
        "g" to ("mass" to 1.0), "kg" to ("mass" to 1000.0), "mg" to ("mass" to 0.001),
        "lb" to ("mass" to 453.59237), "oz" to ("mass" to 28.349523125),
        "l" to ("vol" to 1.0), "ml" to ("vol" to 0.001),
        "gal" to ("vol" to 3.785411784), "floz" to ("vol" to 0.0295735295625),
        "mps" to ("spd" to 1.0), "kph" to ("spd" to 0.277777778), "mph" to ("spd" to 0.44704),
        // time — base: second
        "s" to ("time" to 1.0), "ms" to ("time" to 0.001), "min" to ("time" to 60.0), "h" to ("time" to 3600.0),
        "day" to ("time" to 86400.0), "week" to ("time" to 604800.0),
    )

    private val alias: Map<String, String> = mapOf(
        "meter" to "m", "meters" to "m", "metre" to "m", "metres" to "m",
        "kilometer" to "km", "kilometers" to "km", "kilometre" to "km", "kilometres" to "km",
        "centimeter" to "cm", "centimeters" to "cm", "millimeter" to "mm", "millimeters" to "mm",
        "mile" to "mi", "miles" to "mi", "foot" to "ft", "feet" to "ft",
        "inch" to "in", "inches" to "in", "yard" to "yd", "yards" to "yd",
        "gram" to "g", "grams" to "g", "kilogram" to "kg", "kilograms" to "kg", "kilo" to "kg", "kilos" to "kg",
        "milligram" to "mg", "milligrams" to "mg", "pound" to "lb", "pounds" to "lb", "lbs" to "lb",
        "ounce" to "oz", "ounces" to "oz",
        "liter" to "l", "liters" to "l", "litre" to "l", "litres" to "l",
        "milliliter" to "ml", "milliliters" to "ml", "millilitre" to "ml", "millilitres" to "ml",
        "gallon" to "gal", "gallons" to "gal",
        "celsius" to "c", "centigrade" to "c", "fahrenheit" to "f", "kelvin" to "k",
        "kmh" to "kph", "km/h" to "kph", "mi/h" to "mph", "m/s" to "mps",
        "sec" to "s", "secs" to "s", "second" to "s", "seconds" to "s",
        "millisecond" to "ms", "milliseconds" to "ms", "msec" to "ms",
        "minute" to "min", "minutes" to "min", "mins" to "min",
        "hr" to "h", "hrs" to "h", "hour" to "h", "hours" to "h",
        "days" to "day", "weeks" to "week",
    )

    fun canonical(unit: String): String {
        val u = unit.lowercase().trim()
        return alias[u] ?: u
    }

    fun parse(text: String): Request? {
        val lower = text.lowercase()
        val sep = when {
            lower.contains(" to ") -> " to "
            lower.contains(" in ") -> " in "
            else -> return null
        }
        val parts = lower.split(sep)
        if (parts.size != 2) return null
        val toUnit = canonical(parts[1])
        val left = parts[0].trim()
        val numStr = StringBuilder()
        var i = 0
        while (i < left.length && (left[i].isDigit() || left[i] == '.' || left[i] == '-')) {
            numStr.append(left[i]); i++
        }
        val value = numStr.toString().toDoubleOrNull() ?: return null
        val fromUnit = canonical(left.substring(i))
        if (fromUnit.isEmpty()) return null
        return Request(value, fromUnit, toUnit)
    }

    fun convert(value: Double, from: String, to: String): Double? {
        val temps = setOf("c", "f", "k")
        if (from in temps || to in temps) {
            if (from !in temps || to !in temps) return null
            val celsius = when (from) {
                "c" -> value; "f" -> (value - 32) * 5 / 9; "k" -> value - 273.15; else -> return null
            }
            return when (to) {
                "c" -> celsius; "f" -> celsius * 9 / 5 + 32; "k" -> celsius + 273.15; else -> null
            }
        }
        val f = linear[from] ?: return null
        val t = linear[to] ?: return null
        if (f.first != t.first) return null
        return value * f.second / t.second
    }

    fun format(v: Double): String {
        if (v == Math.rint(v) && abs(v) < 1e12) return v.toLong().toString()
        return (Math.round(v * 10000) / 10000.0).toString()   // up to 4 decimal places
    }
}

// --- Date arithmetic ---

/** Offline date math: "days between 2026-06-08 and 2026-12-25" -> a day count, or
 *  "2026-06-08 plus 90 days" / "... minus 14 days" -> a new ISO date. Uses java.time
 *  LocalDate, so results are calendar-correct and deterministic. */
class DateCalcTool : Capability {
    override val name = "date"
    override val purpose = "Date math: \"days between 2026-06-08 and 2026-12-25\", \"2026-06-08 plus 90 days\", or \"what day of the week is 2026-12-25\"."
    override fun run(input: String): String =
        DateCalc.evaluate(input)
            ?: "Couldn't read a date calculation from \"$input\". Use ISO dates, e.g. 2026-06-08."
}

object DateCalc {
    private val isoRegex = Regex("""\d{4}-\d{2}-\d{2}""")

    private fun isoDates(text: String): List<LocalDate> =
        isoRegex.findAll(text).mapNotNull { runCatching { LocalDate.parse(it.value) }.getOrNull() }.toList()

    private fun firstInteger(text: String): Int? {
        val digits = StringBuilder()
        for (c in text) {
            if (c.isDigit()) digits.append(c) else if (digits.isNotEmpty()) break
        }
        return digits.toString().toIntOrNull()
    }

    fun evaluate(text: String): String? {
        val lower = text.lowercase()
        val dates = isoDates(text)

        if (dates.size >= 2 && lower.contains("between")) {
            val days = abs(ChronoUnit.DAYS.between(dates[0], dates[1]))
            return "$days day${if (days == 1L) "" else "s"}"
        }

        if (dates.size == 1) {
            // "what day of the week is <date>" → the weekday name. Specific triggers so it can't
            // collide with an offset query like "90 days after <date>". (Identical names to iOS.)
            if (lower.contains("weekday") || lower.contains("day of the week") || lower.contains("day of week")) {
                val names = arrayOf("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
                return names[dates[0].dayOfWeek.value - 1]   // DayOfWeek: MONDAY=1 … SUNDAY=7
            }
            val stripped = text.replace(isoRegex, " ")
            val n = firstInteger(stripped) ?: return null
            val isMinus = lower.contains("minus") || lower.contains("subtract") || lower.contains("before")
            val isPlus = lower.contains("plus") || lower.contains("add") || lower.contains("after")
            if (!isPlus && !isMinus) return null
            // Twin-drift fix: LocalDate.plusDays THROWS DateTimeException on year overflow (caps at year
            // ±999,999,999) and nothing upstream catches it — a huge Int day-offset (well within the parse)
            // crashed the tool, violating this file's "tolerate LLM garbage, never throw" contract. iOS's
            // Calendar.date(byAdding:) returns nil instead; runCatching → graceful null fallback here.
            return runCatching { dates[0].plusDays((if (isMinus) -n else n).toLong()).toString() }.getOrNull()
        }

        return null
    }
}
