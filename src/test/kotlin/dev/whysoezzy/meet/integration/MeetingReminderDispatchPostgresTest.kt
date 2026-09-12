package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.service.push.JdbcReminderDispatchStore
import dev.whysoezzy.meet.service.push.MeetingReminderStore
import dev.whysoezzy.meet.service.push.PushInstallationService
import dev.whysoezzy.meet.service.push.ReminderFinalization
import dev.whysoezzy.meet.service.push.parseFid
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class MeetingReminderDispatchPostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var reminders: MeetingReminderStore

    @Autowired
    private lateinit var installations: PushInstallationService

    @Autowired
    private lateinit var dispatch: JdbcReminderDispatchStore

    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `leased accepted target becomes sent and closes its claim`() {
        val now = databaseNow()
        val fixture = seedReminder(now)
        val lease = dispatch.leaseNext()
        assertNotNull(lease)
        val prepared = dispatch.prepareSend(lease, now)
        assertNotNull(prepared)

        assertEquals(true, dispatch.finalize(lease, prepared, ReminderFinalization.Accepted, now))
        assertEquals(
            "SENT",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
        assertEquals(
            "SENT",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_claims WHERE id = ?",
                String::class.java,
                lease.claimId,
            ),
        )
        assertEquals(fixture.bob.id, lease.userId)
    }

    @Test
    fun `invalid provider registration terminally invalidates only the exact installation`() {
        val now = databaseNow()
        val fixture = seedReminder(now)
        val lease = requireNotNull(dispatch.leaseNext())
        val prepared = requireNotNull(dispatch.prepareSend(lease, now))

        dispatch.finalize(lease, prepared, ReminderFinalization.InvalidRegistration, now)

        assertEquals(
            "INVALID",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
        assertEquals(
            "UNREGISTERED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM push_installations WHERE user_id = ?",
                String::class.java,
                fixture.bob.id,
            ),
        )
        assertEquals(null, jdbcTemplate.queryForObject(
            "SELECT fid FROM push_installations WHERE user_id = ?",
            String::class.java,
            fixture.bob.id,
        ))
    }

    @Test
    fun `expired fifth lease applies eligibility precedence before attempts exhausted`() {
        val now = databaseNow()
        val fixture = seedReminder(now)
        val lease = requireNotNull(dispatch.leaseNext())
        jdbcTemplate.update(
            """
            UPDATE meeting_reminder_targets
            SET attempts = 5, status = 'LEASED',
                lease_until = clock_timestamp() - INTERVAL '1 second'
            WHERE id = ?
            """.trimIndent(),
            lease.targetId,
        )
        jdbcTemplate.update("UPDATE users SET notifications_enabled = false WHERE id = ?", fixture.bob.id)

        assertEquals(1, dispatch.recoverAndExpire(100, now))
        assertEquals(
            "SKIPPED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
        assertEquals(
            "OPTED_OUT",
            jdbcTemplate.queryForObject(
                "SELECT reason FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
        assertNull(
            jdbcTemplate.queryForObject(
                "SELECT lease_token FROM meeting_reminder_targets WHERE id = ?",
                UUID::class.java,
                lease.targetId,
            ),
        )
    }

    @Test
    fun `transient retries consume exactly five attempts and never lease a sixth`() {
        val now = databaseNow()
        seedReminder(now)

        repeat(4) {
            val lease = requireNotNull(dispatch.leaseNext())
            val prepared = requireNotNull(dispatch.prepareSend(lease, now))
            assertEquals(true, dispatch.finalize(lease, prepared, ReminderFinalization.TransientFailure, now))
            jdbcTemplate.update(
                "UPDATE meeting_reminder_targets SET next_attempt_at = clock_timestamp() - INTERVAL '1 second'",
            )
        }
        val fifth = requireNotNull(dispatch.leaseNext())
        val prepared = requireNotNull(dispatch.prepareSend(fifth, now))
        assertEquals(true, dispatch.finalize(fifth, prepared, ReminderFinalization.TransientFailure, now))

        assertEquals(
            "FAILED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                fifth.targetId,
            ),
        )
        assertEquals(null, dispatch.leaseNext())
    }

    @Test
    fun `stale lease completion has no state or invalidation side effects`() {
        val now = databaseNow()
        val fixture = seedReminder(now)
        val lease = requireNotNull(dispatch.leaseNext())
        val prepared = requireNotNull(dispatch.prepareSend(lease, now))
        val stale = lease.copy(leaseToken = UUID.randomUUID())

        assertEquals(false, dispatch.finalize(stale, prepared, ReminderFinalization.InvalidRegistration, now))
        assertEquals(
            "LEASED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
        assertEquals(
            "ACTIVE",
            jdbcTemplate.queryForObject(
                "SELECT status FROM push_installations WHERE user_id = ?",
                String::class.java,
                fixture.bob.id,
            ),
        )
    }

    private fun seedReminder(now: Instant): ApiFixture {
        val fixture = fixture()
        jdbcTemplate.update(
            "UPDATE meetings SET time = ? WHERE id = ?",
            now.plusSeconds(3_600).toEpochMilli(),
            fixture.meeting.id,
        )
        installations.register(requireNotNull(fixture.bob.id), parseFid("fid-bob"))
        val candidate = reminders.findCandidates(now).single()
        requireNotNull(reminders.discover(candidate, now))
        jdbcTemplate.update(
            "UPDATE meeting_reminder_targets SET next_attempt_at = clock_timestamp() - INTERVAL '1 second'",
        )
        return fixture
    }

    private fun databaseNow(): Instant =
        jdbcTemplate.queryForObject(
            "SELECT clock_timestamp()",
            java.sql.Timestamp::class.java,
        )!!.toInstant().truncatedTo(ChronoUnit.MILLIS)
}
