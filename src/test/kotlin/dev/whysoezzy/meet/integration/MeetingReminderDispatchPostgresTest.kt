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
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

class MeetingReminderDispatchPostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var reminders: MeetingReminderStore

    @Autowired
    private lateinit var installations: PushInstallationService

    @Autowired
    private lateinit var dispatch: JdbcReminderDispatchStore

    private val now = Instant.parse("2026-09-11T20:00:00Z")

    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `leased accepted target becomes sent and closes its claim`() {
        val fixture = seedReminder()
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
        val fixture = seedReminder()
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

    private fun seedReminder(): ApiFixture {
        val fixture = fixture()
        jdbcTemplate.update(
            "UPDATE meetings SET time = ? WHERE id = ?",
            now.plusSeconds(3_600).toEpochMilli(),
            fixture.meeting.id,
        )
        installations.register(requireNotNull(fixture.bob.id), parseFid("fid-bob"))
        val candidate = reminders.findCandidates(now).single()
        requireNotNull(reminders.discover(candidate, now))
        return fixture
    }
}
