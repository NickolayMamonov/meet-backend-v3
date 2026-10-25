package dev.whysoezzy.meet.ingestion

import tools.jackson.databind.JsonNode
import java.text.Normalizer
import java.math.BigDecimal
import java.util.Locale

internal object TimepadVenueMatcher {
    data class Venue(val road: String, val house: String, val structure: String?)
    data class Candidate(
        val coordinates: Coordinates?,
        val venue: Venue?,
        val eligibleMetadata: Boolean,
        val numericPoint: Pair<BigDecimal, BigDecimal>?,
    )

    fun parseInput(address: String): Venue? {
        var text = normalize(address, 2048) ?: return null
        text = text.replaceFirst(Regex("^россия, *"), "")
            .replaceFirst(Regex("^(?:москва|г\\. москва|город москва), *"), "")
        val splits = text.indices.mapNotNull { index ->
            if (index == 0 || text[index] == ' ' ||
                (text[index - 1] != ' ' && text[index - 1] != ',')
            ) return@mapNotNull null
            val house = parseHouse(text.substring(index)) ?: return@mapNotNull null
            // Consume exactly the road/house delimiter, never arbitrary punctuation.
            val roadText = text.substring(0, index).trimEnd().removeSuffix(",").trimEnd()
            val road = parseRoad(roadText, requireType = false) ?: return@mapNotNull null
            Venue(road, house.first, house.second)
        }
        return splits.singleOrNull()
    }

    fun parseCandidate(node: JsonNode): Candidate {
        val address = node.path("address")
        val quality = node.path("matchquality")
        val road = parseRoad(text(address.path("road")) ?: "", requireType = true)
        val house = parseHouse(text(address.path("house_number")) ?: "")
        val venue = if (road != null && house != null) Venue(road, house.first, house.second) else null
        val latitude = decimal(node.path("lat"))
        val longitude = decimal(node.path("lon"))
        val point = if (latitude != null && longitude != null &&
            latitude >= BigDecimal("-90") && latitude <= BigDecimal("90") &&
            longitude >= BigDecimal("-180") && longitude <= BigDecimal("180") &&
            TimepadCoordinateEnrichment.valid(latitude.toDouble(), longitude.toDouble())
        ) Coordinates(latitude.toDouble(), longitude.toDouble()) else null
        val metadata = text(address.path("country_code")) == "ru" &&
            normalize(text(address.path("city")), 128) == "москва" &&
            text(quality.path("matchcode")) == "exact" &&
            text(quality.path("matchtype")) == "point" &&
            text(quality.path("matchlevel")) in setOf("building", "venue")
        val numericPoint = if (point != null) latitude!! to longitude!! else null
        return Candidate(point, venue, metadata, numericPoint)
    }

    fun select(expected: Venue, candidates: List<Candidate>): Coordinates? {
        if (candidates.isEmpty() || candidates.size > 2) return null
        if (candidates.any {
                !it.eligibleMetadata || it.venue != expected || it.coordinates == null || it.numericPoint == null
            }
        ) return null
        val first = candidates.first().coordinates!!
        val numeric = candidates.first().numericPoint!!
        return first.takeIf {
            candidates.all { candidate ->
                candidate.numericPoint!!.first.compareTo(numeric.first) == 0 &&
                    candidate.numericPoint.second.compareTo(numeric.second) == 0
            }
        }
    }

    private fun parseRoad(value: String, requireType: Boolean): String? {
        val tokens = normalize(value, if (requireType) 128 else 2048)?.split(' ') ?: return null
        if (tokens.any { it == "дом" || it == "д." || it in unsupportedTypes ||
                (it.endsWith("улица") && it != "улица")
            }
        ) return null
        val types = tokens.withIndex().filter { it.value == "улица" || it.value == "ул." }
        if (types.size > 1 || (requireType && types.size != 1)) return null
        val type = types.singleOrNull()
        if (type != null && type.index != 0 && type.index != tokens.lastIndex) return null
        val stem = tokens.filterIndexed { index, _ -> index != type?.index }.joinToString(" ")
        return stem.takeIf { stemGrammar.matches(it) }
    }

    private fun parseHouse(value: String): Pair<String, String?>? {
        val text = normalize(value, 128) ?: return null
        val match = houseGrammar.matchEntire(text) ?: return null
        return match.groupValues[1] to (match.groups[2]?.value ?: match.groups[3]?.value)
    }

    private fun normalize(value: String?, maximum: Int): String? {
        if (value == null || value.codePointCount(0, value.length) > maximum ||
            value.codePoints().anyMatch {
                Character.getType(it) in setOf(
                    Character.CONTROL.toInt(), Character.FORMAT.toInt(), Character.SURROGATE.toInt(),
                )
            }
        ) return null
        return Normalizer.normalize(value, Normalizer.Form.NFC).lowercase(Locale.ROOT)
            .replace(whitespace, " ").trim().takeIf { it.isNotEmpty() }
    }

    private fun text(node: JsonNode): String? = if (node.isString) node.asString() else null
    private fun decimal(node: JsonNode): BigDecimal? =
        if (node.isString || node.isNumber) node.asString().toBigDecimalOrNull() else null

    private val whitespace = Regex("[\\p{Z}\\s]+")
    private val stemGrammar = Regex("[\\p{L}\\p{M}]+(?:[- ][\\p{L}\\p{M}]+)*")
    private val houseGrammar = Regex(
        "^(?:дом +|д\\. *)?([1-9][0-9]{0,5})(?:(?:, *| +)(?:стр\\.?|строение) +([1-9][0-9]{0,5})| *с *([1-9][0-9]{0,5}))?$",
    )
    private val unsupportedTypes = setOf(
        "ул", "переулок", "пер.", "проезд", "пр.", "проспект", "пр-т", "шоссе",
        "бульвар", "бул.", "набережная", "наб.", "площадь", "пл.", "аллея", "тупик", "тракт",
    )
}
