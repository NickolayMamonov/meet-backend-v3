package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.service.push.MeetingReminderStore
import dev.whysoezzy.meet.service.push.PushInstallationService
import dev.whysoezzy.meet.service.push.ReminderOffset
import dev.whysoezzy.meet.service.push.parseFid
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class MeetingReminderDiscoveryPostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var reminders: MeetingReminderStore

    @Autowired
    private lateinit var installations: PushInstallationService

    private val now = Instant.parse("2026-09-11T20:00:00Z")

    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `discovery snapshots active fresh installations and is idempotent per offset`() {
        val fixture = fixture()
        val meetingTime = now.plusSeconds(3_600).toEpochMilli()
        jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", meetingTime, fixture.meeting.id)
        installations.register(requireNotNull(fixture.bob.id), parseFid("fid-bob"))

        val candidate = reminders.findCandidates(now).single()
        assertEquals(ReminderOffset.ONE_HOUR, candidate.offset)
        val claim = reminders.discover(candidate, now)

        assertNotNull(claim)
        assertEquals(1L, jdbcTemplate.queryForObject(
            "SELECT COUNT(*) FROM meeting_reminder_targets WHERE claim_id = ?",
            Long::class.java,
            claim.id,
        ))
        assertNull(reminders.discover(candidate, now))
        assertEquals(
            "PENDING",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_claims WHERE id = ?",
                String::class.java,
                claim.id,
            ),
        )
    }

    @Test
    fun `discovery rejects a candidate when mutable opt in changes before claim`() {
        val fixture = fixture()
        val meetingTime = now.plusSeconds(3_600).toEpochMilli()
        jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", meetingTime, fixture.meeting.id)
        installations.register(requireNotNull(fixture.bob.id), parseFid("fid-bob"))
        val candidate = reminders.findCandidates(now).single()
        jdbcTemplate.update("UPDATE users SET notifications_enabled = false WHERE id = ?", fixture.bob.id)

        assertNull(reminders.discover(candidate, now))
        assertEquals(
            0L,
            jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM meeting_reminder_claims",
                Long::class.java,
            ),
        )
    }
}
