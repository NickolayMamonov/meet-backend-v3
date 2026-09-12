package dev.whysoezzy.meet.service.push

import org.junit.jupiter.api.Test
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ReminderRetryPolicyTest {
    @Test
    fun `retry delay is deterministic and capped before deadline and meeting start`() {
        val id = UUID.fromString("123e4567-e89b-12d3-a456-426614174000")
        val now = Instant.parse("2026-09-11T20:00:00Z")
        val deadline = now.plusSeconds(600)
        val meetingStart = now.plusSeconds(900)
        val first = ReminderRetryPolicy.nextAttemptAt(id, 1, now, deadline, meetingStart)
        val second = ReminderRetryPolicy.nextAttemptAt(id, 1, now, deadline, meetingStart)

        assertEquals(first, second)
        assertNotNull(first)
        assertTrue(first.isAfter(now))
        assertTrue(first.isBefore(deadline))
        assertTrue(first.isBefore(meetingStart))
        assertTrue(
            ReminderRetryPolicy.nextAttemptAt(
                id,
                1,
                now,
                now.plusSeconds(1),
                meetingStart,
            )!!.isBefore(now.plusSeconds(1)),
        )
        assertNull(
            ReminderRetryPolicy.nextAttemptAt(
                id,
                1,
                now,
                deadline,
                now,
            ),
        )
        assertEquals(
            now,
            ReminderRetryPolicy.nextAttemptAt(
                id,
                1,
                now,
                now,
                now.plusSeconds(60),
            ),
        )
    }
}
