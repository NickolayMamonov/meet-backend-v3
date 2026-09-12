package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.service.push.MeetingReminderStore
import dev.whysoezzy.meet.service.push.PushInstallationService
import dev.whysoezzy.meet.service.push.parseFid
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.dao.DataIntegrityViolationException
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class PushReminderMigrationPostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var reminders: MeetingReminderStore

    @Autowired
    private lateinit var installations: PushInstallationService

    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `V10 creates push tables and meeting start version trigger`() {
        val fixture = fixture()
        val tables = jdbcTemplate.queryForList(
            """
            SELECT table_name
            FROM information_schema.tables
            WHERE table_schema = current_schema()
              AND table_name IN ('push_installations', 'meeting_reminder_claims', 'meeting_reminder_targets')
            ORDER BY table_name
            """.trimIndent(),
            String::class.java,
        )
        assertEquals(
            listOf("meeting_reminder_claims", "meeting_reminder_targets", "push_installations"),
            tables,
        )

        val before = jdbcTemplate.queryForObject(
            "SELECT push_start_version FROM meetings WHERE id = ?",
            Long::class.java,
            fixture.meeting.id,
        )
        jdbcTemplate.update(
            "UPDATE meetings SET time = time + 1000 WHERE id = ?",
            fixture.meeting.id,
        )
        val afterChange = jdbcTemplate.queryForObject(
            "SELECT push_start_version FROM meetings WHERE id = ?",
            Long::class.java,
            fixture.meeting.id,
        )
        jdbcTemplate.update(
            "UPDATE meetings SET time = time - 1000 WHERE id = ?",
            fixture.meeting.id,
        )
        val afterReturn = jdbcTemplate.queryForObject(
            "SELECT push_start_version FROM meetings WHERE id = ?",
            Long::class.java,
            fixture.meeting.id,
        )

        assertEquals(0L, before)
        assertEquals(1L, afterChange)
        assertEquals(2L, afterReturn)
    }

    @Test
    fun `V10 rejects illegal terminal target attempt and reason combinations`() {
        val now = databaseNow()
        seedReminder(now)
        val targetId = jdbcTemplate.queryForObject(
            "SELECT id FROM meeting_reminder_targets LIMIT 1",
            java.util.UUID::class.java,
        )

        val illegalStates = listOf(
            Triple("SENT", 1, "TRANSIENT"),
            Triple("INVALID", 1, "ACCEPTED"),
            Triple("FAILED", 4, "ATTEMPTS_EXHAUSTED"),
            Triple("FAILED", 5, "TRANSIENT"),
            Triple("SKIPPED", 0, "ACCEPTED"),
        )
        illegalStates.forEach { (status, attempts, reason) ->
            assertFailsWith<DataIntegrityViolationException> {
                jdbcTemplate.update(
                    """
                    UPDATE meeting_reminder_targets
                    SET status = ?, attempts = ?, reason = ?, completed_at = clock_timestamp()
                    WHERE id = ?
                    """.trimIndent(),
                    status,
                    attempts,
                    reason,
                    targetId,
                )
            }
        }

        jdbcTemplate.update(
            """
            UPDATE meeting_reminder_targets
            SET status = 'FAILED', attempts = 5, reason = 'ATTEMPTS_EXHAUSTED',
                completed_at = clock_timestamp()
            WHERE id = ?
            """.trimIndent(),
            targetId,
        )
        assertEquals(
            "FAILED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                targetId,
            ),
        )
    }

    private fun seedReminder(now: Instant) {
        val fixture = fixture()
        jdbcTemplate.update(
            "UPDATE meetings SET time = ? WHERE id = ?",
            now.plusSeconds(3_600).toEpochMilli(),
            fixture.meeting.id,
        )
        installations.register(requireNotNull(fixture.bob.id), parseFid("fid-migration"))
        val candidate = reminders.findCandidates(now).single()
        requireNotNull(reminders.discover(candidate, now))
    }

    private fun databaseNow(): Instant =
        jdbcTemplate.queryForObject(
            "SELECT clock_timestamp()",
            java.sql.Timestamp::class.java,
        )!!.toInstant().truncatedTo(ChronoUnit.MILLIS)
}
