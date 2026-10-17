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
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

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
                        .queryParam("fields", "location,description_short,description_html,ends_at")
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
            response.values.forEach { event ->
                try {
                    collected += TimepadEventMapper.map(event, zone)
                } catch (rejection: EventMappingRejection) {
                    logger.warn {
                        "Timepad: skipped event source=${source()} externalId=${event.id} reason=${rejection.reason.name.lowercase(Locale.ROOT)}"
                    }
                }
            }
            logger.info { "Timepad: страница ${page + 1}, получено ${response.values.size}/${response.total}" }

            if (skip + response.values.size >= response.total) break
            page++
        }
        logger.info { "Timepad: всего нормализовано ${collected.size} событий" }
        return collected
    }
}
