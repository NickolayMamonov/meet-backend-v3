package dev.whysoezzy.meet.service.push

import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Component
import java.sql.ResultSet
import java.sql.Timestamp
import java.time.Instant
import java.util.UUID

data class PushInstallationRecord(
    val id: UUID,
    val userId: Long,
    val fid: Fid?,
    val status: InstallationStatus,
    val registrationVersion: Long,
    val createdAt: Instant,
    val updatedAt: Instant,
    val lastSeenAt: Instant,
    val terminalAt: Instant?,
)

@Component
class PushInstallationStore(
    private val jdbc: JdbcTemplate,
) {
    fun setLockTimeout() {
        jdbc.execute("SET LOCAL lock_timeout = '2s'")
    }

    fun findById(id: UUID, forUpdate: Boolean = false): PushInstallationRecord? =
        jdbc.query(
            "$COLUMNS FROM push_installations WHERE id = ?${if (forUpdate) " FOR UPDATE" else ""}",
            ::map,
            id,
        ).firstOrNull()

    fun findByFid(fid: Fid, forUpdate: Boolean = false): PushInstallationRecord? =
        jdbc.query(
            "$COLUMNS FROM push_installations WHERE fid = ? AND status = 'ACTIVE'${if (forUpdate) " FOR UPDATE" else ""}",
            ::map,
            fid.value,
        ).firstOrNull()

    fun findByUser(userId: Long, forUpdate: Boolean = false): List<PushInstallationRecord> =
        jdbc.query(
            "$COLUMNS FROM push_installations WHERE user_id = ? ORDER BY id${if (forUpdate) " FOR UPDATE" else ""}",
            ::map,
            userId,
        )

    fun findActiveFreshByUser(userId: Long, now: Instant, forUpdate: Boolean = false): List<PushInstallationRecord> =
        jdbc.query(
            """
            $COLUMNS
            FROM push_installations
            WHERE user_id = ? AND status = 'ACTIVE' AND fid IS NOT NULL
              AND last_seen_at > ?::timestamptz - INTERVAL '35 days'
            ORDER BY id
            ${if (forUpdate) "FOR UPDATE" else ""}
            """.trimIndent(),
            ::map,
            userId,
            timestamp(now),
        )

    fun ownerIdsForFid(fid: Fid): List<Long> =
        jdbc.queryForList(
            "SELECT user_id FROM push_installations WHERE fid = ? AND status = 'ACTIVE' ORDER BY user_id",
            Long::class.java,
            fid.value,
        )

    fun lockUser(userId: Long) {
        jdbc.queryForList("SELECT id FROM users WHERE id = ? FOR UPDATE", Long::class.java, userId)
    }

    fun insert(
        id: UUID,
        userId: Long,
        fid: Fid,
        now: Instant,
    ): PushInstallationRecord {
        jdbc.update(
            """
            INSERT INTO push_installations
                (id, user_id, fid, status, registration_version, created_at, updated_at, last_seen_at, terminal_at)
            VALUES (?, ?, ?, 'ACTIVE', 1, ?, ?, ?, NULL)
            """.trimIndent(),
            id,
            userId,
            fid.value,
            timestamp(now),
            timestamp(now),
            timestamp(now),
        )
        return requireNotNull(findById(id))
    }

    fun heartbeat(id: UUID, userId: Long, now: Instant): PushInstallationRecord? {
        jdbc.update(
            """
            UPDATE push_installations
            SET updated_at = ?, last_seen_at = ?
            WHERE id = ? AND user_id = ? AND status = 'ACTIVE' AND fid IS NOT NULL
            """.trimIndent(),
            timestamp(now),
            timestamp(now),
            id,
            userId,
        )
        return findById(id)
    }

    fun activate(id: UUID, userId: Long, fid: Fid, now: Instant): PushInstallationRecord? {
        jdbc.update(
            """
            UPDATE push_installations
            SET fid = ?, status = 'ACTIVE', registration_version = registration_version + 1,
                updated_at = ?, last_seen_at = ?, terminal_at = NULL
            WHERE id = ? AND user_id = ?
              AND status IN ('ACTIVE', 'UNREGISTERED', 'INVALID', 'EXPIRED')
            """.trimIndent(),
            fid.value,
            timestamp(now),
            timestamp(now),
            id,
            userId,
        )
        return findById(id)
    }

    fun transfer(id: UUID, now: Instant): Int =
        jdbc.update(
            """
            UPDATE push_installations
            SET fid = NULL, status = 'TRANSFERRED', registration_version = registration_version + 1,
                updated_at = ?, terminal_at = ?
            WHERE id = ? AND status = 'ACTIVE'
            """.trimIndent(),
            timestamp(now),
            timestamp(now),
            id,
        )

    fun unregister(id: UUID, userId: Long, now: Instant): Boolean =
        jdbc.update(
            """
            UPDATE push_installations
            SET fid = NULL, status = CASE WHEN status = 'TRANSFERRED' THEN status ELSE 'UNREGISTERED' END,
                registration_version = CASE WHEN status = 'TRANSFERRED' THEN registration_version
                                            ELSE registration_version + 1 END,
                updated_at = ?, terminal_at = CASE WHEN status = 'TRANSFERRED' THEN terminal_at ELSE ? END
            WHERE id = ? AND user_id = ? AND status <> 'TRANSFERRED'
            """.trimIndent(),
            timestamp(now),
            timestamp(now),
            id,
            userId,
        ) > 0

    fun markAccountDeleted(userId: Long, now: Instant): Int =
        jdbc.update(
            """
            UPDATE push_installations
            SET fid = NULL, status = 'ACCOUNT_DELETED', registration_version = registration_version + 1,
                updated_at = ?, terminal_at = ?
            WHERE user_id = ? AND status = 'ACTIVE'
            """.trimIndent(),
            timestamp(now),
            timestamp(now),
            userId,
        )

    fun invalidateExact(
        id: UUID,
        userId: Long,
        registrationVersion: Long,
        fid: Fid,
        now: Instant,
    ): Boolean =
        jdbc.update(
            """
            UPDATE push_installations
            SET fid = NULL, status = 'UNREGISTERED', registration_version = registration_version + 1,
                updated_at = ?, terminal_at = ?
            WHERE id = ? AND user_id = ? AND status = 'ACTIVE'
              AND registration_version = ? AND fid = ?
            """.trimIndent(),
            timestamp(now),
            timestamp(now),
            id,
            userId,
            registrationVersion,
            fid.value,
        ) > 0

    fun expireStale(now: Instant, limit: Int = 100): Int =
        run {
            require(limit > 0)
            jdbc.execute("SET LOCAL lock_timeout = '2s'")
            val candidates = jdbc.query(
                """
                SELECT id, user_id
                FROM push_installations
                WHERE status = 'ACTIVE' AND last_seen_at <= ?::timestamptz - INTERVAL '35 days'
                ORDER BY last_seen_at, id
                LIMIT ?
                """.trimIndent(),
                { rs, _ -> rs.getObject("id", UUID::class.java) to rs.getLong("user_id") },
                timestamp(now),
                limit,
            )
            candidates.map { it.second }.distinct().sorted().forEach(::lockUser)
            candidates.count { (id) ->
                jdbc.update(
                    """
                    UPDATE push_installations
                    SET fid = NULL, status = 'EXPIRED', registration_version = registration_version + 1,
                        updated_at = ?, terminal_at = ?
                    WHERE id = ? AND status = 'ACTIVE'
                      AND last_seen_at <= ?::timestamptz - INTERVAL '35 days'
                    """.trimIndent(),
                    timestamp(now),
                    timestamp(now),
                    id,
                    timestamp(now),
                ) > 0
            }
        }

    private fun map(rs: ResultSet, rowNum: Int): PushInstallationRecord =
        PushInstallationRecord(
            id = rs.getObject("id", UUID::class.java),
            userId = rs.getLong("user_id"),
            fid = rs.getString("fid")?.let(::parseFid),
            status = InstallationStatus.valueOf(rs.getString("status")),
            registrationVersion = rs.getLong("registration_version"),
            createdAt = rs.getTimestamp("created_at").toInstant(),
            updatedAt = rs.getTimestamp("updated_at").toInstant(),
            lastSeenAt = rs.getTimestamp("last_seen_at").toInstant(),
            terminalAt = rs.getTimestamp("terminal_at")?.toInstant(),
        )

    private companion object {
        const val COLUMNS = """
            SELECT id, user_id, fid, status, registration_version,
                   created_at, updated_at, last_seen_at, terminal_at
        """

        fun timestamp(value: Instant): Timestamp = Timestamp.from(value)
    }
}
