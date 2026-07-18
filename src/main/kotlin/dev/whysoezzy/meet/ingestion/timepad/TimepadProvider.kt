package dev.whysoezzy.meet.ingestion.timepad

import dev.whysoezzy.meet.config.TimepadProperties
import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.ingestion.EventProvider
import dev.whysoezzy.meet.ingestion.RawEvent
import mu.KotlinLogging
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.stereotype.Component
import org.springframework.web.client.RestClient
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import com.fasterxml.jackson.databind.JsonNode

private val logger = KotlinLogging.logger {}

@Component
@ConditionalOnProperty(prefix = "app.timepad", name = ["enabled"], havingValue = "true")
class TimepadProvider(
    private val props: TimepadProperties,
    restClientBuilder: RestClient.Builder,
) : EventProvider {

    private val restClient = restClientBuilder
        .baseUrl(props.baseUrl)
        .build()

    override fun source(): EventSource = EventSource.TIMEPAD

    override fun fetch(since: LocalDateTime?): List<RawEvent> {
        val zone = ZoneId.of(props.zone)
        val startMin = (since?.toLocalDate() ?: LocalDate.now()).format(DateTimeFormatter.ISO_LOCAL_DATE)
        val startMax = LocalDate.now().plusDays(props.daysAhead).format(DateTimeFormatter.ISO_LOCAL_DATE)

        val collected = mutableListOf<RawEvent>()
        var page = 0
        while (page < props.maxPages) {
            val skip = page * props.pageSize
            val response = restClient.get()
                .uri { b ->
                    b.path("/events.json")
                        .queryParam("limit", props.pageSize)
                        .queryParam("skip", skip)
                        .queryParam("sort", "+starts_at")
                        .queryParam("fields", "location,description_short,description_html")
                        .queryParam("starts_at_min", startMin)
                        .queryParam("starts_at_max", startMax)
                    if (props.categoryIds.isNotEmpty()) b.queryParam("category_ids", props.categoryIds.joinToString(","))
                    if (props.keywords.isNotEmpty()) b.queryParam("keywords", props.keywords.joinToString(","))
                    if (props.cities.isNotEmpty()) b.queryParam("cities", props.cities.joinToString(","))
                    b.build()
                }
                .headers { h -> if (props.token.isNotBlank()) h.setBearerAuth(props.token) }
                .retrieve()
                .body(TimepadEventsResponse::class.java) ?: break

            if (response.values.isEmpty()) break
            response.values.forEach { collected += it.toRawEvent(zone) }
            logger.info { "Timepad: страница ${page + 1}, получено ${response.values.size}/${response.total}" }

            if (skip + response.values.size >= response.total) break
            page++
        }
        logger.info { "Timepad: всего нормализовано ${collected.size} событий" }
        return collected
    }

    private fun TimepadEvent.toRawEvent(zone: ZoneId): RawEvent {
        // poster_image / location могут прийти объектом, пустым массивом [] или отсутствовать —
        // JsonNode.path() безопасен в любом случае (вернёт MissingNode, не упадёт).
        val imageUrl = posterImage?.path("default_url")?.takeIf { it.isTextual }?.asText().orEmpty()

        val loc = location
        val city = loc?.path("city")?.takeIf { it.isTextual }?.asText().orEmpty()
        val address = loc?.path("address")?.takeIf { it.isTextual }?.asText().orEmpty()

        val coords = loc?.path("coordinates")
        val lat = coords?.takeIf { it.isArray && it.size() > 0 }?.get(0)?.asText()?.toDoubleOrNull() ?: 0.0
        val lng = coords?.takeIf { it.isArray && it.size() > 1 }?.get(1)?.asText()?.toDoubleOrNull() ?: 0.0

        val hasPhysical = address.isNotBlank() ||
                (city.isNotBlank() && !city.equals("Онлайн", ignoreCase = true))
        val addr = when {
            address.isNotBlank() -> address
            city.isNotBlank() -> city
            else -> "Онлайн"
        }

        return RawEvent(
            sourceExternalId = id.toString(),
            title = name,
            description = descriptionShort?.takeIf { it.isNotBlank() } ?: descriptionHtml.orEmpty(),
            imageUrl = imageUrl,
            startsAtEpochMs = parseStartsAt(startsAt, zone),
            address = addr,
            latitude = lat,
            longitude = lng,
            externalUrl = url,
            isOnline = !hasPhysical,
            topicKeywords = extractCategoryNames(categories),
        )
    }

    private fun parseStartsAt(value: String?, zone: ZoneId): Long {
        if (value.isNullOrBlank()) return 0L
        // Timepad обычно отдаёт смещение без двоеточия: 2026-09-15T19:00:00+0300
        runCatching {
            return OffsetDateTime.parse(value, DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssZ"))
                .toInstant().toEpochMilli()
        }
        runCatching {
            return OffsetDateTime.parse(value, DateTimeFormatter.ISO_OFFSET_DATE_TIME)
                .toInstant().toEpochMilli()
        }
        runCatching {
            return LocalDateTime.parse(value, DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss"))
                .atZone(zone).toInstant().toEpochMilli()
        }
        return try {
            LocalDate.parse(value, DateTimeFormatter.ISO_LOCAL_DATE)
                .atStartOfDay(zone).toInstant().toEpochMilli()
        } catch (_: DateTimeParseException) {
            logger.warn { "Timepad: unrecognized event date format" }
            0L
        }
    }
}

private fun extractCategoryNames(node: JsonNode?): Set<String> {
    // categories бывает массивом [{name:...}] или объектом {..:{name:...}} — обходим оба
    if (node == null || (!node.isArray && !node.isObject)) return emptySet()
    return node.elements().asSequence()
        .mapNotNull { el -> el.path("name").takeIf { it.isTextual }?.asText() }
        .filter { it.isNotBlank() }
        .toSet()
}
