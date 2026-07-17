package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.error.RateLimitException
import dev.whysoezzy.meet.config.OtpProperties
import dev.whysoezzy.meet.config.OtpRateLimitProperties
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.core.PreparedStatementCallback
import org.springframework.jdbc.core.PreparedStatementCreator
import org.springframework.stereotype.Service
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.LocalDateTime

@Service
class OtpRateLimiter(
    private val jdbcTemplate: JdbcTemplate,
    private val otpProperties: OtpProperties,
    private val rateLimitProperties: OtpRateLimitProperties,
) {
    fun claim(phone: String, context: OtpRequestContext) {
        val limits = buildList {
            add(RateLimitScope("phone", hash(phone), otpProperties.maxAttemptsPerHour))
            context.clientIp?.takeIf { it.isNotBlank() }?.let {
                add(RateLimitScope("ip", hash(it), rateLimitProperties.ipMaxAttempts))
            }
            if (rateLimitProperties.deviceEnabled) {
                context.userAgent?.takeIf { it.isNotBlank() }?.let {
                    add(RateLimitScope("device", hash(it), rateLimitProperties.deviceMaxAttempts))
                }
            }
        }.sortedBy { "${it.scope}:${it.key}" }

        limits.forEach { limit ->
            jdbcTemplate.execute(
                PreparedStatementCreator { connection ->
                    connection.prepareStatement(
                        "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))",
                    ).apply {
                        setString(1, "${limit.scope}:${limit.key}")
                    }
                },
                PreparedStatementCallback {
                    it.execute()
                    Unit
                },
            )
        }

        val cutoff = LocalDateTime.now().minusMinutes(rateLimitProperties.windowMinutes)
        limits.forEach { limit ->
            jdbcTemplate.update(
                "DELETE FROM otp_rate_limit_attempts WHERE scope = ? AND subject_key = ? AND attempted_at <= ?",
                limit.scope,
                limit.key,
                cutoff,
            )
        }

        if (limits.any { limit ->
                jdbcTemplate.queryForObject(
                    "SELECT COUNT(*) FROM otp_rate_limit_attempts WHERE scope = ? AND subject_key = ? AND attempted_at > ?",
                    Long::class.java,
                    limit.scope,
                    limit.key,
                    cutoff,
                ) >= limit.maxAttempts
            }
        ) {
            throw RateLimitException("Too many OTP requests. Please try again later.")
        }

        val attemptedAt = LocalDateTime.now()
        limits.forEach { limit ->
            jdbcTemplate.update(
                "INSERT INTO otp_rate_limit_attempts (scope, subject_key, attempted_at) VALUES (?, ?, ?)",
                limit.scope,
                limit.key,
                attemptedAt,
            )
        }
    }

    private fun hash(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(StandardCharsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    private data class RateLimitScope(val scope: String, val key: String, val maxAttempts: Long)
}
