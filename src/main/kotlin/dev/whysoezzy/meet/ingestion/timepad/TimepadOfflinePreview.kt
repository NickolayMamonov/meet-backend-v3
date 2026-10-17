package dev.whysoezzy.meet.ingestion.timepad

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.ingestion.RawEvent
import dev.whysoezzy.meet.ingestion.TopicClassifier
import java.net.URI
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.util.Locale

internal enum class ReviewedFormat { MOSCOW_PHYSICAL, ONLINE }

internal data class ReviewedEvent(val id: Long, val format: ReviewedFormat)

internal enum class PreviewRejection {
    NOT_REVIEWED, MISSING_START, MALFORMED_START, MALFORMED_END, END_BEFORE_START,
    EMPTY_TITLE, NOT_FUTURE, OUTSIDE_30_DAY_WINDOW, INVALID_SOURCE_URL, SOURCE_URL_ID_MISMATCH,
    FORMAT_AMBIGUOUS, FORMAT_REVIEW_MISMATCH, CITY_OUT_OF_SCOPE, ADDRESS_MISSING, ADDRESS_AMBIGUOUS,
    COORDINATES_INVALID, ONLINE_COORDINATE_CONFLICT, NO_MATCHING_TOPIC,
}

internal enum class PreviewWarning { COORDINATES_MISSING_MAP_UNAVAILABLE }

internal enum class PreviewStatus { CANDIDATE, REJECTED }

internal data class PreviewIdentity(val source: EventSource = EventSource.TIMEPAD, val externalId: String)

internal data class PreviewResult(
    val id: Long,
    val status: PreviewStatus,
    val code: PreviewRejection? = null,
    val identity: PreviewIdentity? = null,
    val normalized: RawEvent? = null,
    val topics: List<String> = emptyList(),
    val warnings: List<PreviewWarning> = emptyList(),
)

internal data class PreviewCounts(
    val input: Int,
    val reviewed: Int,
    val candidates: Int,
    val rejected: Int,
    val reviewedRejected: Int,
)

internal data class PreviewReport(
    val schemaVersion: Int = 1,
    val mode: String = "OFFLINE_CANDIDATES_ONLY",
    val databaseCompared: Boolean = false,
    val inputSha256: String,
    val reviewSha256: String,
    val asOf: String,
    val windowEnd: String,
    val zone: String,
    val counts: PreviewCounts,
    val results: List<PreviewResult>,
)

/** Pure evaluation. No provider, persistence, clock, geocoder or application context. */
internal class TimepadOfflinePreview(private val classifier: TopicClassifier = TopicClassifier()) {
    private val zone = ZoneId.of("Europe/Moscow")

    fun evaluate(
        events: List<TimepadEvent>,
        reviewed: List<ReviewedEvent>,
        asOf: Instant,
        inputSha256: String,
        reviewSha256: String,
    ): PreviewReport {
        require(events.size <= 500 && reviewed.size in 1..500)
        require(events.all { it.id > 0 } && events.map { it.id }.distinct().size == events.size)
        require(reviewed.all { it.id > 0 } && reviewed.map { it.id }.distinct().size == reviewed.size)
        val byId = reviewed.associateBy { it.id }
        require(byId.keys.all { id -> events.any { it.id == id } })
        val end = asOf.plus(Duration.ofDays(30))
        val results = events.sortedBy { it.id }.map { evaluateEvent(it, byId[it.id], asOf, end) }
        val candidates = results.count { it.status == PreviewStatus.CANDIDATE }
        return PreviewReport(
            inputSha256 = inputSha256, reviewSha256 = reviewSha256,
            asOf = asOf.toString(), windowEnd = end.toString(), zone = zone.id,
            counts = PreviewCounts(
                events.size, reviewed.size, candidates, events.size - candidates,
                results.count { it.id in byId && it.status == PreviewStatus.REJECTED },
            ),
            results = results,
        )
    }

    private fun evaluateEvent(
        event: TimepadEvent, review: ReviewedEvent?, asOf: Instant, end: Instant,
    ): PreviewResult {
        fun reject(code: PreviewRejection) = PreviewResult(event.id, PreviewStatus.REJECTED, code)
        if (review == null) return reject(PreviewRejection.NOT_REVIEWED)
        val raw = try {
            TimepadEventMapper.map(event, zone)
        } catch (e: EventMappingRejection) {
            return reject(when (e.reason) {
                MappingRejection.MISSING_START -> PreviewRejection.MISSING_START
                MappingRejection.MALFORMED_START -> PreviewRejection.MALFORMED_START
                MappingRejection.MALFORMED_END -> PreviewRejection.MALFORMED_END
                MappingRejection.END_BEFORE_START -> PreviewRejection.END_BEFORE_START
            })
        }
        if (raw.title.isBlank()) return reject(PreviewRejection.EMPTY_TITLE)
        val start = Instant.ofEpochMilli(raw.startsAtEpochMs)
        if (start <= asOf) return reject(PreviewRejection.NOT_FUTURE)
        if (start > end) return reject(PreviewRejection.OUTSIDE_30_DAY_WINDOW)
        sourceUrlRejection(event.url, event.id)?.let { return reject(it) }

        val loc = event.location
        val cityNode = loc?.path("city")
        val addressNode = loc?.path("address")
        if (loc == null || !loc.isObject ||
            (cityNode != null && !cityNode.isMissingNode && !cityNode.isNull && !cityNode.isString) ||
            (addressNode != null && !addressNode.isMissingNode && !addressNode.isNull && !addressNode.isString)
        ) return reject(PreviewRejection.FORMAT_AMBIGUOUS)
        val city = cityNode?.takeIf { it.isString }?.stringValue().orEmpty().trim()
        val address = addressNode?.takeIf { it.isString }?.stringValue().orEmpty().trim()
        val onlineCity = TimepadEventMapper.isOnlineMarker(city)
        val onlineAddress = TimepadEventMapper.isOnlineMarker(address)
        if ((city.isBlank() && address.isBlank()) || (onlineCity && address.isNotBlank() && !onlineAddress)) {
            return reject(PreviewRejection.FORMAT_AMBIGUOUS)
        }
        val explicitOnline = onlineCity || onlineAddress
        if (raw.isOnline != explicitOnline) return reject(PreviewRejection.FORMAT_AMBIGUOUS)
        if ((review.format == ReviewedFormat.ONLINE) != raw.isOnline) {
            return reject(PreviewRejection.FORMAT_REVIEW_MISMATCH)
        }
        if (!raw.isOnline) {
            if (!isMoscow(city)) return reject(PreviewRejection.CITY_OUT_OF_SCOPE)
            if (address.isBlank()) return reject(PreviewRejection.ADDRESS_MISSING)
            if (isMoscow(address) || address.equals(city, ignoreCase = true)) {
                return reject(PreviewRejection.ADDRESS_AMBIGUOUS)
            }
        }

        val coords = loc.path("coordinates")
        val missingCoords = coords.isMissingNode || (coords.isArray && coords.isEmpty)
        val pair = if (missingCoords) listOf(0.0, 0.0) else {
            if (!coords.isArray || coords.size() != 2) return reject(PreviewRejection.COORDINATES_INVALID)
            coords.values().map {
                when {
                    it.isNumber -> it.doubleValue()
                    it.isString -> it.stringValue().toDoubleOrNull()
                    else -> null
                }
            }
        }
        val lat = pair[0]
        val lng = pair[1]
        if (lat == null || lng == null || !lat.isFinite() || !lng.isFinite() ||
            lat !in -90.0..90.0 || lng !in -180.0..180.0
        ) return reject(PreviewRejection.COORDINATES_INVALID)
        val zero = lat == 0.0 && lng == 0.0
        if (raw.isOnline && !zero) return reject(PreviewRejection.ONLINE_COORDINATE_CONFLICT)
        val topics = classifier.classify(raw).sorted()
        if (topics.isEmpty()) return reject(PreviewRejection.NO_MATCHING_TOPIC)
        return PreviewResult(
            event.id, PreviewStatus.CANDIDATE,
            identity = PreviewIdentity(externalId = event.id.toString()),
            normalized = raw.copy(latitude = lat, longitude = lng, topicKeywords = raw.topicKeywords.toSortedSet()),
            topics = topics,
            warnings = if (!raw.isOnline && zero) listOf(PreviewWarning.COORDINATES_MISSING_MAP_UNAVAILABLE)
                else emptyList(),
        )
    }

    private fun isMoscow(value: String): Boolean =
        value.equals("Москва", ignoreCase = true) || value.equals("Moscow", ignoreCase = true)

    private fun sourceUrlRejection(value: String?, id: Long): PreviewRejection? {
        val uri = try {
            if (value == null) return PreviewRejection.INVALID_SOURCE_URL
            URI(value)
        } catch (_: java.net.URISyntaxException) {
            return PreviewRejection.INVALID_SOURCE_URL
        }
        val host = uri.host?.lowercase(Locale.ROOT)
        if (!uri.scheme.equals("https", ignoreCase = true) || host == null ||
            (host != "timepad.ru" && !host.endsWith(".timepad.ru")) ||
            uri.rawUserInfo != null ||
            (!uri.rawAuthority.equals(host, ignoreCase = true) &&
                !uri.rawAuthority.equals("$host:443", ignoreCase = true))
        ) return PreviewRejection.INVALID_SOURCE_URL
        val match = Regex("/event/([1-9][0-9]*)/?").matchEntire(uri.rawPath.orEmpty())
            ?: return PreviewRejection.INVALID_SOURCE_URL
        if (match.groupValues[1] != id.toString()) return PreviewRejection.SOURCE_URL_ID_MISMATCH
        return null
    }
}
