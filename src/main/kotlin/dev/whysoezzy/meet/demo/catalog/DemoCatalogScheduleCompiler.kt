package dev.whysoezzy.meet.demo.catalog

import java.time.Clock
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

data class CompiledMeeting(
    val time: Long,
    val date: String,
    val endsAt: Long,
)

class DemoCatalogScheduleCompiler(
    private val clock: Clock,
    private val zoneId: ZoneId = ZoneId.of("Europe/Moscow"),
) {
    private val dateFormatter = DateTimeFormatter.ofPattern("dd.MM.yyyy")

    fun compile(
        manifest: BetaDemoCatalogManifest,
        scheduleAnchorDate: LocalDate,
        catalogValidThrough: Instant,
    ): Map<CatalogKey, CompiledMeeting> {
        val now = clock.instant()
        return manifest.meetings.associate { meeting ->
            val start = scheduleAnchorDate
                .plusDays(meeting.dayOffset)
                .atTime(meeting.localStart)
                .atZone(zoneId)
            val end = start.plusMinutes(meeting.durationMinutes)
            val compiled = CompiledMeeting(start.toInstant().toEpochMilli(), start.format(dateFormatter), end.toInstant().toEpochMilli())
            require(start.toInstant().isAfter(now) && start.toInstant().isAfter(catalogValidThrough) && compiled.endsAt > compiled.time)
            meeting.key to compiled
        }
    }
}
