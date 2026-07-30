package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.service.OtpRequestContext
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import dev.whysoezzy.meet.service.auth.identifier.IpLiteralParser
import dev.whysoezzy.meet.service.auth.otp.ActivationOutcome
import dev.whysoezzy.meet.service.auth.otp.OtpChallengeLifecycle
import dev.whysoezzy.meet.service.auth.otp.OtpHasher
import dev.whysoezzy.meet.service.auth.otp.OtpAttemptStore
import dev.whysoezzy.meet.service.auth.otp.OtpIdentifierLock
import dev.whysoezzy.meet.service.auth.otp.OtpVerificationCommand
import dev.whysoezzy.meet.service.auth.otp.OtpVerificationExecutor
import dev.whysoezzy.meet.service.auth.otp.SensitiveOtpCode
import dev.whysoezzy.meet.service.auth.otp.VerificationOutcome
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.dao.DataAccessException
import org.springframework.jdbc.core.RowMapper
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import java.time.LocalDateTime
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs

class OtpVerificationPostgresIntegrationTest(
    @Autowired private val lifecycle: OtpChallengeLifecycle,
    @Autowired private val hasher: OtpHasher,
    @Autowired private val verificationExecutor: OtpVerificationExecutor,
    @Autowired private val attemptStore: OtpAttemptStore,
    @Autowired private val identifierLock: OtpIdentifierLock,
    @Autowired private val transactionManager: PlatformTransactionManager,
) : IntegrationTestSupport() {
    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `concurrent correct submissions produce one user identity token set and one replay failure`() {
        val identifier = AuthIdentifier.email("person@example.com")
        activate(identifier, "123456")
        val command = command(identifier, "123456")
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val results = (1..2).map {
                executor.submit(
                    Callable {
                        start.await()
                        verificationExecutor.verify(command)
                    },
                )
            }
            start.countDown()
            val outcomes = results.map { it.get(10, TimeUnit.SECONDS) }

            assertEquals(1, outcomes.count { it is VerificationOutcome.Authenticated })
            assertEquals(1, outcomes.count { it == VerificationOutcome.Invalid })
        } finally {
            executor.shutdownNow()
        }

        assertEquals(1L, users.count())
        assertEquals(1L, jdbcTemplate.queryForObject("SELECT COUNT(*) FROM auth_identities", Long::class.java))
        assertEquals(1L, jdbcTemplate.queryForObject("SELECT COUNT(*) FROM refresh_tokens", Long::class.java))
        assertEquals(
            "CONSUMED",
            jdbcTemplate.queryForObject("SELECT status FROM otp_codes", String::class.java),
        )
    }

    @Test
    fun `failed identifier budget commits and cannot be reset by a resend`() {
        val identifier = AuthIdentifier.email("person@example.com")
        activate(identifier, "111111")

        repeat(5) {
            assertEquals(VerificationOutcome.Invalid, verificationExecutor.verify(command(identifier, "999999")))
        }
        assertEquals(
            5,
            jdbcTemplate.queryForObject("SELECT failed_attempts FROM otp_codes", Int::class.java),
        )
        assertEquals(
            5L,
            jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM otp_rate_limit_attempts WHERE scope = 'verify_email'",
                Long::class.java,
            ),
        )

        activate(identifier, "222222")
        assertEquals(
            VerificationOutcome.Invalid,
            verificationExecutor.verify(command(identifier, "222222")),
        )
        assertEquals(0L, users.count())
        assertEquals(0L, jdbcTemplate.queryForObject("SELECT COUNT(*) FROM refresh_tokens", Long::class.java))
    }

    @Test
    fun `unknown identifier charges only IP and does not poison a future identifier challenge`() {
        val identifier = AuthIdentifier.email("person@example.com")
        val context = OtpRequestContext(
            clientIp = requireNotNull(IpLiteralParser.parse("203.0.113.7")),
            deviceId = null,
        )
        assertEquals(
            VerificationOutcome.Invalid,
            verificationExecutor.verify(command(identifier, "123456", context)),
        )
        assertEquals(
            listOf("verify_ip"),
            jdbcTemplate.queryForList("SELECT scope FROM otp_rate_limit_attempts", String::class.java),
        )

        activate(identifier, "123456")
        assertIs<VerificationOutcome.Authenticated>(
            verificationExecutor.verify(command(identifier, "123456", context)),
        )
    }

    @Test
    fun `token persistence failure rolls back consumption identity and user for a safe retry`() {
        val identifier = AuthIdentifier.email("person@example.com")
        activate(identifier, "123456")
        jdbcTemplate.execute(
            """
            CREATE FUNCTION reject_refresh_insert() RETURNS trigger
            LANGUAGE plpgsql AS $$
            BEGIN
                RAISE EXCEPTION 'refresh insert rejected';
            END;
            $$
            """.trimIndent(),
        )
        jdbcTemplate.execute(
            """
            CREATE TRIGGER reject_refresh_insert
            BEFORE INSERT ON refresh_tokens
            FOR EACH ROW EXECUTE FUNCTION reject_refresh_insert()
            """.trimIndent(),
        )

        try {
            assertThrows<DataAccessException> {
                verificationExecutor.verify(command(identifier, "123456"))
            }
            assertEquals(
                "ACTIVE",
                jdbcTemplate.queryForObject("SELECT status FROM otp_codes", String::class.java),
            )
            assertEquals(0L, users.count())
            assertEquals(0L, jdbcTemplate.queryForObject("SELECT COUNT(*) FROM auth_identities", Long::class.java))
        } finally {
            jdbcTemplate.execute("DROP TRIGGER IF EXISTS reject_refresh_insert ON refresh_tokens")
            jdbcTemplate.execute("DROP FUNCTION IF EXISTS reject_refresh_insert()")
        }

        assertIs<VerificationOutcome.Authenticated>(
            verificationExecutor.verify(command(identifier, "123456")),
        )
    }

    @Test
    fun `correct code crossing expiry on an attempt lock charges only IP`() {
        val identifier = AuthIdentifier.email("person@example.com")
        activate(identifier, "123456")
        jdbcTemplate.update(
            "UPDATE otp_codes SET expires_at = clock_timestamp() + INTERVAL '1 second'",
        )
        val context = OtpRequestContext(
            clientIp = requireNotNull(IpLiteralParser.parse("203.0.113.8")),
            deviceId = null,
        )
        val identifierLimit = attemptStore.verificationIdentifier(identifier, 5)
        val lockHeld = CountDownLatch(1)
        val releaseLock = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val holder = executor.submit {
                TransactionTemplate(transactionManager).executeWithoutResult {
                    attemptStore.lock(listOf(identifierLimit))
                    lockHeld.countDown()
                    releaseLock.await(5, TimeUnit.SECONDS)
                }
            }
            check(lockHeld.await(5, TimeUnit.SECONDS)) { "Attempt lock was not acquired" }
            val verification = executor.submit<VerificationOutcome> {
                verificationExecutor.verify(command(identifier, "123456", context))
            }
            awaitDatabaseLockWait()
            Thread.sleep(1_200)
            releaseLock.countDown()

            assertEquals(VerificationOutcome.Invalid, verification.get(5, TimeUnit.SECONDS))
            holder.get(5, TimeUnit.SECONDS)
        } finally {
            releaseLock.countDown()
            executor.shutdownNow()
        }

        assertEquals(
            "EXPIRED",
            jdbcTemplate.queryForObject("SELECT status FROM otp_codes", String::class.java),
        )
        assertEquals(
            0,
            jdbcTemplate.queryForObject("SELECT failed_attempts FROM otp_codes", Int::class.java),
        )
        assertEquals(
            listOf("verify_ip"),
            jdbcTemplate.queryForList("SELECT scope FROM otp_rate_limit_attempts", String::class.java),
        )
    }

    @Test
    fun `wrong code crossing expiry on an attempt lock leaves no identifier or challenge failure state`() {
        val identifier = AuthIdentifier.email("person@example.com")
        activate(identifier, "123456")
        val expiredChallenge = requireNotNull(
            jdbcTemplate.queryForObject("SELECT id FROM otp_codes", Long::class.java),
        )
        jdbcTemplate.update(
            "UPDATE otp_codes SET expires_at = clock_timestamp() + INTERVAL '1 second'",
        )
        val context = OtpRequestContext(
            clientIp = requireNotNull(IpLiteralParser.parse("203.0.113.9")),
            deviceId = null,
        )
        val identifierLimit = attemptStore.verificationIdentifier(identifier, 5)
        val lockHeld = CountDownLatch(1)
        val releaseLock = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val holder = executor.submit {
                TransactionTemplate(transactionManager).executeWithoutResult {
                    attemptStore.lock(listOf(identifierLimit))
                    lockHeld.countDown()
                    releaseLock.await(5, TimeUnit.SECONDS)
                }
            }
            check(lockHeld.await(5, TimeUnit.SECONDS)) { "Attempt lock was not acquired" }
            val verification = executor.submit<VerificationOutcome> {
                verificationExecutor.verify(command(identifier, "999999", context))
            }
            awaitDatabaseLockWait()
            Thread.sleep(1_200)
            releaseLock.countDown()

            assertEquals(VerificationOutcome.Invalid, verification.get(5, TimeUnit.SECONDS))
            holder.get(5, TimeUnit.SECONDS)
        } finally {
            releaseLock.countDown()
            executor.shutdownNow()
        }

        val expiredState = jdbcTemplate.queryForObject(
            "SELECT id, status, failed_attempts FROM otp_codes",
            RowMapper<Triple<Long, String, Int>> { row, _ ->
                Triple(
                    row.getLong("id"),
                    row.getString("status"),
                    row.getInt("failed_attempts"),
                )
            },
        )
        assertEquals(Triple(expiredChallenge, "EXPIRED", 0), expiredState)
        assertEquals(
            listOf("verify_ip"),
            jdbcTemplate.queryForList("SELECT scope FROM otp_rate_limit_attempts", String::class.java),
        )

        activate(identifier, "654321")
        assertIs<VerificationOutcome.Authenticated>(
            verificationExecutor.verify(command(identifier, "654321")),
        )
    }

    @Test
    fun `challenge row lock wait crossing expiry leaves a resend clean`() {
        val identifier = AuthIdentifier.email("person@example.com")
        activate(identifier, "123456")
        val expiredChallenge = jdbcTemplate.queryForObject("SELECT id FROM otp_codes", Long::class.java)
        jdbcTemplate.update(
            "UPDATE otp_codes SET expires_at = clock_timestamp() + INTERVAL '1 second'",
        )
        val context = OtpRequestContext(
            clientIp = requireNotNull(IpLiteralParser.parse("203.0.113.10")),
            deviceId = null,
        )
        val rowLocked = CountDownLatch(1)
        val releaseRow = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val holder = executor.submit {
                TransactionTemplate(transactionManager).executeWithoutResult {
                    jdbcTemplate.queryForObject(
                        "SELECT id FROM otp_codes WHERE id = ? FOR UPDATE",
                        Long::class.java,
                        expiredChallenge,
                    )
                    rowLocked.countDown()
                    releaseRow.await(5, TimeUnit.SECONDS)
                }
            }
            check(rowLocked.await(5, TimeUnit.SECONDS)) { "Challenge row lock was not acquired" }
            val verification = executor.submit<VerificationOutcome> {
                verificationExecutor.verify(command(identifier, "999999", context))
            }
            awaitDatabaseLockWait()
            Thread.sleep(1_200)
            releaseRow.countDown()

            assertEquals(VerificationOutcome.Invalid, verification.get(5, TimeUnit.SECONDS))
            holder.get(5, TimeUnit.SECONDS)
        } finally {
            releaseRow.countDown()
            executor.shutdownNow()
        }

        assertEquals(
            "EXPIRED" to 0,
            jdbcTemplate.queryForObject(
                "SELECT status, failed_attempts FROM otp_codes WHERE id = ?",
                { row, _ -> row.getString("status") to row.getInt("failed_attempts") },
                expiredChallenge,
            ),
        )
        assertEquals(
            listOf("verify_ip"),
            jdbcTemplate.queryForList("SELECT scope FROM otp_rate_limit_attempts", String::class.java),
        )

        activate(identifier, "654321")
        assertIs<VerificationOutcome.Authenticated>(
            verificationExecutor.verify(command(identifier, "654321")),
        )
    }

    @Test
    fun `activation queued before verification is observed and consumed`() {
        val identifier = AuthIdentifier.email("person@example.com")
        activate(identifier, "111111")
        val newer = pending(identifier, "222222")
        val executor = Executors.newFixedThreadPool(3)
        val heldIdentifier = holdIdentifierLock(identifier, executor)
        try {
            val activation = executor.submit<ActivationOutcome> { lifecycle.activate(newer) }
            awaitAdvisoryWaiters(1)
            val verification = executor.submit<VerificationOutcome> {
                verificationExecutor.verify(command(identifier, "222222"))
            }
            awaitAdvisoryWaiters(2)
            heldIdentifier.release.countDown()

            assertEquals(ActivationOutcome.Activated, activation.get(5, TimeUnit.SECONDS))
            assertIs<VerificationOutcome.Authenticated>(verification.get(5, TimeUnit.SECONDS))
            heldIdentifier.holder.get(5, TimeUnit.SECONDS)
        } finally {
            heldIdentifier.release.countDown()
            executor.shutdownNow()
        }

        assertEquals(
            listOf("SUPERSEDED", "CONSUMED"),
            jdbcTemplate.queryForList("SELECT status FROM otp_codes ORDER BY id", String::class.java),
        )
    }

    @Test
    fun `verification queued before activation consumes prior challenge and leaves newer active`() {
        val identifier = AuthIdentifier.email("person@example.com")
        activate(identifier, "111111")
        val newer = pending(identifier, "222222")
        val executor = Executors.newFixedThreadPool(3)
        val heldIdentifier = holdIdentifierLock(identifier, executor)
        try {
            val verification = executor.submit<VerificationOutcome> {
                verificationExecutor.verify(command(identifier, "111111"))
            }
            awaitAdvisoryWaiters(1)
            val activation = executor.submit<ActivationOutcome> { lifecycle.activate(newer) }
            awaitAdvisoryWaiters(2)
            heldIdentifier.release.countDown()

            assertIs<VerificationOutcome.Authenticated>(verification.get(5, TimeUnit.SECONDS))
            assertEquals(ActivationOutcome.Activated, activation.get(5, TimeUnit.SECONDS))
            heldIdentifier.holder.get(5, TimeUnit.SECONDS)
        } finally {
            heldIdentifier.release.countDown()
            executor.shutdownNow()
        }

        assertEquals(
            listOf("CONSUMED", "ACTIVE"),
            jdbcTemplate.queryForList("SELECT status FROM otp_codes ORDER BY id", String::class.java),
        )
    }

    @Test
    fun `concurrent verification restores one soft deleted user through disjoint identities`() {
        val user = users.saveAndFlush(
            dev.whysoezzy.meet.domain.entity.User(
                name = "Restorable",
                surname = "User",
                phone = "+15550000011",
                email = "restore@example.com",
            ).also {
                it.deletedAt = LocalDateTime.now().minusDays(1)
                it.authVersion = 7
            },
        )
        jdbcTemplate.update(
            """
            INSERT INTO auth_identities (user_id, type, normalized_identifier)
            VALUES (?, 'PHONE', ?), (?, 'EMAIL', ?)
            """.trimIndent(),
            user.id,
            "+15550000011",
            user.id,
            "restore@example.com",
        )
        val phone = AuthIdentifier.phone("+15550000011")
        val email = AuthIdentifier.email("restore@example.com")
        activate(phone, "111111")
        activate(email, "222222")

        val userRowLocked = CountDownLatch(1)
        val releaseUserRow = CountDownLatch(1)
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(3)
        try {
            val holder = executor.submit {
                TransactionTemplate(transactionManager).executeWithoutResult {
                    jdbcTemplate.queryForObject(
                        "SELECT id FROM users WHERE id = ? FOR UPDATE",
                        Long::class.java,
                        user.id,
                    )
                    userRowLocked.countDown()
                    releaseUserRow.await(10, TimeUnit.SECONDS)
                }
            }
            check(userRowLocked.await(5, TimeUnit.SECONDS)) { "User row lock was not acquired" }
            val phoneVerification = executor.submit<VerificationOutcome> {
                start.await()
                verificationExecutor.verify(command(phone, "111111"))
            }
            val emailVerification = executor.submit<VerificationOutcome> {
                start.await()
                verificationExecutor.verify(command(email, "222222"))
            }
            start.countDown()
            awaitDatabaseLockWait(expected = 2)
            releaseUserRow.countDown()

            assertIs<VerificationOutcome.Authenticated>(phoneVerification.get(10, TimeUnit.SECONDS))
            assertIs<VerificationOutcome.Authenticated>(emailVerification.get(10, TimeUnit.SECONDS))
            holder.get(5, TimeUnit.SECONDS)
        } finally {
            releaseUserRow.countDown()
            executor.shutdownNow()
        }

        val restored = users.findById(requireNotNull(user.id)).orElseThrow()
        assertFalse(restored.isDeleted)
        assertEquals(7L, restored.authVersion)
        assertEquals(1L, users.count())
        assertEquals(2L, jdbcTemplate.queryForObject("SELECT COUNT(*) FROM refresh_tokens", Long::class.java))
    }

    private fun activate(identifier: AuthIdentifier, code: String) {
        assertEquals(ActivationOutcome.Activated, lifecycle.activate(pending(identifier, code)))
    }

    private fun pending(identifier: AuthIdentifier, code: String): Long {
        val sensitiveCode = SensitiveOtpCode.validated(code)
        return lifecycle.createPending(identifier, hasher.hash(identifier, sensitiveCode)).id
    }

    private fun holdIdentifierLock(
        identifier: AuthIdentifier,
        executor: ExecutorService,
    ): HeldIdentifierLock {
        val lockHeld = CountDownLatch(1)
        val releaseLock = CountDownLatch(1)
        val holder = executor.submit {
            TransactionTemplate(transactionManager).executeWithoutResult {
                identifierLock.lock(identifier)
                lockHeld.countDown()
                releaseLock.await(10, TimeUnit.SECONDS)
            }
        }
        check(lockHeld.await(5, TimeUnit.SECONDS)) { "Identifier lock was not acquired" }
        return HeldIdentifierLock(releaseLock, holder)
    }

    private fun awaitAdvisoryWaiters(expected: Int) {
        awaitCondition("Expected $expected advisory lock waiters") {
            requireNotNull(
                jdbcTemplate.queryForObject(
                    """
                    SELECT COUNT(*) FROM pg_locks
                    WHERE locktype = 'advisory'
                      AND database = (
                          SELECT oid FROM pg_database WHERE datname = current_database()
                      )
                      AND NOT granted
                    """.trimIndent(),
                    Int::class.java,
                ),
            ) >= expected
        }
    }

    private fun awaitDatabaseLockWait(expected: Int = 1) {
        awaitCondition("Expected $expected database lock waiters") {
            requireNotNull(
                jdbcTemplate.queryForObject(
                    """
                    SELECT COUNT(*) FROM pg_stat_activity
                    WHERE datname = current_database()
                      AND pid <> pg_backend_pid()
                      AND wait_event_type = 'Lock'
                    """.trimIndent(),
                    Int::class.java,
                ),
            ) >= expected
        }
    }

    private fun awaitCondition(message: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!condition()) {
            check(System.nanoTime() < deadline) { message }
            Thread.sleep(10)
        }
    }

    private data class HeldIdentifierLock(
        val release: CountDownLatch,
        val holder: Future<*>,
    )

    private fun command(
        identifier: AuthIdentifier,
        code: String,
        context: OtpRequestContext = OtpRequestContext.EMPTY,
    ) = OtpVerificationCommand(
        identifier = identifier,
        code = SensitiveOtpCode.validated(code),
        context = context,
        name = "Test",
        surname = "User",
    )
}
