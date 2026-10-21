package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.service.push.JdbcReminderDispatchStore
import dev.whysoezzy.meet.service.push.MeetingReminderStore
import dev.whysoezzy.meet.service.push.PushInstallationService
import dev.whysoezzy.meet.service.push.parseFid
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class TimepadReminderVisibilityPostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var reminders: MeetingReminderStore

    @Autowired
    private lateinit var installations: PushInstallationService

    @Autowired
    private lateinit var dispatch: JdbcReminderDispatchStore

    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `discovery omits expired and revoked Timepad rows and allows fresh eligible claims`() {
        val now = databaseNow()
        val bob = users.save(User("Bob", "Member", "+15550000002"))
        val bobId = requireNotNull(bob.id)
        installations.register(bobId, parseFid("fid-timepad-discovery"))

        val expired = meeting("expired", bobId, now, now.minusMillis(1))
        val revoked = meeting("revoked-before-claim", bobId, now, now.plusSeconds(3_600))
        val fresh = meeting("fresh", bobId, now, now.plusSeconds(3_600))
        meetings.saveAll(listOf(expired, revoked, fresh))
        meetings.flush()

        val candidates = reminders.findCandidates(now)
        assertEquals(setOf(revoked.id, fresh.id), candidates.map { it.meetingId }.toSet())
        assertEquals(1, candidates.count { it.meetingId == revoked.id })
        assertEquals(1, candidates.count { it.meetingId == fresh.id })
        assertEquals(0, candidates.count { it.meetingId == expired.id })

        jdbcTemplate.update(
            "UPDATE meetings SET timepad_eligible_until_ms = NULL WHERE id = ?",
            revoked.id,
        )
        assertNull(reminders.discover(candidates.single { it.meetingId == revoked.id }, now))
        assertEquals(
            0L,
            jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM meeting_reminder_claims WHERE meeting_id = ?",
                Long::class.java,
                revoked.id,
            ),
        )

        val freshClaim = reminders.discover(candidates.single { it.meetingId == fresh.id }, now)
        assertNotNull(freshClaim)
        assertEquals(fresh.id, freshClaim.meetingId)
    }

    @Test
    fun `dispatch refuses to prepare a claimed Timepad reminder after visibility is revoked`() {
        val now = databaseNow()
        val bob = users.save(User("Bob", "Member", "+15550000002"))
        val bobId = requireNotNull(bob.id)
        installations.register(bobId, parseFid("fid-timepad-dispatch"))
        val timepadMeeting = meeting("revoked-before-send", bobId, now, now.plusSeconds(3_600))
        meetings.save(timepadMeeting)
        meetings.flush()

        val candidate = reminders.findCandidates(now).single()
        val claim = assertNotNull(reminders.discover(candidate, now))
        assertEquals(
            1L,
            jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM meeting_reminder_targets WHERE claim_id = ?",
                Long::class.java,
                claim.id,
            ),
        )

        jdbcTemplate.update(
            "UPDATE meetings SET timepad_eligible_until_ms = NULL WHERE id = ?",
            timepadMeeting.id,
        )
        val lease = assertNotNull(dispatch.leaseNext())
        assertNull(dispatch.prepareSend(lease, now))
        assertEquals(true, dispatch.skipIneligible(lease, now))
        assertEquals(
            "MEETING_UNAVAILABLE",
            jdbcTemplate.queryForObject(
                "SELECT reason FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
        assertEquals(
            0L,
            jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM meeting_reminder_targets WHERE status = 'SENT'",
                Long::class.java,
            ),
        )
    }

    private fun meeting(
        key: String,
        userId: Long,
        now: Instant,
        eligibleUntil: Instant,
    ) = Meeting(
        title = "Timepad $key",
        description = "Reminder visibility fixture",
        imageUrl = "",
        time = now.plusSeconds(3_600).toEpochMilli(),
        date = "01.01.2026",
        address = "Moscow",
        latitude = 55.75,
        longitude = 37.61,
        participants = mutableSetOf(users.findById(userId).orElseThrow()),
        source = EventSource.TIMEPAD,
        sourceExternalId = key,
        timepadEligibleUntilMs = eligibleUntil.toEpochMilli(),
    )

    private fun databaseNow(): Instant =
        jdbcTemplate.queryForObject(
            "SELECT clock_timestamp()",
            java.sql.Timestamp::class.java,
        )!!.toInstant()
}
