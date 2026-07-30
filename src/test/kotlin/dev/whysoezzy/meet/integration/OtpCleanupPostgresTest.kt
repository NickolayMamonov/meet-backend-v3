package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.service.OtpRequestContext
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import dev.whysoezzy.meet.service.auth.identifier.IpLiteralParser
import dev.whysoezzy.meet.service.auth.otp.OtpAttemptStore
import dev.whysoezzy.meet.service.auth.otp.OtpChallengeStore
import dev.whysoezzy.meet.service.auth.otp.OtpRequestRateLimiter
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals

class OtpCleanupPostgresTest(
    @Autowired private val challengeStore: OtpChallengeStore,
    @Autowired private val attemptStore: OtpAttemptStore,
    @Autowired private val requestRateLimiter: OtpRequestRateLimiter,
    @Autowired private val transactionManager: PlatformTransactionManager,
) : IntegrationTestSupport() {
    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `cleanup uses bounded PostgreSQL SKIP LOCKED batches and retains live rows`() {
        repeat(2) { index ->
            insertChallenge("old-$index@example.com", "clock_timestamp() - INTERVAL '25 hours'")
        }
        insertChallenge("live@example.com", "clock_timestamp() - INTERVAL '1 hour'")
        repeat(2) { index ->
            jdbcTemplate.update(
                """
                INSERT INTO otp_rate_limit_attempts (scope, subject_key, attempted_at)
                VALUES ('ip', LPAD(CAST(? AS TEXT), 64, '0'), clock_timestamp() - INTERVAL '61 minutes')
                """.trimIndent(),
                index,
            )
        }
        jdbcTemplate.update(
            """
            INSERT INTO otp_rate_limit_attempts (scope, subject_key, attempted_at)
            VALUES ('ip', ?, clock_timestamp())
            """.trimIndent(),
            "f".repeat(64),
        )

        TransactionTemplate(transactionManager).executeWithoutResult {
            assertEquals(1, challengeStore.cleanup(retentionHours = 24, batchSize = 1))
            assertEquals(1, attemptStore.cleanup(maxWindowMinutes = 60, batchSize = 1))
        }

        assertEquals(2L, jdbcTemplate.queryForObject("SELECT COUNT(*) FROM otp_codes", Long::class.java))
        assertEquals(
            1L,
            jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM otp_codes WHERE identifier = 'live@example.com'",
                Long::class.java,
            ),
        )
        assertEquals(2L, jdbcTemplate.queryForObject("SELECT COUNT(*) FROM otp_rate_limit_attempts", Long::class.java))
    }

    @Test
    fun `crossed stale rows do not deadlock disjoint claims with concurrent cleanup`() {
        val firstIdentifier = AuthIdentifier.email("first@example.com")
        val secondIdentifier = AuthIdentifier.email("second@example.com")
        val firstContext = context("198.51.100.1")
        val secondContext = context("198.51.100.2")
        val firstIdentifierLimit = attemptStore.requestIdentifier(firstIdentifier, 10)
        val secondIdentifierLimit = attemptStore.requestIdentifier(secondIdentifier, 10)
        val firstIpLimit = attemptStore.requestIp(requireNotNull(firstContext.clientIp), 20)
        val secondIpLimit = attemptStore.requestIp(requireNotNull(secondContext.clientIp), 20)

        listOf(
            firstIdentifierLimit,
            secondIpLimit,
            secondIdentifierLimit,
            firstIpLimit,
        ).forEachIndexed { index, limit ->
            jdbcTemplate.update(
                """
                INSERT INTO otp_rate_limit_attempts (scope, subject_key, attempted_at)
                VALUES (?, ?, clock_timestamp() - INTERVAL '2 hours' - (? * INTERVAL '1 second'))
                """.trimIndent(),
                limit.scope,
                limit.key,
                index,
            )
        }

        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(3)
        try {
            val firstClaim = executor.submit {
                start.await()
                requestRateLimiter.claim(firstIdentifier, firstContext)
            }
            val secondClaim = executor.submit {
                start.await()
                requestRateLimiter.claim(secondIdentifier, secondContext)
            }
            val cleanup = executor.submit<Int> {
                start.await()
                attemptStore.cleanup(maxWindowMinutes = 60, batchSize = 4)
            }
            start.countDown()

            firstClaim.get(10, TimeUnit.SECONDS)
            secondClaim.get(10, TimeUnit.SECONDS)
            assertEquals(4, cleanup.get(10, TimeUnit.SECONDS))
        } finally {
            executor.shutdownNow()
        }

        assertEquals(
            0L,
            jdbcTemplate.queryForObject(
                """
                SELECT COUNT(*) FROM otp_rate_limit_attempts
                WHERE attempted_at <= clock_timestamp() - INTERVAL '60 minutes'
                """.trimIndent(),
                Long::class.java,
            ),
        )
        assertEquals(4L, jdbcTemplate.queryForObject("SELECT COUNT(*) FROM otp_rate_limit_attempts", Long::class.java))
    }

    private fun insertChallenge(identifier: String, expiresExpression: String) {
        jdbcTemplate.update(
            """
            INSERT INTO otp_codes (
                identifier, channel, code_hash, hash_salt, hash_key_id, status,
                failed_attempts, max_attempts, expires_at, created_at
            )
            VALUES (
                ?, 'EMAIL', decode(?, 'hex'), decode(?, 'hex'), 'test-current', 'CONSUMED',
                0, 5, $expiresExpression, clock_timestamp()
            )
            """.trimIndent(),
            identifier,
            "01".repeat(32),
            "02".repeat(16),
        )
    }

    private fun context(ip: String) =
        OtpRequestContext(
            clientIp = requireNotNull(IpLiteralParser.parse(ip)),
            deviceId = null,
        )
}
