package dev.whysoezzy.meet.ingestion

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.Meeting
import java.text.Normalizer
import java.time.LocalDateTime
import java.util.Locale

/** Immutable evidence captured before provider/enrichment I/O, never a managed entity. */
data class SavedTimepadVenue(
    val id: Long?,
    val source: EventSource,
    val externalId: String?,
    val address: String,
    val online: Boolean,
    val latitude: Double,
    val longitude: Double,
    val ingestedAt: LocalDateTime?,
) {
    companion object {
        fun from(meeting: Meeting) = SavedTimepadVenue(
            meeting.id, meeting.source, meeting.sourceExternalId, meeting.address,
            meeting.isOnline, meeting.latitude, meeting.longitude, meeting.ingestedAt,
        )
    }
}

/** Derived evidence stays separate from RawEvent's authoritative source point. */
data class PreparedTimepadPoint(
    val externalId: String,
    val address: String,
    val expectedSaved: SavedTimepadVenue?,
    val point: Coordinates,
)

internal object TimepadCoordinateEnrichment {
    private val whitespace = Regex("[\\p{Z}\\s]+")

    fun addressIdentity(address: String): String =
        Normalizer.normalize(address, Normalizer.Form.NFC)
            .lowercase(Locale.ROOT).replace(whitespace, " ").trim()

    fun valid(latitude: Double, longitude: Double): Boolean =
        latitude.isFinite() && longitude.isFinite() &&
            latitude in -90.0..90.0 && longitude in -180.0..180.0 &&
            (latitude != 0.0 || longitude != 0.0)

    private fun reusable(raw: RawEvent, saved: SavedTimepadVenue?): Boolean =
        saved != null && saved.source == EventSource.TIMEPAD &&
            saved.externalId == raw.sourceExternalId && !raw.isOnline && !saved.online &&
            addressIdentity(saved.address) == addressIdentity(raw.address) &&
            valid(saved.latitude, saved.longitude)

    fun needsPoint(raw: RawEvent, saved: SavedTimepadVenue?): Boolean =
        !raw.isOnline && raw.address.isNotBlank() &&
            !valid(raw.latitude, raw.longitude) && !reusable(raw, saved)

    fun select(raw: RawEvent, locked: SavedTimepadVenue?, prepared: PreparedTimepadPoint?): Coordinates {
        if (valid(raw.latitude, raw.longitude)) return Coordinates(raw.latitude, raw.longitude)
        if (reusable(raw, locked)) return Coordinates(locked!!.latitude, locked.longitude)
        if (!raw.isOnline && raw.address.isNotBlank() &&
            prepared != null && prepared.externalId == raw.sourceExternalId &&
            prepared.address == raw.address && prepared.expectedSaved == locked &&
            (locked == null || (locked.source == EventSource.TIMEPAD && locked.externalId == raw.sourceExternalId)) &&
            valid(prepared.point.latitude, prepared.point.longitude)
        ) return prepared.point
        return Coordinates(0.0, 0.0)
    }
}
