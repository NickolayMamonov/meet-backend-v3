package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.config.OtpProperties
import dev.whysoezzy.meet.service.OtpRequestContext
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import dev.whysoezzy.meet.service.auth.otp.ActivationOutcome
import dev.whysoezzy.meet.service.auth.otp.OtpChallengeLifecycle
import dev.whysoezzy.meet.service.auth.otp.OtpCodeGenerator
import dev.whysoezzy.meet.service.auth.otp.OtpDeliveryRouter
import dev.whysoezzy.meet.service.auth.otp.OtpHasher
import dev.whysoezzy.meet.service.auth.otp.OtpIdentifierLock
import dev.whysoezzy.meet.service.auth.otp.OtpRequestCoordinator
import dev.whysoezzy.meet.service.auth.otp.OtpRequestOutcome
import dev.whysoezzy.meet.service.auth.otp.OtpRequestRateLimiter
import dev.whysoezzy.meet.service.auth.otp.SensitiveOtpCode
import dev.whysoezzy.meet.service.email.EmailOtpMessage
import dev.whysoezzy.meet.service.email.EmailOtpSender
import dev.whysoezzy.meet.service.sms.SmsSender
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals

class OtpChallengeStorePostgresTest(
    @Autowired private val lifecycle: OtpChallengeLifecycle,
    @Autowired private val hasher: OtpHasher,
    @Autowired private val codeGenerator: OtpCodeGenerator,
    @Autowired private val requestRateLimiter: OtpRequestRateLimiter,
    @Autowired private val otpProperties: OtpProperties,
    @Autowired private val identifierLock: OtpIdentifierLock,
    @Autowired private val transactionManager: PlatformTransactionManager,
) : IntegrationTestSupport() {
    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `greatest request ID is the only challenge eligible to activate`() {
        val identifier = AuthIdentifier.email("person@example.com")
        val older = pending(identifier, "111111")
        val newer = pending(identifier, "222222")
        assertEquals(
            300.0,
            jdbcTemplate.queryForObject(
                "SELECT EXTRACT(EPOCH FROM expires_at - created_at) FROM otp_codes WHERE id = ?",
                Double::class.java,
                newer,
            ),
        )

        assertEquals(ActivationOutcome.Activated, lifecycle.activate(newer))
        assertEquals(ActivationOutcome.Superseded, lifecycle.activate(older))

        assertEquals(
            listOf(newer to "ACTIVE", older to "SUPERSEDED"),
            jdbcTemplate.query(
                """
                SELECT id, status FROM otp_codes
                WHERE channel = 'EMAIL' AND identifier = 'person@example.com'
                ORDER BY id DESC
                """.trimIndent(),
            ) { row, _ -> row.getLong("id") to row.getString("status") },
        )
    }

    @Test
    fun `failed newer delivery preserves the prior active challenge`() {
        val identifier = AuthIdentifier.email("person@example.com")
        val prior = pending(identifier, "111111")
        assertEquals(ActivationOutcome.Activated, lifecycle.activate(prior))
        val failed = pending(identifier, "222222")

        lifecycle.markDeliveryFailed(failed)

        assertEquals(
            listOf(prior to "ACTIVE", failed to "DELIVERY_FAILED"),
            jdbcTemplate.query(
                """
                SELECT id, status FROM otp_codes
                WHERE channel = 'EMAIL' AND identifier = 'person@example.com'
                ORDER BY id
                """.trimIndent(),
            ) { row, _ -> row.getLong("id") to row.getString("status") },
        )
    }

    @Test
    fun `concurrent activation leaves exactly the greatest request ID active`() {
        val identifier = AuthIdentifier.email("person@example.com")
        val older = pending(identifier, "111111")
        val newer = pending(identifier, "222222")
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val oldResult = executor.submit<ActivationOutcome> {
                start.await()
                lifecycle.activate(older)
            }
            val newResult = executor.submit<ActivationOutcome> {
                start.await()
                lifecycle.activate(newer)
            }
            start.countDown()

            assertEquals(ActivationOutcome.Superseded, oldResult.get(5, TimeUnit.SECONDS))
            assertEquals(ActivationOutcome.Activated, newResult.get(5, TimeUnit.SECONDS))
        } finally {
            executor.shutdownNow()
        }

        assertEquals(
            listOf(newer),
            jdbcTemplate.queryForList(
                "SELECT id FROM otp_codes WHERE status = 'ACTIVE'",
                Long::class.java,
            ),
        )
    }

    @Test
    fun `slow older delivery completion cannot supersede a fast newer delivery`() {
        val identifier = AuthIdentifier.email("person@example.com")
        val olderDeliveryStarted = CountDownLatch(1)
        val releaseOlderCompletion = CountDownLatch(1)
        val deliveryNumber = AtomicInteger()
        val deliveryRouter = OtpDeliveryRouter(
            smsSender = object : SmsSender {
                override fun sendOtp(phone: String, code: String) = Unit
            },
            emailOtpSender = object : EmailOtpSender {
                override fun send(message: EmailOtpMessage) {
                    if (deliveryNumber.incrementAndGet() == 1) {
                        olderDeliveryStarted.countDown()
                        check(releaseOlderCompletion.await(5, TimeUnit.SECONDS)) {
                            "Older delivery was not released"
                        }
                    }
                }
            },
        )
        val coordinator = OtpRequestCoordinator(
            requestRateLimiter = requestRateLimiter,
            codeGenerator = codeGenerator,
            hasher = hasher,
            challengeLifecycle = lifecycle,
            deliveryRouter = deliveryRouter,
            otpProperties = otpProperties,
        )
        val executor = Executors.newSingleThreadExecutor()
        try {
            val olderRequest = executor.submit<OtpRequestOutcome> {
                coordinator.request(identifier, OtpRequestContext.EMPTY)
            }
            check(olderDeliveryStarted.await(5, TimeUnit.SECONDS)) { "Older delivery did not start" }

            assertEquals(
                OtpRequestOutcome.Accepted,
                coordinator.request(identifier, OtpRequestContext.EMPTY),
            )
            releaseOlderCompletion.countDown()

            assertEquals(OtpRequestOutcome.Accepted, olderRequest.get(5, TimeUnit.SECONDS))
            assertEquals(
                listOf("SUPERSEDED", "ACTIVE"),
                jdbcTemplate.queryForList(
                    """
                    SELECT status FROM otp_codes
                    WHERE channel = 'EMAIL' AND identifier = 'person@example.com'
                    ORDER BY id
                    """.trimIndent(),
                    String::class.java,
                ),
            )
        } finally {
            releaseOlderCompletion.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `post-lock database time prevents activation after expiry and preserves prior active`() {
        val identifier = AuthIdentifier.email("person@example.com")
        val prior = pending(identifier, "111111")
        assertEquals(ActivationOutcome.Activated, lifecycle.activate(prior))
        val expiring = pending(identifier, "222222")
        jdbcTemplate.update(
            "UPDATE otp_codes SET expires_at = clock_timestamp() + INTERVAL '1 second' WHERE id = ?",
            expiring,
        )

        val lockHeld = CountDownLatch(1)
        val releaseLock = CountDownLatch(1)
        val activationStarted = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val holder = executor.submit {
                TransactionTemplate(transactionManager).executeWithoutResult {
                    identifierLock.lock(identifier)
                    lockHeld.countDown()
                    releaseLock.await(5, TimeUnit.SECONDS)
                }
            }
            lockHeld.await(5, TimeUnit.SECONDS)
            val activation = executor.submit<ActivationOutcome> {
                activationStarted.countDown()
                lifecycle.activate(expiring)
            }
            activationStarted.await(5, TimeUnit.SECONDS)
            Thread.sleep(1_200)
            releaseLock.countDown()

            assertEquals(ActivationOutcome.Expired, activation.get(5, TimeUnit.SECONDS))
            holder.get(5, TimeUnit.SECONDS)
        } finally {
            releaseLock.countDown()
            executor.shutdownNow()
        }

        assertEquals(
            "ACTIVE",
            jdbcTemplate.queryForObject("SELECT status FROM otp_codes WHERE id = ?", String::class.java, prior),
        )
        assertEquals(
            "EXPIRED",
            jdbcTemplate.queryForObject("SELECT status FROM otp_codes WHERE id = ?", String::class.java, expiring),
        )
    }

    private fun pending(identifier: AuthIdentifier, code: String): Long {
        val sensitiveCode = SensitiveOtpCode.validated(code)
        return lifecycle.createPending(identifier, hasher.hash(identifier, sensitiveCode)).id
    }
}
