package dev.whysoezzy.meet.service.auth.otp

import dev.whysoezzy.meet.service.auth.identifier.AuthChannel
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import dev.whysoezzy.meet.service.auth.identifier.DeviceId
import dev.whysoezzy.meet.service.auth.identifier.NormalizedIp
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.core.PreparedStatementCallback
import org.springframework.jdbc.core.PreparedStatementCreator
import org.springframework.jdbc.support.GeneratedKeyHolder
import org.springframework.stereotype.Component
import java.security.MessageDigest
import java.sql.ResultSet
import java.time.LocalDateTime
import java.util.HexFormat

@Component
class OtpIdentifierLock(
    private val jdbcTemplate: JdbcTemplate,
) {
    fun lock(identifier: AuthIdentifier) {
        jdbcTemplate.execute(
            PreparedStatementCreator { connection ->
                connection.prepareStatement(
                    "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))",
                ).apply {
                    setString(1, "$LOCK_NAMESPACE:${identifier.channel.name}:${identifier.canonicalValue}")
                }
            },
            PreparedStatementCallback {
                it.execute()
                Unit
            },
        )
    }

    private companion object {
        const val LOCK_NAMESPACE = "meet-otp-identifier-v1"
    }
}

@Component
class OtpChallengeStore(
    private val jdbcTemplate: JdbcTemplate,
) {
    internal fun insertPending(
        identifier: AuthIdentifier,
        material: OtpHashMaterial,
        expirationMinutes: Long,
        maxAttempts: Int,
    ): PendingChallenge {
        val keyHolder = GeneratedKeyHolder()
        jdbcTemplate.update(
            { connection ->
                connection.prepareStatement(
                    """
                    WITH sampled AS (
                        SELECT clock_timestamp()::timestamp AS now
                    )
                    INSERT INTO otp_codes (
                        identifier,
                        channel,
                        code_hash,
                        hash_salt,
                        hash_key_id,
                        status,
                        failed_attempts,
                        max_attempts,
                        expires_at,
                        created_at
                    )
                    SELECT ?, ?, ?, ?, ?, 'PENDING', 0, ?,
                        sampled.now + (? * INTERVAL '1 minute'),
                        sampled.now
                    FROM sampled
                    """.trimIndent(),
                    arrayOf("id"),
                ).apply {
                    setString(1, identifier.canonicalValue)
                    setString(2, identifier.channel.name)
                    setBytes(3, material.codeHash())
                    setBytes(4, material.salt())
                    setString(5, material.keyId)
                    setInt(6, maxAttempts)
                    setLong(7, expirationMinutes)
                }
            },
            keyHolder,
        )
        return PendingChallenge(requireNotNull(keyHolder.key).toLong())
    }

    fun findById(id: Long): OtpChallengeSnapshot? =
        jdbcTemplate.query(
            "$SELECT_COLUMNS FROM otp_codes WHERE id = ?",
            ::mapChallenge,
            id,
        ).firstOrNull()

    fun lockById(id: Long): OtpChallengeSnapshot? =
        jdbcTemplate.query(
            "$SELECT_COLUMNS FROM otp_codes WHERE id = ? FOR UPDATE",
            ::mapChallenge,
            id,
        ).firstOrNull()

    fun lockActive(identifier: AuthIdentifier): OtpChallengeSnapshot? =
        jdbcTemplate.query(
            """
            $SELECT_COLUMNS
            FROM otp_codes
            WHERE channel = ? AND identifier = ? AND status = 'ACTIVE'
            ORDER BY id DESC
            LIMIT 1
            FOR UPDATE
            """.trimIndent(),
            ::mapChallenge,
            identifier.channel.name,
            identifier.canonicalValue,
        ).firstOrNull()

    fun hasNewerRequest(challenge: OtpChallengeSnapshot): Boolean =
        jdbcTemplate.queryForObject(
            """
            SELECT EXISTS (
                SELECT 1
                FROM otp_codes
                WHERE channel = ? AND identifier = ? AND id > ?
            )
            """.trimIndent(),
            Boolean::class.java,
            challenge.channel.name,
            challenge.identifier,
            challenge.id,
        ) ?: error("OTP challenge existence query returned no result")

    fun isPendingAndUnexpired(id: Long): Boolean =
        jdbcTemplate.queryForObject(
            """
            SELECT EXISTS (
                SELECT 1 FROM otp_codes
                WHERE id = ? AND status = 'PENDING' AND expires_at > clock_timestamp()
            )
            """.trimIndent(),
            Boolean::class.java,
            id,
        ) ?: error("OTP pending challenge query returned no result")

    fun isActiveAndUnexpired(id: Long): Boolean =
        jdbcTemplate.queryForObject(
            """
            SELECT EXISTS (
                SELECT 1 FROM otp_codes
                WHERE id = ? AND status = 'ACTIVE'
                  AND failed_attempts < max_attempts
                  AND expires_at > clock_timestamp()
            )
            """.trimIndent(),
            Boolean::class.java,
            id,
        ) ?: error("OTP active challenge query returned no result")

    fun supersedeActive(challenge: OtpChallengeSnapshot): Int =
        jdbcTemplate.update(
            """
            UPDATE otp_codes
            SET status = 'SUPERSEDED'
            WHERE channel = ? AND identifier = ? AND status = 'ACTIVE' AND id <> ?
            """.trimIndent(),
            challenge.channel.name,
            challenge.identifier,
            challenge.id,
        )

    fun activatePending(id: Long): Boolean =
        jdbcTemplate.update(
            """
            UPDATE otp_codes
            SET status = 'ACTIVE', activated_at = clock_timestamp()
            WHERE id = ? AND status = 'PENDING' AND expires_at > clock_timestamp()
            """.trimIndent(),
            id,
        ) == 1

    fun markPending(id: Long, status: OtpChallengeStatus): Boolean {
        require(
            status in setOf(
                OtpChallengeStatus.DELIVERY_FAILED,
                OtpChallengeStatus.SUPERSEDED,
                OtpChallengeStatus.EXPIRED,
            ),
        )
        return jdbcTemplate.update(
            "UPDATE otp_codes SET status = ? WHERE id = ? AND status = 'PENDING'",
            status.name,
            id,
        ) == 1
    }

    fun expireActiveIfNeeded(id: Long): Boolean =
        jdbcTemplate.update(
            """
            UPDATE otp_codes
            SET status = 'EXPIRED'
            WHERE id = ? AND status = 'ACTIVE' AND expires_at <= clock_timestamp()
            """.trimIndent(),
            id,
        ) == 1

    fun recordMismatch(id: Long): Boolean =
        jdbcTemplate.update(
            """
            UPDATE otp_codes
            SET failed_attempts = failed_attempts + 1,
                status = CASE
                    WHEN failed_attempts + 1 >= max_attempts THEN 'EXHAUSTED'
                    ELSE 'ACTIVE'
                END
            WHERE id = ? AND status = 'ACTIVE'
              AND failed_attempts < max_attempts
              AND expires_at > clock_timestamp()
            """.trimIndent(),
            id,
        ) == 1

    fun consume(id: Long): Boolean =
        jdbcTemplate.update(
            """
            UPDATE otp_codes
            SET status = 'CONSUMED', consumed_at = clock_timestamp()
            WHERE id = ? AND status = 'ACTIVE'
              AND failed_attempts < max_attempts
              AND expires_at > clock_timestamp()
            """.trimIndent(),
            id,
        ) == 1

    fun cleanup(retentionHours: Long, batchSize: Int): Int =
        jdbcTemplate.update(
            CLEANUP_SQL,
            retentionHours,
            batchSize,
        )

    private fun mapChallenge(resultSet: ResultSet, @Suppress("UNUSED_PARAMETER") row: Int) =
        OtpChallengeSnapshot(
            id = resultSet.getLong("id"),
            channel = AuthChannel.valueOf(resultSet.getString("channel")),
            identifier = resultSet.getString("identifier"),
            codeHash = resultSet.getBytes("code_hash"),
            hashSalt = resultSet.getBytes("hash_salt"),
            hashKeyId = resultSet.getString("hash_key_id"),
            status = OtpChallengeStatus.valueOf(resultSet.getString("status")),
            failedAttempts = resultSet.getInt("failed_attempts"),
            maxAttempts = resultSet.getInt("max_attempts"),
            expiresAt = resultSet.getObject("expires_at", LocalDateTime::class.java),
        )

    companion object {
        private const val SELECT_COLUMNS =
            "SELECT id, channel, identifier, code_hash, hash_salt, hash_key_id, status, " +
                "failed_attempts, max_attempts, expires_at"

        internal val CLEANUP_SQL: String =
            """
            WITH eligible AS (
                SELECT id
                FROM otp_codes
                WHERE expires_at <= (
                    SELECT clock_timestamp() - (? * INTERVAL '1 hour')
                )
                ORDER BY expires_at, id
                LIMIT ?
                FOR UPDATE SKIP LOCKED
            )
            DELETE FROM otp_codes
            WHERE id IN (SELECT id FROM eligible)
            """.trimIndent()
    }
}

@Component
class OtpAttemptStore(
    private val jdbcTemplate: JdbcTemplate,
) {
    internal fun requestIdentifier(identifier: AuthIdentifier, maxAttempts: Long): AttemptLimit =
        limit(identifier.channel.name.lowercase(), identifier.canonicalValue, maxAttempts)

    internal fun requestIp(ip: NormalizedIp, maxAttempts: Long): AttemptLimit =
        limit("ip", ip.value, maxAttempts)

    internal fun requestDevice(deviceId: DeviceId, maxAttempts: Long): AttemptLimit =
        limit("device", deviceId.value, maxAttempts)

    internal fun verificationIdentifier(identifier: AuthIdentifier, maxAttempts: Long): AttemptLimit =
        limit("verify_${identifier.channel.name.lowercase()}", identifier.canonicalValue, maxAttempts)

    internal fun verificationIp(ip: NormalizedIp, maxAttempts: Long): AttemptLimit =
        limit("verify_ip", ip.value, maxAttempts)

    internal fun verificationDevice(deviceId: DeviceId, maxAttempts: Long): AttemptLimit =
        limit("verify_device", deviceId.value, maxAttempts)

    internal fun lock(limits: Collection<AttemptLimit>) {
        limits.sortedBy { "${it.scope}:${it.key}" }.forEach { limit ->
            jdbcTemplate.execute(
                PreparedStatementCreator { connection ->
                    connection.prepareStatement(
                        "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))",
                    ).apply {
                        setString(1, "$LOCK_NAMESPACE:${limit.scope}:${limit.key}")
                    }
                },
                PreparedStatementCallback {
                    it.execute()
                    Unit
                },
            )
        }
    }

    internal fun isExhausted(limits: Collection<AttemptLimit>, windowMinutes: Long): Boolean =
        limits.any { limit ->
            jdbcTemplate.queryForObject(
                """
                SELECT COUNT(*)
                FROM otp_rate_limit_attempts
                WHERE scope = ? AND subject_key = ?
                  AND attempted_at > clock_timestamp() - (? * INTERVAL '1 minute')
                """.trimIndent(),
                Long::class.java,
                limit.scope,
                limit.key,
                windowMinutes,
            ) ?: error("OTP rate limit count query returned no result") >= limit.maxAttempts
        }

    internal fun insert(limits: Collection<AttemptLimit>) {
        limits.forEach { limit ->
            jdbcTemplate.update(
                """
                INSERT INTO otp_rate_limit_attempts (scope, subject_key, attempted_at)
                VALUES (?, ?, clock_timestamp())
                """.trimIndent(),
                limit.scope,
                limit.key,
            )
        }
    }

    fun cleanup(maxWindowMinutes: Long, batchSize: Int): Int =
        jdbcTemplate.update(
            """
            WITH eligible AS (
                SELECT id
                FROM otp_rate_limit_attempts
                WHERE attempted_at <= clock_timestamp() - (? * INTERVAL '1 minute')
                ORDER BY attempted_at, id
                LIMIT ?
                FOR UPDATE SKIP LOCKED
            )
            DELETE FROM otp_rate_limit_attempts
            WHERE id IN (SELECT id FROM eligible)
            """.trimIndent(),
            maxWindowMinutes,
            batchSize,
        )

    private fun hash(value: String): String =
        HexFormat.of().formatHex(
            MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)),
        )

    private fun limit(scope: String, rawSubject: String, maxAttempts: Long): AttemptLimit =
        AttemptLimit(scope, hash(rawSubject), maxAttempts)

    private companion object {
        const val LOCK_NAMESPACE = "meet-otp-attempt-v1"
    }
}
