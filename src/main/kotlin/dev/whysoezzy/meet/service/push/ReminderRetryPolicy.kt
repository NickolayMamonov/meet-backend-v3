package dev.whysoezzy.meet.service.push

import java.nio.ByteBuffer
import java.time.Duration
import java.time.Instant
import java.util.UUID
import kotlin.math.min

object ReminderRetryPolicy {
    const val MAX_ATTEMPTS = 5
    private val BASE_DELAYS = longArrayOf(30, 60, 120, 240)

    /**
     * [attempt] is the attempt that just completed (1..4). At the inclusive
     * deadline/start boundary, a zero-delay retry keeps the fifth attempt
     * durable without scheduling before now or at/after the meeting start.
     */
    fun nextAttemptAt(
        targetId: UUID,
        attempt: Int,
        now: Instant,
        deadline: Instant,
        meetingStart: Instant,
    ): Instant? {
        require(attempt in 1..4) { "Retry attempt must be between 1 and 4" }
        val baseMillis = BASE_DELAYS[attempt - 1] * 1_000
        val jitterBound = baseMillis / 5
        val jitter = deterministicJitter(targetId, attempt, jitterBound)
        val requested = now.plusMillis(baseMillis + jitter)
        val latest = min(
            deadline.toEpochMilli() - 1,
            meetingStart.toEpochMilli() - 1,
        )
        val candidate = min(requested.toEpochMilli(), latest)
        return when {
            candidate > now.toEpochMilli() -> Instant.ofEpochMilli(candidate)
            !now.isAfter(deadline) && now.isBefore(meetingStart) -> now
            else -> null
        }
    }

    private fun deterministicJitter(targetId: UUID, attempt: Int, bound: Long): Long {
        if (bound <= 0) return 0
        val bytes = ByteBuffer.allocate(20)
            .putLong(targetId.mostSignificantBits)
            .putLong(targetId.leastSignificantBits)
            .putInt(attempt)
            .array()
        var hash = 0x811c9dc5L
        bytes.forEach { byte ->
            hash = (hash xor (byte.toInt() and 0xff).toLong()) * 0x01000193L
        }
        return (hash and Long.MAX_VALUE) % (bound + 1)
    }
}
