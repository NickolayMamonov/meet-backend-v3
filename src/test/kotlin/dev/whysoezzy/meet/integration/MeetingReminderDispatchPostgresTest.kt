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
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

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
