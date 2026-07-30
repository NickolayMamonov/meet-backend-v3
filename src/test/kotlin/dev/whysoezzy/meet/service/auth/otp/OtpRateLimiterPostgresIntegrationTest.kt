package dev.whysoezzy.meet.service.auth.otp

import dev.whysoezzy.meet.config.OtpProperties
import dev.whysoezzy.meet.config.OtpRateLimitProperties
import dev.whysoezzy.meet.service.OtpRequestContext
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import dev.whysoezzy.meet.service.auth.identifier.DeviceId
import dev.whysoezzy.meet.service.auth.identifier.IpLiteralParser
import dev.whysoezzy.meet.support.PostgresTestDatabase
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.junit.jupiter.api.assertThrows
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.datasource.DataSourceTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals

@Tag("postgres")
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class OtpRateLimiterPostgresIntegrationTest {
    private lateinit var database: PostgresTestDatabase
    private lateinit var jdbc: JdbcTemplate
    private lateinit var transactionManager: DataSourceTransactionManager
    private lateinit var attemptStore: OtpAttemptStore

    @BeforeAll
    fun startDatabase() {
        database = PostgresTestDatabase("otp_rate_limit")
        val dataSource = database.dataSource()
        jdbc = JdbcTemplate(dataSource)
        transactionManager = DataSourceTransactionManager(dataSource)
        attemptStore = OtpAttemptStore(jdbc)
        jdbc.execute(
            """
            CREATE TABLE otp_rate_limit_attempts (
                id BIGSERIAL PRIMARY KEY,
                scope VARCHAR(16) NOT NULL,
                subject_key CHAR(64) NOT NULL,
                attempted_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """.trimIndent(),
        )
    }

    @AfterAll
    fun stopDatabase() = database.close()

    @BeforeEach
    fun clearAttempts() {
        jdbc.execute("TRUNCATE otp_rate_limit_attempts RESTART IDENTITY")
    }

    @Test
    fun `enforces channel identifier aggregate IP and enabled device scopes`() {
        val limiter = limiter(identifierMax = 2, ipMax = 2, deviceMax = 2)

        limiter.claim(AuthIdentifier.phone("+15550000001"), context("10.0.0.1", "device-id-000001"))
        limiter.claim(AuthIdentifier.phone("+15550000001"), context("10.0.0.2", "device-id-000002"))
        assertThrows<OtpRequestRateLimitExceeded> {
            limiter.claim(AuthIdentifier.phone("+15550000001"), context("10.0.0.3", "device-id-000003"))
        }

        clearAttempts()
        limiter.claim(AuthIdentifier.phone("+15550000001"), context("10.0.0.1", "device-id-000001"))
        limiter.claim(AuthIdentifier.email("one@example.com"), context("10.0.0.1", "device-id-000002"))
        assertThrows<OtpRequestRateLimitExceeded> {
            limiter.claim(AuthIdentifier.email("two@example.com"), context("10.0.0.1", "device-id-000003"))
        }

        clearAttempts()
        limiter.claim(AuthIdentifier.phone("+15550000001"), context("10.0.0.1", "device-id-shared1"))
        limiter.claim(AuthIdentifier.email("one@example.com"), context("10.0.0.2", "device-id-shared1"))
        assertThrows<OtpRequestRateLimitExceeded> {
            limiter.claim(AuthIdentifier.email("two@example.com"), context("10.0.0.3", "device-id-shared1"))
        }
    }

    @Test
    fun `allows exactly the configured number of concurrent claims`() {
        val limiter = limiter(identifierMax = 3, ipMax = 100, deviceMax = 100)
        val executor = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        try {
            val results = (1..8).map { index ->
                executor.submit(
                    Callable<Throwable?> {
                        start.await()
                        runCatching {
                            limiter.claim(
                                AuthIdentifier.email("person@example.com"),
                                context("10.0.0.$index", "device-id-00000$index"),
                            )
                        }.exceptionOrNull()
                    },
                )
            }
            start.countDown()
            val failures = results.map { it.get(15, TimeUnit.SECONDS) }

            assertEquals(3, failures.count { it == null })
            assertEquals(5, failures.count { it is OtpRequestRateLimitExceeded })
            assertEquals(
                3L,
                jdbc.queryForObject(
                    "SELECT COUNT(*) FROM otp_rate_limit_attempts WHERE scope = 'email'",
                    Long::class.java,
                ),
            )
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `concurrent request boundaries cover phone identifier aggregate IP and enabled device`() {
        assertConcurrentRequestBoundary(
            scope = "phone",
            limiter = limiter(identifierMax = 3, ipMax = 100, deviceMax = 100),
        ) { index ->
            AuthIdentifier.phone("+15550000001") to context("10.0.1.$index", "phone-device-000$index")
        }

        clearAttempts()
        assertConcurrentRequestBoundary(
            scope = "ip",
            limiter = limiter(identifierMax = 100, ipMax = 3, deviceMax = 100),
        ) { index ->
            AuthIdentifier.email("ip-$index@example.com") to context("10.0.2.1", "request-device-000$index")
        }

        clearAttempts()
        assertConcurrentRequestBoundary(
            scope = "device",
            limiter = limiter(identifierMax = 100, ipMax = 100, deviceMax = 3),
        ) { index ->
            AuthIdentifier.email("device-$index@example.com") to context("10.0.3.$index", "shared-device-id")
        }
    }

    @Test
    fun `concurrent verification boundaries cover identifier IP and enabled device`() {
        assertConcurrentAttemptBoundary(
            attemptStore.verificationIdentifier(AuthIdentifier.email("person@example.com"), 3),
        )
        assertConcurrentAttemptBoundary(
            attemptStore.verificationIp(requireNotNull(IpLiteralParser.parse("10.0.4.1")), 3),
        )
        assertConcurrentAttemptBoundary(
            attemptStore.verificationDevice(requireNotNull(DeviceId.parse("verify-device-id")), 3),
        )

        assertEquals(
            listOf(
                "verify_device" to 3L,
                "verify_email" to 3L,
                "verify_ip" to 3L,
            ),
            jdbc.query(
                """
                SELECT scope, COUNT(*) AS attempt_count
                FROM otp_rate_limit_attempts
                GROUP BY scope
                ORDER BY scope
                """.trimIndent(),
            ) { row, _ -> row.getString("scope") to row.getLong("attempt_count") },
        )
    }

    @Test
    fun `uses PostgreSQL window time and leaves cleanup to the bounded cleanup path`() {
        jdbc.update(
            """
            INSERT INTO otp_rate_limit_attempts (scope, subject_key, attempted_at)
            VALUES ('email', ?, clock_timestamp() - INTERVAL '61 minutes')
            """.trimIndent(),
            attemptStore.requestIdentifier(AuthIdentifier.email("person@example.com"), 1).key,
        )

        limiter(identifierMax = 1).claim(
            AuthIdentifier.email("person@example.com"),
            context("10.0.0.1", "device-id-000001"),
        )
        assertEquals(4L, jdbc.queryForObject("SELECT COUNT(*) FROM otp_rate_limit_attempts", Long::class.java))

        assertEquals(1, attemptStore.cleanup(maxWindowMinutes = 60, batchSize = 1))
        assertEquals(3L, jdbc.queryForObject("SELECT COUNT(*) FROM otp_rate_limit_attempts", Long::class.java))
    }

    @Test
    fun `request claims commit before an enclosing downstream transaction rolls back`() {
        val limiter = limiter(identifierMax = 5, ipMax = 5, deviceMax = 5)

        assertThrows<IllegalStateException> {
            TransactionTemplate(transactionManager).executeWithoutResult {
                limiter.claim(
                    AuthIdentifier.email("person@example.com"),
                    context("10.0.0.1", "device-id-000001"),
                )
                throw IllegalStateException("simulated downstream failure")
            }
        }

        assertEquals(3L, jdbc.queryForObject("SELECT COUNT(*) FROM otp_rate_limit_attempts", Long::class.java))
    }

    @Test
    fun `attempt lock wait uses the post-wait PostgreSQL window boundary`() {
        val identifier = AuthIdentifier.email("person@example.com")
        val limit = attemptStore.requestIdentifier(identifier, 1)
        jdbc.update(
            """
            INSERT INTO otp_rate_limit_attempts (scope, subject_key, attempted_at)
            VALUES (?, ?, clock_timestamp() - INTERVAL '59.5 seconds')
            """.trimIndent(),
            limit.scope,
            limit.key,
        )
        val lockHeld = CountDownLatch(1)
        val releaseLock = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val holder = executor.submit {
                TransactionTemplate(transactionManager).executeWithoutResult {
                    attemptStore.lock(listOf(limit))
                    lockHeld.countDown()
                    releaseLock.await(5, TimeUnit.SECONDS)
                }
            }
            lockHeld.await(5, TimeUnit.SECONDS)
            val claim = executor.submit {
                limiter(identifierMax = 1, windowMinutes = 1)
                    .claim(identifier, OtpRequestContext.EMPTY)
            }
            Thread.sleep(1_200)
            releaseLock.countDown()

            claim.get(5, TimeUnit.SECONDS)
            holder.get(5, TimeUnit.SECONDS)
        } finally {
            releaseLock.countDown()
            executor.shutdownNow()
        }

        assertEquals(2L, jdbc.queryForObject("SELECT COUNT(*) FROM otp_rate_limit_attempts", Long::class.java))
    }

    private fun limiter(
        identifierMax: Long = 10,
        ipMax: Long = 10,
        deviceMax: Long = 10,
        windowMinutes: Long = 60,
    ) = OtpRequestRateLimiter(
        attemptStore = attemptStore,
        otpProperties = OtpProperties(maxAttemptsPerHour = identifierMax),
        rateLimitProperties = OtpRateLimitProperties(
            windowMinutes = windowMinutes,
            ipMaxAttempts = ipMax,
            deviceEnabled = true,
            deviceMaxAttempts = deviceMax,
        ),
        transactionManager = transactionManager,
    )

    private fun assertConcurrentRequestBoundary(
        scope: String,
        limiter: OtpRequestRateLimiter,
        claim: (Int) -> Pair<AuthIdentifier, OtpRequestContext>,
    ) {
        val failures = concurrentFailures { index ->
            val (identifier, requestContext) = claim(index)
            limiter.claim(identifier, requestContext)
        }
        assertEquals(3, failures.count { it == null })
        assertEquals(5, failures.count { it is OtpRequestRateLimitExceeded })
        assertEquals(
            3L,
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM otp_rate_limit_attempts WHERE scope = ?",
                Long::class.java,
                scope,
            ),
        )
    }

    private fun assertConcurrentAttemptBoundary(limit: AttemptLimit) {
        val failures = concurrentFailures {
            TransactionTemplate(transactionManager).executeWithoutResult {
                attemptStore.lock(listOf(limit))
                if (attemptStore.isExhausted(listOf(limit), 15)) {
                    throw OtpRequestRateLimitExceeded()
                }
                attemptStore.insert(listOf(limit))
            }
        }
        assertEquals(3, failures.count { it == null })
        assertEquals(5, failures.count { it is OtpRequestRateLimitExceeded })
    }

    private fun concurrentFailures(action: (Int) -> Unit): List<Throwable?> {
        val executor = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        return try {
            val results = (1..8).map { index ->
                executor.submit(
                    Callable<Throwable?> {
                        start.await()
                        runCatching { action(index) }.exceptionOrNull()
                    },
                )
            }
            start.countDown()
            results.map { it.get(15, TimeUnit.SECONDS) }
        } finally {
            executor.shutdownNow()
        }
    }

    private fun context(ip: String, device: String) =
        OtpRequestContext(
            clientIp = requireNotNull(IpLiteralParser.parse(ip)),
            deviceId = requireNotNull(DeviceId.parse(device)),
        )
}
