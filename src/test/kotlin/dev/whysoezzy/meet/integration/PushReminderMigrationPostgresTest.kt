package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.service.push.MeetingReminderStore
import dev.whysoezzy.meet.service.push.PushInstallationService
import dev.whysoezzy.meet.service.push.parseFid
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.dao.DataIntegrityViolationException
import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.ingestion.MeetingUpsertService
import dev.whysoezzy.meet.ingestion.RawEvent
import dev.whysoezzy.meet.ingestion.UpsertResult
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

    @Autowired
    private lateinit var upsertService: MeetingUpsertService

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

    @Test
    fun `start version increments for raw SQL and TIMEPAD upsert away and back`() {
        val fixture = fixture()
        val original = fixture.meeting.time
        val originalVersion = jdbcTemplate.queryForObject(
            "SELECT push_start_version FROM meetings WHERE id = ?",
            Long::class.java,
            fixture.meeting.id,
        )

        jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", original + 1_000, fixture.meeting.id)
        jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", original, fixture.meeting.id)
        assertEquals(
            originalVersion!! + 2,
            jdbcTemplate.queryForObject(
                "SELECT push_start_version FROM meetings WHERE id = ?",
                Long::class.java,
                fixture.meeting.id,
            ),
        )

        val raw = RawEvent(
            sourceExternalId = "version-away-back",
            title = "Kotlin version trigger",
            description = "PostgreSQL trigger proof",
            imageUrl = "",
            startsAtEpochMs = 1_790_000_000_000,
            address = "Online",
            latitude = 0.0,
            longitude = 0.0,
            externalUrl = null,
            isOnline = true,
            topicKeywords = setOf("ИТ и интернет"),
        )
        assertEquals(UpsertResult.CREATED, upsertService.upsert(EventSource.TIMEPAD, raw))
        val upserted = meetings.findAll().single { it.sourceExternalId == raw.sourceExternalId }
        val baseVersion = jdbcTemplate.queryForObject(
            "SELECT push_start_version FROM meetings WHERE id = ?",
            Long::class.java,
            upserted.id,
        )
        val changed = raw.copy(startsAtEpochMs = raw.startsAtEpochMs + 1_000)
        assertEquals(UpsertResult.UPDATED, upsertService.upsert(EventSource.TIMEPAD, changed))
        assertEquals(UpsertResult.UPDATED, upsertService.upsert(EventSource.TIMEPAD, raw))
        assertEquals(
            baseVersion!! + 2,
            jdbcTemplate.queryForObject(
                "SELECT push_start_version FROM meetings WHERE id = ?",
                Long::class.java,
                upserted.id,
            ),
        )
    }

    @Test
    fun `V10 rejects invalid lifecycle, timing, lease and attempt rows`() {
        val fixture = fixture()
        val now = Instant.parse("2026-09-11T20:00:00Z")
        val timestamp = java.sql.Timestamp.from(now)
        val userId = requireNotNull(fixture.bob.id)
        val installationId = UUID.randomUUID()
        assertFailsWith<DataIntegrityViolationException> {
            jdbcTemplate.update(
                """
                INSERT INTO push_installations
                    (id, user_id, fid, status, registration_version, created_at, updated_at, last_seen_at, terminal_at)
                VALUES (?, ?, ?, 'ACTIVE', 1, ?, ?, ?, ?)
                """.trimIndent(),
                installationId, userId, "bad-terminal", timestamp, timestamp, timestamp, timestamp,
            )
        }
        jdbcTemplate.update(
            """
            INSERT INTO push_installations
                (id, user_id, fid, status, registration_version, created_at, updated_at, last_seen_at, terminal_at)
            VALUES (?, ?, ?, 'ACTIVE', 1, ?, ?, ?, NULL)
            """.trimIndent(),
            installationId, userId, "fid-migration-constraints", timestamp, timestamp, timestamp,
        )
        val meetingStart = now.plusSeconds(3_600)
        assertFailsWith<DataIntegrityViolationException> {
            jdbcTemplate.update(
                """
                INSERT INTO meeting_reminder_claims
                    (id, user_id, meeting_id, reminder_offset_minutes, meeting_start_ms,
                     start_version, due_at, deadline_at, issued_at, status, completed_at)
                VALUES (?, ?, ?, 60, ?, 0, ?, ?, ?, 'PENDING', NULL)
                """.trimIndent(),
                UUID.randomUUID(),
                userId,
                fixture.meeting.id,
                meetingStart.toEpochMilli(),
                java.sql.Timestamp.from(now.plusSeconds(1)),
                java.sql.Timestamp.from(now.plusSeconds(16 * 60)),
                timestamp,
            )
        }
        val claimId = UUID.randomUUID()
        jdbcTemplate.update(
            """
            INSERT INTO meeting_reminder_claims
                (id, user_id, meeting_id, reminder_offset_minutes, meeting_start_ms,
                 start_version, due_at, deadline_at, issued_at, status, completed_at)
            VALUES (?, ?, ?, 60, ?, 0, ?, ?, ?, 'PENDING', NULL)
            """.trimIndent(),
            claimId, userId, fixture.meeting.id, meetingStart.toEpochMilli(),
            timestamp, java.sql.Timestamp.from(now.plusSeconds(15 * 60)),
            timestamp,
        )
        val targetId = UUID.randomUUID()
        assertFailsWith<DataIntegrityViolationException> {
            jdbcTemplate.update(
                """
                INSERT INTO meeting_reminder_targets
                    (id, claim_id, user_id, installation_id, status, attempts, next_attempt_at,
                     lease_token, lease_until, reason, completed_at)
                VALUES (?, ?, ?, ?, 'LEASED', 0, ?, NULL, NULL, NULL, NULL)
                """.trimIndent(),
                targetId, claimId, userId, installationId, java.sql.Timestamp.from(now),
            )
        }
        assertFailsWith<DataIntegrityViolationException> {
            jdbcTemplate.update(
                """
                INSERT INTO meeting_reminder_targets
                    (id, claim_id, user_id, installation_id, status, attempts, next_attempt_at,
                     lease_token, lease_until, reason, completed_at)
                VALUES (?, ?, ?, ?, 'PENDING', 6, ?, NULL, NULL, NULL, NULL)
                """.trimIndent(),
                targetId, claimId, userId, installationId, java.sql.Timestamp.from(now),
            )
        }
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
