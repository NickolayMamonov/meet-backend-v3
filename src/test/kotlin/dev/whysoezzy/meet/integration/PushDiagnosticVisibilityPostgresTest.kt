package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.service.push.JdbcPushDiagnosticStore
import dev.whysoezzy.meet.service.push.PushDiagnosticCommand
import dev.whysoezzy.meet.service.push.PushDiagnosticMode
import dev.whysoezzy.meet.service.push.PushInstallationService
import dev.whysoezzy.meet.service.push.parseFid
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import java.time.Instant
import java.util.UUID
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class PushDiagnosticVisibilityPostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var diagnosticStore: JdbcPushDiagnosticStore

    @Autowired
    private lateinit var installationService: PushInstallationService

    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `selection and pair recheck use database visibility while preserving manual and demo controls`() {
        val fixture = fixture()
        val userId = requireNotNull(fixture.bob.id)
        val installationId = installationService.register(userId, parseFid("fid-diagnostic-visibility"))
            .installation.id

        val accepted = saveMeeting(fixture.bob, "accepted", EventSource.TIMEPAD)
        val expired = saveMeeting(fixture.bob, "expired", EventSource.TIMEPAD)
        val rejected = saveMeeting(fixture.bob, "rejected", EventSource.TIMEPAD)
        val legacyNull = saveMeeting(fixture.bob, "legacy-null", EventSource.TIMEPAD)
        val manual = saveMeeting(fixture.bob, "manual", EventSource.MANUAL)
        val demo = saveMeeting(
            fixture.bob,
            "demo",
            EventSource.TIMEPAD,
            demoCatalogKey = "diagnostic-visibility-demo",
        )

        setEligibleUntil(accepted, 2 * 60 * 60 * 1000L)
        setEligibleUntil(expired, -1_000L)
        // A rejected saved event and an unclassified legacy row are both revoked/hidden.
        setEligibleUntil(rejected, null)

        val skewedPast = Instant.parse("1970-01-01T00:00:00Z")
        val skewedFuture = Instant.parse("2999-01-01T00:00:00Z")

        assertNotNull(diagnosticStore.select(accepted, userId, installationId, skewedFuture))
        assertNull(diagnosticStore.select(expired, userId, installationId, skewedPast))
        assertNull(diagnosticStore.select(rejected, userId, installationId, skewedPast))
        assertNull(diagnosticStore.select(legacyNull, userId, installationId, skewedPast))
        assertNotNull(diagnosticStore.select(manual, userId, installationId, skewedFuture))
        assertNotNull(diagnosticStore.select(demo, userId, installationId, skewedFuture))

        val acceptedSelection = requireNotNull(
            diagnosticStore.select(accepted, userId, installationId, skewedPast),
        )
        assertNotNull(diagnosticStore.recheckEligible(acceptedSelection, skewedFuture))
        assertNull(diagnosticStore.recheckEligible(acceptedSelection.copy(meetingId = expired), skewedPast))
        assertNull(diagnosticStore.recheckEligible(acceptedSelection.copy(meetingId = rejected), skewedFuture))
        assertNull(diagnosticStore.recheckEligible(acceptedSelection.copy(meetingId = legacyNull), skewedPast))

        // Expiry between the initial selection and pair recheck must win using DB time.
        setEligibleUntil(accepted, -1_000L)
        assertNull(diagnosticStore.recheckEligible(acceptedSelection, skewedPast))

        val manualSelection = requireNotNull(
            diagnosticStore.select(manual, userId, installationId, skewedPast),
        )
        assertNotNull(diagnosticStore.recheckEligible(manualSelection, skewedFuture))
        val demoSelection = requireNotNull(
            diagnosticStore.select(demo, userId, installationId, skewedPast),
        )
        assertNotNull(diagnosticStore.recheckEligible(demoSelection, skewedFuture))
    }

    private fun saveMeeting(
        participant: User,
        name: String,
        source: EventSource,
        demoCatalogKey: String? = null,
    ): Long {
        val meeting = meetings.saveAndFlush(
            Meeting(
                title = "Push diagnostic $name",
                description = "Visibility integration fixture",
                imageUrl = "",
                time = System.currentTimeMillis() + 3_600_000,
                date = "21.10.2026",
                address = "Moscow",
                latitude = 55.75,
                longitude = 37.61,
                source = source,
                sourceExternalId = if (source == EventSource.TIMEPAD) name else null,
                participants = mutableSetOf(participant),
                demoCatalogKey = demoCatalogKey,
            ),
        )
        val id = requireNotNull(meeting.id)
        jdbcTemplate.update(
            """
            UPDATE meetings
            SET time = (EXTRACT(EPOCH FROM clock_timestamp() + INTERVAL '2 hours') * 1000)::bigint
            WHERE id = ?
            """.trimIndent(),
            id,
        )
        return id
    }

    private fun setEligibleUntil(meetingId: Long, offsetFromDatabaseNowMs: Long?) {
        if (offsetFromDatabaseNowMs == null) {
            jdbcTemplate.update(
                "UPDATE meetings SET timepad_eligible_until_ms = NULL WHERE id = ?",
                meetingId,
            )
        } else {
            jdbcTemplate.update(
                """
                UPDATE meetings
                SET timepad_eligible_until_ms =
                    (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint + ?
                WHERE id = ?
                """.trimIndent(),
                offsetFromDatabaseNowMs,
                meetingId,
            )
        }
    }

    private fun JdbcPushDiagnosticStore.select(
        meetingId: Long,
        userId: Long,
        installationId: UUID,
        now: Instant,
    ) = selectEligible(
        PushDiagnosticCommand(
            userId = userId,
            installationId = installationId,
            meetingId = meetingId,
            reminderOffsetMinutes = 60,
            mode = PushDiagnosticMode.DEDUP_PAIR,
        ),
        now,
    )
}
