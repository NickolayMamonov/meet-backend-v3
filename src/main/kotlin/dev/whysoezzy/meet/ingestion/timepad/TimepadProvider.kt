package dev.whysoezzy.meet.ingestion.timepad

import dev.whysoezzy.meet.config.TimepadProperties
import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.ingestion.EventProvider
import dev.whysoezzy.meet.ingestion.FetchContext
import dev.whysoezzy.meet.ingestion.ProviderFetchResult
import dev.whysoezzy.meet.ingestion.RawEvent
import mu.KotlinLogging
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.stereotype.Component
import java.time.LocalDate
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

private val logger = KotlinLogging.logger {}

@Component
@ConditionalOnProperty(prefix = "app.timepad", name = ["enabled"], havingValue = "true")
class TimepadProvider(
    private val props: TimepadProperties,
    private val httpClient: TimepadHttpClient,
) : EventProvider {

    override fun source(): EventSource = EventSource.TIMEPAD

    override fun fetch(context: FetchContext): ProviderFetchResult {
        val zone = ZoneId.of(props.zone)
        val observedAt = context.observedAt.toEpochMilli()
        val startMin = LocalDate.now(zone).format(DateTimeFormatter.ISO_LOCAL_DATE)
        val startMax = LocalDate.now(zone).plusDays(180).format(DateTimeFormatter.ISO_LOCAL_DATE)
        if (context.savedExternalIds.size > 500) return ProviderFetchResult.Incomplete("saved_id_budget")
        return try {
            val discovery = linkedMapOf<String, TimepadEvent>()
            val conflictingNewIds = mutableSetOf<String>()
            var page = 0
            var expectedTotal: Int? = null
            while (true) {
                if (page >= props.maxPages) return ProviderFetchResult.Incomplete("discovery_page_budget")
                val response = requestEvents(page * 100, startMin, startMax)
                val total = response.total ?: return ProviderFetchResult.Incomplete("missing_total")
                val values = response.values ?: return ProviderFetchResult.Incomplete("missing_values")
                if (total < 0 || total > 500 || values.size > 100) {
                    return ProviderFetchResult.Incomplete("discovery_budget")
                }
                if (values.any { (it.categories?.size() ?: 0) > 64 }) {
                    return ProviderFetchResult.Incomplete("category_budget")
                }
                if (values.any { (it.categories?.size() ?: 0) > 64 }) {
                    return ProviderFetchResult.Incomplete("category_budget")
                }
                if (expectedTotal != null && expectedTotal != total) {
                    return ProviderFetchResult.Incomplete("changing_total")
                }
                expectedTotal = total
                values.forEach { event ->
                    if (event.id <= 0) return ProviderFetchResult.Incomplete("invalid_id")
                    val id = event.id.toString()
                    if (id in conflictingNewIds) return@forEach
                    val previous = discovery.putIfAbsent(id, event)
                    if (previous != null && previous != event) {
                        if (id in context.savedExternalIds) {
                            return ProviderFetchResult.Incomplete("saved_id_conflict")
                        }
                        discovery.remove(id)
                        conflictingNewIds += id
                    }
                }
                page++
                if (page * 100 >= total) break
                if (values.size != 100) return ProviderFetchResult.Incomplete("short_page")
            }

            val refreshed = linkedMapOf<String, TimepadEvent>()
            context.savedExternalIds.chunked(100).forEach { ids ->
                val response = requestSaved(ids)
                val values = response.values ?: return ProviderFetchResult.Incomplete("missing_saved_values")
                if (response.total != ids.size || values.size != ids.size || values.size > 100) {
                    return ProviderFetchResult.Incomplete("missing_saved_id")
                }
                if (values.any { (it.categories?.size() ?: 0) > 64 }) {
                    return ProviderFetchResult.Incomplete("category_budget")
                }
                if (values.any { (it.categories?.size() ?: 0) > 64 }) {
                    return ProviderFetchResult.Incomplete("category_budget")
                }
                values.forEach { event ->
                    val id = event.id.toString()
                    if (id !in ids || refreshed.putIfAbsent(id, event) != null) {
                        return ProviderFetchResult.Incomplete("saved_id_conflict")
                    }
                }
            }
            if (!refreshed.keys.containsAll(context.savedExternalIds)) {
                return ProviderFetchResult.Incomplete("missing_saved_id")
            }
            refreshed.forEach { (id, event) ->
                val discovered = discovery[id]
                if (discovered != null && discovered != event) {
                    return ProviderFetchResult.Incomplete("changing_saved_observation")
                }
                discovery[id] = event
            }
            if (discovery.size + conflictingNewIds.size > 1000) {
                return ProviderFetchResult.Incomplete("observation_budget")
            }

            val accepted = mutableListOf<RawEvent>()
            val rejectedSaved = mutableSetOf<String>()
            discovery.forEach { (id, event) ->
                try {
                    accepted += event.toRawEvent(zone, observedAt, id in context.savedExternalIds)
                } catch (rejection: EventMappingRejection) {
                    if (id in context.savedExternalIds) rejectedSaved += id
                }
            }
            logger.info { "Timepad snapshot complete observed=${discovery.size} accepted=${accepted.size}" }
            ProviderFetchResult.Complete(accepted.toList(), rejectedSaved.toSet(), discovery.size + conflictingNewIds.size)
        } catch (_: Exception) {
            logger.warn { "Timepad snapshot incomplete reason=provider_failure" }
            ProviderFetchResult.Incomplete("provider_failure")
        }
    }

    private fun requestEvents(skip: Int, startMin: String, startMax: String): TimepadEventsResponse =
        httpClient.fetch(endpoint(
            "limit" to "100",
            "skip" to skip.toString(),
            "sort" to "+starts_at",
            "fields" to "location,categories,ends_at,access_status,registration_data,locale",
            "starts_at_min" to startMin,
            "starts_at_max" to startMax,
        ))

    private fun requestSaved(ids: List<String>): TimepadEventsResponse =
        httpClient.fetch(endpoint(
            "limit" to ids.size.toString(),
            "event_ids" to ids.joinToString(","),
            "fields" to "location,categories,ends_at,access_status,registration_data,locale",
        ))

    private fun endpoint(vararg query: Pair<String, String>): URI {
        val base = URI(props.baseUrl)
        val path = base.toString().trimEnd('/') + "/events.json"
        val encoded = query.joinToString("&") { (key, value) ->
            "${encode(key)}=${encode(value)}"
        }
        return URI.create("$path?$encoded")
    }

    private fun encode(value: String): String =
        URLEncoder.encode(value, StandardCharsets.UTF_8).replace("+", "%20")

    private fun TimepadEvent.toRawEvent(zone: ZoneId, observedAt: Long, saved: Boolean): RawEvent {
        if (id <= 0) throw EventMappingRejection("invalid_id")
        val title = TimepadPolicy.title(name) ?: throw EventMappingRejection("invalid_title")
        if (!TimepadPolicy.isRussianLocale(locale)) throw EventMappingRejection("locale")
        if (!TimepadPolicy.isPublic(accessStatus)) throw EventMappingRejection("not_public")
        if (!TimepadPolicy.registrationOpen(registrationData)) throw EventMappingRejection("registration_closed")
        val categoryNames = TimepadPolicy.categoryNames(categories)
        val groups = TimepadPolicy.groups(title, categoryNames) ?: throw EventMappingRejection("topic")
        val loc = location
        val city = loc?.path("city")?.takeIf { it.isString }?.stringValue().orEmpty()
        val address = loc?.path("address")?.takeIf { it.isString }?.stringValue().orEmpty()
        val coords = loc?.path("coordinates")
        val coordinates = if (coords?.isArray == true && coords.size() >= 2) {
            (0..1).map { index ->
                val coordinate = coords[index]
                when {
                    coordinate.isNumber -> coordinate.doubleValue()
                    coordinate.isString -> coordinate.stringValue().toDoubleOrNull()
                    else -> null
                }
            }
        } else listOf(null, null)
        val validCoordinates = coordinates[0]?.let { it in -90.0..90.0 } == true &&
            coordinates[1]?.let { it in -180.0..180.0 } == true
        val lat = if (validCoordinates) coordinates[0]!! else 0.0
        val lng = if (validCoordinates) coordinates[1]!! else 0.0

        val startsAtEpochMs = TimepadPolicy.parseTimestamp(startsAt, zone)
            ?: throw EventMappingRejection("malformed_start")
        val endsAtEpochMs = if (endsAt.isNullOrBlank()) {
            null
        } else {
            TimepadPolicy.parseTimestamp(endsAt, zone) ?: throw EventMappingRejection("malformed_end")
        }
        if (endsAtEpochMs != null && endsAtEpochMs < startsAtEpochMs) {
            throw EventMappingRejection("end_before_start")
        }
        val physicalAddress = TimepadPolicy.physicalMoscowAddress(city, address)
            ?: throw EventMappingRejection("location")
        if (!TimepadPolicy.eventStartAllowed(startsAtEpochMs, observedAt, saved, endsAtEpochMs)) {
            throw EventMappingRejection("start_window")
        }
        val registrationUrl = TimepadPolicy.validRegistrationUrl(url, id)
            ?: throw EventMappingRejection("registration_url")
        val publicAssetBase = props.assetBaseUrl.trimEnd('/')
        if (publicAssetBase.isBlank()) throw EventMappingRejection("assets_unconfigured")

        return RawEvent(
            sourceExternalId = id.toString(),
            title = title,
            description = TimepadPolicy.description(groups, startsAtEpochMs, physicalAddress),
            imageUrl = "$publicAssetBase/timepad-assets/v1/${groups.first().asset}.png",
            startsAtEpochMs = startsAtEpochMs,
            endsAtEpochMs = endsAtEpochMs,
            address = physicalAddress,
            latitude = lat,
            longitude = lng,
            externalUrl = registrationUrl,
            isOnline = false,
            topicKeywords = categoryNames.toSet(),
            timepadGroups = groups.map { it.displayName },
        )
    }
}

private class EventMappingRejection(val reason: String) : RuntimeException()
