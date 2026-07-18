package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.error.RateLimitException
import dev.whysoezzy.meet.config.OtpProperties
import dev.whysoezzy.meet.config.OtpRateLimitProperties
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assumptions
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.junit.jupiter.api.assertThrows
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.datasource.DataSourceTransactionManager
import org.springframework.jdbc.datasource.DriverManagerDataSource
import org.springframework.transaction.support.TransactionTemplate
import org.testcontainers.containers.PostgreSQLContainer
import java.time.LocalDateTime
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals

@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class OtpRateLimiterPostgresIntegrationTest {
    private lateinit var dataSource: DriverManagerDataSource
    private lateinit var jdbcTemplate: JdbcTemplate
    private var container: PostgreSQLContainer<Nothing>? = null
    private var externalAdmin: JdbcTemplate? = null
    private var externalSchema: String? = null

    @BeforeAll
    fun startDatabase() {
        val externalUrl = System.getenv("TEST_POSTGRES_JDBC_URL")
        if (externalUrl != null) {
            val username = System.getenv("TEST_POSTGRES_USERNAME")
                ?: error("TEST_POSTGRES_USERNAME is required with TEST_POSTGRES_JDBC_URL")
            val password = System.getenv("TEST_POSTGRES_PASSWORD")
                ?: error("TEST_POSTGRES_PASSWORD is required with TEST_POSTGRES_JDBC_URL")
            val schema = "otp_rate_limit_test_${UUID.randomUUID().toString().replace("-", "")}"
            externalAdmin = JdbcTemplate(DriverManagerDataSource(externalUrl, username, password)).also {
                it.execute("CREATE SCHEMA $schema")
            }
            externalSchema = schema
            val separator = if (externalUrl.contains("?")) "&" else "?"
            dataSource = DriverManagerDataSource(
                "$externalUrl${separator}currentSchema=$schema",
                username,
                password,
            )
            return
        }

        val postgres = PostgreSQLContainer<Nothing>("postgres:16-alpine")
        try {
            postgres.start()
        } catch (exception: Exception) {
            Assumptions.assumeTrue(false, "Docker is unavailable: ${exception.message}")
            return
        }
        container = postgres
        dataSource = DriverManagerDataSource(postgres.jdbcUrl, postgres.username, postgres.password)
    }

    @AfterAll
    fun stopDatabase() {
        externalSchema?.let { schema ->
            externalAdmin?.execute("DROP SCHEMA $schema CASCADE")
        }
        container?.stop()
    }

    @BeforeEach
    fun setUp() {
        jdbcTemplate = JdbcTemplate(dataSource)
        jdbcTemplate.execute(
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

    @AfterEach
    fun tearDown() {
        jdbcTemplate.execute("DROP TABLE otp_rate_limit_attempts")
    }

    @Test
    fun `enforces phone IP and device scopes independently`() {
        val limiter = limiter(phoneMaxAttempts = 2, ipMaxAttempts = 2, deviceMaxAttempts = 2)

        limiter.claim("+79990000001", context("10.0.0.1", "device-a"))
        limiter.claim("+79990000001", context("10.0.0.2", "device-b"))
        assertRejected { limiter.claim("+79990000001", context("10.0.0.3", "device-c")) }

        clearAttempts()
        limiter.claim("+79990000001", context("10.0.0.1", "device-a"))
        limiter.claim("+79990000002", context("10.0.0.1", "device-b"))
        assertRejected { limiter.claim("+79990000003", context("10.0.0.1", "device-c")) }

        clearAttempts()
        limiter.claim("+79990000001", context("10.0.0.1", "device-a"))
        limiter.claim("+79990000002", context("10.0.0.2", "device-a"))
        assertRejected { limiter.claim("+79990000003", context("10.0.0.3", "device-a")) }
    }

    @Test
    fun `allows only the configured number of concurrent PostgreSQL claims`() {
        val limiter = limiter(phoneMaxAttempts = 3, ipMaxAttempts = 100, deviceMaxAttempts = 100)
        val executor = Executors.newFixedThreadPool(8)
        val start = java.util.concurrent.CountDownLatch(1)

        val results = (1..8).map {
            executor.submit(Callable {
                start.await()
                runCatching { limiter.claim("+79990000001", context("10.0.0.$it", "device-$it")) }.exceptionOrNull()
            })
        }
        start.countDown()

        val failures = results.map { it.get(15, TimeUnit.SECONDS) }
        executor.shutdown()
        assertEquals(3, failures.count { it == null })
        assertEquals(5, failures.count { it is RateLimitException })
        assertEquals(3L, countAttempts("phone"))
    }

    @Test
    fun `globally removes expired attempts in bounded batches`() {
        val limiter = limiter(cleanupBatchSize = 100)
        val stale = LocalDateTime.now().minusMinutes(61)
        repeat(101) { index ->
            jdbcTemplate.update(
                "INSERT INTO otp_rate_limit_attempts (scope, subject_key, attempted_at) VALUES ('ip', LPAD(CAST(? AS TEXT), 64, '0'), ?)",
                index,
                stale,
            )
        }

        limiter.claim("+79990000001", context("10.0.0.1", "device-a"))
        assertEquals(1L, countExpired())

        limiter.claim("+79990000002", context("10.0.0.2", "device-b"))
        assertEquals(0L, countExpired())
    }

    @Test
    fun `commits and releases a claim before an enclosing transaction rolls back`() {
        val transactionManager = DataSourceTransactionManager(dataSource)
        val limiter = limiter(
            transactionManager = transactionManager,
            phoneMaxAttempts = 2,
            ipMaxAttempts = 100,
            deviceMaxAttempts = 100,
        )
        val executor = Executors.newSingleThreadExecutor()

        try {
            assertThrows<IllegalStateException> {
                TransactionTemplate(transactionManager).executeWithoutResult {
                    limiter.claim("+79990000001", context("10.0.0.1", "device-a"))

                    executor.submit(Callable {
                        limiter.claim("+79990000001", context("10.0.0.2", "device-b"))
                    }).get(5, TimeUnit.SECONDS)

                    throw IllegalStateException("Simulated downstream failure")
                }
            }

            assertEquals(2L, countAttempts("phone"))
        } finally {
            executor.shutdownNow()
        }
    }

    private fun limiter(
        transactionManager: DataSourceTransactionManager = DataSourceTransactionManager(dataSource),
        phoneMaxAttempts: Long = 10,
        ipMaxAttempts: Long = 10,
        deviceMaxAttempts: Long = 10,
        cleanupBatchSize: Int = 1_000,
    ): OtpRateLimiter = OtpRateLimiter(
        jdbcTemplate = jdbcTemplate,
        otpProperties = OtpProperties(maxAttemptsPerHour = phoneMaxAttempts),
        rateLimitProperties = OtpRateLimitProperties(
            ipMaxAttempts = ipMaxAttempts,
            deviceEnabled = true,
            deviceMaxAttempts = deviceMaxAttempts,
            cleanupBatchSize = cleanupBatchSize,
        ),
        transactionManager = transactionManager,
    )

    private fun context(ip: String, device: String) = OtpRequestContext(ip, device)

    private fun assertRejected(action: () -> Unit) {
        assertThrows<RateLimitException>(action)
    }

    private fun clearAttempts() {
        jdbcTemplate.execute("TRUNCATE otp_rate_limit_attempts")
    }

    private fun countAttempts(scope: String): Long =
        jdbcTemplate.queryForObject(
            "SELECT COUNT(*) FROM otp_rate_limit_attempts WHERE scope = ?",
            Long::class.java,
            scope,
        )

    private fun countExpired(): Long =
        jdbcTemplate.queryForObject(
            "SELECT COUNT(*) FROM otp_rate_limit_attempts WHERE attempted_at <= ?",
            Long::class.java,
            LocalDateTime.now().minusMinutes(60),
        )

}
