package dev.whysoezzy.meet.service.push

import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Component
import java.sql.ResultSet
import java.sql.Timestamp
import java.time.Instant
import java.util.UUID

data class ReminderCandidate(
    val userId: Long,
    val meetingId: Long,
    val offset: ReminderOffset,
    val meetingStartMs: Long,
    val startVersion: Long,
    val dueAt: Instant,
    val deadlineAt: Instant,
)

data class ReminderClaimRecord(
    val id: UUID,
    val userId: Long,
    val meetingId: Long,
    val offset: ReminderOffset,
    val meetingStartMs: Long,
    val startVersion: Long,
    val dueAt: Instant,
    val deadlineAt: Instant,
    val issuedAt: Instant,
    val status: ReminderClaimStatus,
)

/**
 * JDBC authority for reminder persistence. The scheduler owns the transaction
 * around discovery so that claim creation and the complete target snapshot
 * commit or roll back together.
 */
@Component
class MeetingReminderStore(
    private val jdbc: JdbcTemplate,
) {
    fun findCandidates(now: Instant, limit: Int = 100): List<ReminderCandidate> {
        require(limit > 0)
        return jdbc.query(
            """
            WITH offsets(minutes) AS (VALUES (1440), (60)),
            candidates AS (
                SELECT p.user_id, m.id AS meeting_id, o.minutes,
                       m.time AS meeting_start_ms, m.push_start_version,
                       to_timestamp((m.time - o.minutes * 60000)::double precision / 1000) AS due_at
                FROM meeting_participants p
                JOIN users u ON u.id = p.user_id
                JOIN meetings m ON m.id = p.meeting_id
                CROSS JOIN offsets o
                WHERE u.deleted_at IS NULL
                  AND u.notifications_enabled
                  AND m.status = 'ACTIVE'
                  AND m.time > EXTRACT(EPOCH FROM ?::timestamptz) * 1000
                  AND to_timestamp((m.time - o.minutes * 60000)::double precision / 1000)
                      BETWEEN ?::timestamptz AND ?::timestamptz + INTERVAL '15 minutes'
                  AND NOT EXISTS (
                      SELECT 1 FROM meeting_reminder_claims c
                      WHERE c.user_id = p.user_id
                        AND c.meeting_id = m.id
                        AND c.reminder_offset_minutes = o.minutes
                  )
            )
            SELECT user_id, meeting_id, minutes, meeting_start_ms, push_start_version,
                   due_at, due_at + INTERVAL '15 minutes' AS deadline_at
            FROM candidates
            WHERE due_at < to_timestamp(meeting_start_ms::double precision / 1000)
            ORDER BY due_at, meeting_id, user_id, minutes
            LIMIT ?
            """.trimIndent(),
            ::mapCandidate,
            timestamp(now),
            timestamp(now),
            timestamp(now),
            limit,
        )
    }

    /**
     * Rechecks all mutable eligibility under the user/meeting locks and
     * inserts the unique claim. A non-null result means this transaction won
     * the claim race; only that winner snapshots installations.
     */
    fun discover(candidate: ReminderCandidate, now: Instant): ReminderClaimRecord? {
        val user = jdbc.query(
            """
            SELECT notifications_enabled, deleted_at
            FROM users WHERE id = ? FOR UPDATE
            """.trimIndent(),
            { rs, _ -> rs.getBoolean("notifications_enabled") to rs.getTimestamp("deleted_at") },
            candidate.userId,
        ).firstOrNull() ?: return null
        if (!user.first || user.second != null) return null

        val meeting = jdbc.query(
            """
            SELECT time, push_start_version, status
            FROM meetings WHERE id = ? FOR SHARE
            """.trimIndent(),
            { rs, _ -> Triple(rs.getLong("time"), rs.getLong("push_start_version"), rs.getString("status")) },
            candidate.meetingId,
        ).firstOrNull() ?: return null
        val due = candidate.dueAt
        val deadline = candidate.deadlineAt
        val currentDue = Instant.ofEpochMilli(meeting.first - candidate.offset.minutes * 60_000L)
        if (
            meeting.third != "ACTIVE" ||
            meeting.first <= now.toEpochMilli() ||
            meeting.first != candidate.meetingStartMs ||
            meeting.second != candidate.startVersion ||
            currentDue != due ||
            now.isBefore(due) ||
            now.isAfter(deadline)
        ) return null

        val issuedAt = now.truncatedTo(java.time.temporal.ChronoUnit.MILLIS)
        val claimId = UUID.randomUUID()
        val inserted = jdbc.query(
            """
            INSERT INTO meeting_reminder_claims
                (id, user_id, meeting_id, reminder_offset_minutes, meeting_start_ms,
                 start_version, due_at, deadline_at, issued_at, status, completed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', NULL)
            ON CONFLICT (user_id, meeting_id, reminder_offset_minutes) DO NOTHING
            RETURNING id
            """.trimIndent(),
            { rs, _ -> rs.getObject("id", UUID::class.java) },
            claimId,
            candidate.userId,
            candidate.meetingId,
            candidate.offset.minutes,
            candidate.meetingStartMs,
            candidate.startVersion,
            timestamp(due),
            timestamp(deadline),
            timestamp(issuedAt),
        ).firstOrNull() ?: return null

        val installations = jdbc.query(
            """
            SELECT id, user_id
            FROM push_installations
            WHERE user_id = ? AND status = 'ACTIVE' AND fid IS NOT NULL
              AND last_seen_at > ?::timestamptz - INTERVAL '35 days'
            ORDER BY id
            """.trimIndent(),
            { rs, _ -> rs.getObject("id", UUID::class.java) to rs.getLong("user_id") },
            candidate.userId,
            timestamp(now),
        )
        installations.forEach { (installationId, userId) ->
            jdbc.update(
                """
                INSERT INTO meeting_reminder_targets
                    (id, claim_id, user_id, installation_id, status, attempts, next_attempt_at,
                     lease_token, lease_until, reason, completed_at)
                VALUES (?, ?, ?, ?, 'PENDING', 0, ?, NULL, NULL, NULL, NULL)
                """.trimIndent(),
                UUID.randomUUID(),
                inserted,
                userId,
                installationId,
                timestamp(now),
            )
        }
        if (installations.isEmpty()) {
            jdbc.update(
                """
                UPDATE meeting_reminder_claims
                SET status = 'NO_TARGET', completed_at = ?
                WHERE id = ? AND status = 'PENDING'
                """.trimIndent(),
                timestamp(now),
                inserted,
            )
        }
        return ReminderClaimRecord(
            id = inserted,
            userId = candidate.userId,
            meetingId = candidate.meetingId,
            offset = candidate.offset,
            meetingStartMs = candidate.meetingStartMs,
            startVersion = candidate.startVersion,
            dueAt = due,
            deadlineAt = deadline,
            issuedAt = issuedAt,
            status = if (installations.isEmpty()) ReminderClaimStatus.NO_TARGET else ReminderClaimStatus.PENDING,
        )
    }

    fun setLockTimeout() {
        jdbc.execute("SET LOCAL lock_timeout = '2s'")
    }

    fun findClaim(id: UUID): ReminderClaimRecord? =
        jdbc.query(
            """
            SELECT id, user_id, meeting_id, reminder_offset_minutes, meeting_start_ms,
                   start_version, due_at, deadline_at, issued_at, status
            FROM meeting_reminder_claims WHERE id = ?
            """.trimIndent(),
            ::mapClaim,
            id,
        ).firstOrNull()

    private fun mapCandidate(rs: ResultSet, rowNum: Int): ReminderCandidate =
        ReminderCandidate(
            userId = rs.getLong("user_id"),
            meetingId = rs.getLong("meeting_id"),
            offset = ReminderOffset.fromMinutes(rs.getInt("minutes")),
            meetingStartMs = rs.getLong("meeting_start_ms"),
            startVersion = rs.getLong("push_start_version"),
            dueAt = rs.getTimestamp("due_at").toInstant(),
            deadlineAt = rs.getTimestamp("deadline_at").toInstant(),
        )

    private fun mapClaim(rs: ResultSet, rowNum: Int): ReminderClaimRecord =
        ReminderClaimRecord(
            id = rs.getObject("id", UUID::class.java),
            userId = rs.getLong("user_id"),
            meetingId = rs.getLong("meeting_id"),
            offset = ReminderOffset.fromMinutes(rs.getInt("reminder_offset_minutes")),
            meetingStartMs = rs.getLong("meeting_start_ms"),
            startVersion = rs.getLong("start_version"),
            dueAt = rs.getTimestamp("due_at").toInstant(),
            deadlineAt = rs.getTimestamp("deadline_at").toInstant(),
            issuedAt = rs.getTimestamp("issued_at").toInstant(),
            status = ReminderClaimStatus.valueOf(rs.getString("status")),
        )

    private companion object {
        fun timestamp(value: Instant): Timestamp = Timestamp.from(value)
    }
}
