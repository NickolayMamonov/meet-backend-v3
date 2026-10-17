package dev.whysoezzy.meet.ingestion.timepad

import dev.whysoezzy.meet.ingestion.RawEvent
import tools.jackson.databind.JsonNode
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.time.format.ResolverStyle

internal enum class MappingRejection {
    MISSING_START, MALFORMED_START, MALFORMED_END, END_BEFORE_START,
}

internal class EventMappingRejection(val reason: MappingRejection) : RuntimeException()

/** Shared normalization only; first-catalog eligibility belongs to the offline preview. */
internal object TimepadEventMapper {
    private val compactOffset = DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ssZ")
        .withResolverStyle(ResolverStyle.STRICT)

    fun isOnlineMarker(value: String): Boolean =
        value.trim().equals("Онлайн", ignoreCase = true) || value.trim().equals("Online", ignoreCase = true)

    fun map(event: TimepadEvent, zone: ZoneId): RawEvent = with(event) {
        if (startsAt.isNullOrBlank()) throw EventMappingRejection(MappingRejection.MISSING_START)
        val start = parseTimestamp(startsAt, zone)
            ?: throw EventMappingRejection(MappingRejection.MALFORMED_START)
        val end = endsAt?.takeIf { it.isNotBlank() }?.let {
            parseTimestamp(it, zone) ?: throw EventMappingRejection(MappingRejection.MALFORMED_END)
        }
        if (end != null && end < start) throw EventMappingRejection(MappingRejection.END_BEFORE_START)

        val city = location?.path("city")?.takeIf { it.isString }?.stringValue().orEmpty()
        val address = location?.path("address")?.takeIf { it.isString }?.stringValue().orEmpty()
        val coords = location?.path("coordinates")
        fun coordinate(index: Int): Double =
            coords?.takeIf { it.isArray && it.size() > index }?.get(index)?.asString()?.toDoubleOrNull() ?: 0.0
        val hasPhysical = address.isNotBlank() || (city.isNotBlank() && !isOnlineMarker(city))
        val isOnline = isOnlineMarker(address) || !hasPhysical
        RawEvent(
            sourceExternalId = id.toString(),
            title = name,
            description = descriptionShort?.takeIf { it.isNotBlank() } ?: descriptionHtml.orEmpty(),
            imageUrl = posterImage?.path("default_url")?.takeIf { it.isString }?.stringValue().orEmpty(),
            startsAtEpochMs = start,
            endsAtEpochMs = end,
            address = if (isOnline) "Онлайн" else address.takeIf { it.isNotBlank() } ?: city,
            latitude = if (isOnline) 0.0 else coordinate(0),
            longitude = if (isOnline) 0.0 else coordinate(1),
            externalUrl = url,
            isOnline = isOnline,
            topicKeywords = categoryNames(categories),
        )
    }

    private fun parseTimestamp(value: String, zone: ZoneId): Long? {
        for (format in listOf(compactOffset, DateTimeFormatter.ISO_OFFSET_DATE_TIME)) {
            try {
                return epochMillis(OffsetDateTime.parse(value, format).toInstant())
            } catch (_: DateTimeParseException) {
                // Try the next explicitly supported source format.
            }
        }
        try {
            return epochMillis(LocalDateTime.parse(value, DateTimeFormatter.ISO_LOCAL_DATE_TIME)
                .atZone(zone).toInstant())
        } catch (_: DateTimeParseException) {
            // Date-only source values are midnight in the configured source zone.
        }
        return try {
            epochMillis(LocalDate.parse(value, DateTimeFormatter.ISO_LOCAL_DATE).atStartOfDay(zone).toInstant())
        } catch (_: DateTimeParseException) {
            null
        }
    }

    private fun epochMillis(instant: Instant): Long? = try {
        instant.toEpochMilli()
    } catch (_: ArithmeticException) {
        null
    }

    private fun categoryNames(node: JsonNode?): Set<String> {
        if (node == null || (!node.isArray && !node.isObject)) return emptySet()
        return node.values().asSequence()
            .mapNotNull { it.path("name").takeIf { name -> name.isString }?.stringValue() }
            .filter { it.isNotBlank() }.toSet()
    }
}
