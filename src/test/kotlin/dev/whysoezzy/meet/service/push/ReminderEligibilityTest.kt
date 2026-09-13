package dev.whysoezzy.meet.service.push

import org.junit.jupiter.api.Test
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ReminderEligibilityTest {
    private val now = Instant.parse("2026-09-11T20:00:00Z")
    private val start = now.plusSeconds(3600)

    @Test
    fun `reasons follow the contract precedence`() {
        val base = ReminderEligibilityInput(
            userAvailable = true,
            optedIn = true,
            joinedMeeting = true,
            meetingAvailable = true,
            expectedStart = start,
            actualStart = start,
            expectedStartVersion = 2,
            actualStartVersion = 2,
            installationAvailable = true,
            installationFresh = true,
            now = now,
            deadline = now.plusSeconds(900),
        )
        assertEquals(
            ReminderEligibilityReason.USER_UNAVAILABLE,
            ReminderEligibility.reason(base.copy(userAvailable = false, optedIn = false)),
        )
        assertEquals(
            ReminderEligibilityReason.OPTED_OUT,
            ReminderEligibility.reason(base.copy(optedIn = false, joinedMeeting = false)),
        )
        assertEquals(
            ReminderEligibilityReason.LEFT_MEETING,
            ReminderEligibility.reason(base.copy(joinedMeeting = false, meetingAvailable = false)),
        )
        assertEquals(
            ReminderEligibilityReason.MEETING_UNAVAILABLE,
            ReminderEligibility.reason(base.copy(meetingAvailable = false)),
        )
        assertEquals(
            ReminderEligibilityReason.START_CHANGED,
            ReminderEligibility.reason(base.copy(actualStartVersion = 3)),
        )
        assertEquals(
            ReminderEligibilityReason.STARTED,
            ReminderEligibility.reason(base.copy(expectedStart = now, actualStart = now)),
        )
        assertEquals(
            ReminderEligibilityReason.INSTALLATION_UNAVAILABLE,
            ReminderEligibility.reason(base.copy(installationAvailable = false)),
        )
        assertEquals(
            ReminderEligibilityReason.INSTALLATION_STALE,
            ReminderEligibility.reason(base.copy(installationFresh = false)),
        )
        assertEquals(
            ReminderEligibilityReason.DEADLINE_PASSED,
            ReminderEligibility.reason(base.copy(deadline = now.minusMillis(1))),
        )
        assertNull(ReminderEligibility.reason(base))
    }
}
