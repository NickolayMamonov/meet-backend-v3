package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.service.push.JdbcReminderDispatchStore
import dev.whysoezzy.meet.service.push.MeetingReminderStore
import dev.whysoezzy.meet.service.push.PushInstallationService
import dev.whysoezzy.meet.service.push.ReminderFinalization
import dev.whysoezzy.meet.service.push.parseFid
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MeetingReminderDispatchPostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var reminders: MeetingReminderStore

    @Autowired
    private lateinit var installations: PushInstallationService

    @Autowired
    private lateinit var dispatch: JdbcReminderDispatchStore

    @Autowired
    private lateinit var transactionManager: PlatformTransactionManager

    private val transaction by lazy { TransactionTemplate(transactionManager) }

    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `leased accepted target becomes sent and closes its claim`() {
        val now = databaseNow()
        val fixture = seedReminder(now)
        val lease = dispatch.leaseNext()
        assertNotNull(lease)
        val prepared = dispatch.prepareSend(lease, now)
        assertNotNull(prepared)

        assertEquals(true, dispatch.finalize(lease, prepared, ReminderFinalization.Accepted, now))
        assertEquals(
            "SENT",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
        assertEquals(
            "SENT",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_claims WHERE id = ?",
                String::class.java,
                lease.claimId,
            ),
        )
        assertEquals(fixture.bob.id, lease.userId)
    }

    @Test
    fun `invalid provider registration terminally invalidates only the exact installation`() {
        val now = databaseNow()
        val fixture = seedReminder(now)
        val lease = requireNotNull(dispatch.leaseNext())
        val prepared = requireNotNull(dispatch.prepareSend(lease, now))

        dispatch.finalize(lease, prepared, ReminderFinalization.InvalidRegistration, now)

        assertEquals(
            "INVALID",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
        assertEquals(
            "UNREGISTERED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM push_installations WHERE user_id = ?",
                String::class.java,
                fixture.bob.id,
            ),
        )
        assertEquals(null, jdbcTemplate.queryForObject(
            "SELECT fid FROM push_installations WHERE user_id = ?",
            String::class.java,
            fixture.bob.id,
        ))
    }

    @Test
    fun `expired fifth lease applies eligibility precedence before attempts exhausted`() {
        val now = databaseNow()
        val fixture = seedReminder(now)
        val lease = requireNotNull(dispatch.leaseNext())
        jdbcTemplate.update(
            """
            UPDATE meeting_reminder_targets
            SET attempts = 5, status = 'LEASED',
                lease_until = clock_timestamp() - INTERVAL '1 second'
            WHERE id = ?
            """.trimIndent(),
            lease.targetId,
        )
        jdbcTemplate.update("UPDATE users SET notifications_enabled = false WHERE id = ?", fixture.bob.id)

        assertEquals(1, dispatch.recoverAndExpire(100, now))
        assertEquals(
            "SKIPPED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
        assertEquals(
            "OPTED_OUT",
            jdbcTemplate.queryForObject(
                "SELECT reason FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
        assertNull(
            jdbcTemplate.queryForObject(
                "SELECT lease_token FROM meeting_reminder_targets WHERE id = ?",
                UUID::class.java,
                lease.targetId,
            ),
        )
    }

    @Test
    fun `transient retries consume exactly five attempts and never lease a sixth`() {
        val now = databaseNow()
        seedReminder(now)

        repeat(4) {
            val lease = requireNotNull(dispatch.leaseNext())
            assertEquals(it + 1, lease.attempt)
            val prepared = requireNotNull(dispatch.prepareSend(lease, now))
            assertEquals(true, dispatch.finalize(lease, prepared, ReminderFinalization.TransientFailure, now))
            jdbcTemplate.update(
                "UPDATE meeting_reminder_targets SET next_attempt_at = clock_timestamp() - INTERVAL '1 second'",
            )
        }
        val fifth = requireNotNull(dispatch.leaseNext())
        assertEquals(5, fifth.attempt)
        val prepared = requireNotNull(dispatch.prepareSend(fifth, now))
        assertEquals(true, dispatch.finalize(fifth, prepared, ReminderFinalization.TransientFailure, now))

        assertEquals(
            "FAILED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                fifth.targetId,
            ),
        )
        assertEquals(null, dispatch.leaseNext())
    }

    @Test
    fun `stale lease completion has no state or invalidation side effects`() {
        val now = databaseNow()
        val fixture = seedReminder(now)
        val lease = requireNotNull(dispatch.leaseNext())
        val prepared = requireNotNull(dispatch.prepareSend(lease, now))
        jdbcTemplate.update(
            "UPDATE meeting_reminder_targets SET lease_until = clock_timestamp() - INTERVAL '1 second' WHERE id = ?",
            lease.targetId,
        )

        assertEquals(false, dispatch.finalize(lease, prepared, ReminderFinalization.InvalidRegistration, now))
        assertEquals(
            "LEASED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
        assertEquals(
            "ACTIVE",
            jdbcTemplate.queryForObject(
                "SELECT status FROM push_installations WHERE user_id = ?",
                String::class.java,
                fixture.bob.id,
            ),
        )
    }

    @Test
    fun `maintenance terminalizes overdue unleased retry work without leasing it`() {
        val now = databaseNow()
        val fixture = seedReminder(now.minusSeconds(3_600))
        val targetId = jdbcTemplate.queryForObject(
            "SELECT id FROM meeting_reminder_targets LIMIT 1",
            UUID::class.java,
        )
        jdbcTemplate.update(
            """
            UPDATE meeting_reminder_targets
            SET status = 'RETRY_WAIT', attempts = 1, reason = 'TRANSIENT',
                next_attempt_at = CURRENT_TIMESTAMP - INTERVAL '10 minutes',
                lease_token = NULL, lease_until = NULL
            WHERE id = ?
            """.trimIndent(),
            targetId,
        )

        assertEquals(1, dispatch.recoverAndExpire(100, now))
        assertEquals(
            "SKIPPED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                targetId,
            ),
        )
        assertEquals(
            "STARTED",
            jdbcTemplate.queryForObject(
                "SELECT reason FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                targetId,
            ),
        )
        assertEquals(fixture.bob.id, jdbcTemplate.queryForObject(
            "SELECT user_id FROM meeting_reminder_targets WHERE id = ?",
            Long::class.java,
            targetId,
        ))
    }

    @Test
    fun `transient failure at the inclusive deadline remains retryable until attempt five`() {
        val issuedAt = databaseNow()
        seedReminder(issuedAt)
        val lease = requireNotNull(dispatch.leaseNext())
        val prepared = requireNotNull(dispatch.prepareSend(lease, issuedAt))
        val deadline = jdbcTemplate.queryForObject(
            "SELECT deadline_at FROM meeting_reminder_claims WHERE id = ?",
            java.sql.Timestamp::class.java,
            lease.claimId,
        )!!.toInstant()

        assertEquals(
            true,
            dispatch.finalize(lease, prepared, ReminderFinalization.TransientFailure, deadline),
        )
        assertEquals(
            "RETRY_WAIT",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
        assertEquals(
            1,
            jdbcTemplate.queryForObject(
                "SELECT attempts FROM meeting_reminder_targets WHERE id = ?",
                Int::class.java,
                lease.targetId,
            ),
        )
        assertEquals(
            deadline,
            jdbcTemplate.queryForObject(
                "SELECT next_attempt_at FROM meeting_reminder_targets WHERE id = ?",
                java.sql.Timestamp::class.java,
                lease.targetId,
            )!!.toInstant(),
        )
    }

    @Test
    fun `expired fifth leases apply every eligibility reason before attempts exhausted`() {
        val reasons = listOf(
            "USER_UNAVAILABLE",
            "OPTED_OUT",
            "LEFT_MEETING",
            "MEETING_UNAVAILABLE",
            "START_CHANGED",
            "STARTED",
            "INSTALLATION_UNAVAILABLE",
            "DEADLINE_PASSED",
        )
        reasons.forEach { expectedReason ->
            resetDatabase()
            val seedNow = databaseNow()
            val fixture = seedReminder(seedNow)
            val target = requireNotNull(transaction.execute { dispatch.leaseNext() })
            jdbcTemplate.update(
                """
                UPDATE meeting_reminder_targets
                SET attempts = 5, lease_until = clock_timestamp() - INTERVAL '1 second'
                WHERE id = ?
                """.trimIndent(),
                target.targetId,
            )
            when (expectedReason) {
                "USER_UNAVAILABLE" -> jdbcTemplate.update(
                    "UPDATE users SET deleted_at = ? WHERE id = ?",
                    java.sql.Timestamp.from(seedNow),
                    fixture.bob.id,
                )
                "OPTED_OUT" -> jdbcTemplate.update(
                    "UPDATE users SET notifications_enabled = false WHERE id = ?",
                    fixture.bob.id,
                )
                "LEFT_MEETING" -> jdbcTemplate.update(
                    "DELETE FROM meeting_participants WHERE user_id = ? AND meeting_id = ?",
                    fixture.bob.id,
                    fixture.meeting.id,
                )
                "MEETING_UNAVAILABLE" -> jdbcTemplate.update(
                    "UPDATE meetings SET status = 'CANCELLED' WHERE id = ?",
                    fixture.meeting.id,
                )
                "START_CHANGED" -> jdbcTemplate.update(
                    "UPDATE meetings SET time = time + 1000 WHERE id = ?",
                    fixture.meeting.id,
                )
                "STARTED" -> {
                    val startedAt = seedNow.minusSeconds(1).toEpochMilli()
                    jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", startedAt, fixture.meeting.id)
                    val startedVersion = jdbcTemplate.queryForObject(
                        "SELECT push_start_version FROM meetings WHERE id = ?",
                        Long::class.java,
                        fixture.meeting.id,
                    )!!
                    jdbcTemplate.update(
                        """
                        UPDATE meeting_reminder_claims
                        SET meeting_start_ms = ?,
                            start_version = ?,
                            due_at = to_timestamp((? - 60 * 60000)::double precision / 1000),
                            deadline_at = to_timestamp((? - 60 * 60000)::double precision / 1000)
                                + INTERVAL '15 minutes',
                            issued_at = to_timestamp((? - 60 * 60000)::double precision / 1000)
                        WHERE id = ?
                        """.trimIndent(),
                        startedAt, startedVersion, startedAt, startedAt, startedAt, target.claimId,
                    )
                }
                "INSTALLATION_UNAVAILABLE" -> jdbcTemplate.update(
                    """
                    UPDATE push_installations
                    SET fid = NULL, status = 'UNREGISTERED',
                        registration_version = registration_version + 1,
                        terminal_at = ?, updated_at = ?
                    WHERE user_id = ?
                    """.trimIndent(),
                    java.sql.Timestamp.from(seedNow),
                    java.sql.Timestamp.from(seedNow),
                    fixture.bob.id,
                )
                "DEADLINE_PASSED" -> Unit
            }

            if (expectedReason == "DEADLINE_PASSED") {
                val deadlineMeetingStart = seedNow.plusSeconds(44 * 60)
                val deadlineVersion = jdbcTemplate.queryForObject(
                    "SELECT push_start_version FROM meetings WHERE id = ?",
                    Long::class.java,
                    fixture.meeting.id,
                )!!
                jdbcTemplate.update(
                    "UPDATE meetings SET time = ? WHERE id = ?",
                    deadlineMeetingStart.toEpochMilli(),
                    fixture.meeting.id,
                )
                val deadlineStartVersion = deadlineVersion + 1
                val due = deadlineMeetingStart.minusSeconds(60 * 60)
                val deadline = due.plusSeconds(15 * 60)
                jdbcTemplate.update(
                    """
                    UPDATE meeting_reminder_claims
                    SET meeting_start_ms = ?, start_version = ?, due_at = ?, deadline_at = ?, issued_at = ?
                    WHERE id = ?
                    """.trimIndent(),
                    deadlineMeetingStart.toEpochMilli(),
                    deadlineStartVersion,
                    java.sql.Timestamp.from(due),
                    java.sql.Timestamp.from(deadline),
                    java.sql.Timestamp.from(due),
                    target.claimId,
                )
            }
            val recoveryNow = seedNow
            assertTrue(dispatch.recoverAndExpire(100, recoveryNow) >= 1)
            assertEquals(
                expectedReason,
                jdbcTemplate.queryForObject(
                    "SELECT reason FROM meeting_reminder_targets WHERE id = ?",
                    String::class.java,
                    target.targetId,
                ),
            )
            assertEquals(
                "SKIPPED",
                jdbcTemplate.queryForObject(
                    "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                    String::class.java,
                    target.targetId,
                ),
            )
        }
    }

    @Test
    fun `freshness boundary is reported as stale before maintenance expires the installation`() {
        val now = databaseNow()
        val fixture = seedReminder(now)
        val lease = requireNotNull(transaction.execute { dispatch.leaseNext() })
        jdbcTemplate.update(
            "UPDATE push_installations SET last_seen_at = ?, updated_at = ? WHERE user_id = ?",
            java.sql.Timestamp.from(now.minus(35, ChronoUnit.DAYS)),
            java.sql.Timestamp.from(now.minus(35, ChronoUnit.DAYS)),
            fixture.bob.id,
        )

        assertNull(transaction.execute { dispatch.prepareSend(lease, now) })
        assertTrue(transaction.execute { dispatch.skipIneligible(lease, now) } == true)
        assertEquals(
            "INSTALLATION_STALE",
            jdbcTemplate.queryForObject(
                "SELECT reason FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
    }

    @Test
    fun `old completion cannot mutate a freshly fenced lease after expiry`() {
        val now = databaseNow()
        val fixture = seedReminder(now)
        val oldLease = requireNotNull(transaction.execute { dispatch.leaseNext() })
        val prepared = requireNotNull(transaction.execute { dispatch.prepareSend(oldLease, now) })
        jdbcTemplate.update(
            "UPDATE meeting_reminder_targets SET lease_until = clock_timestamp() - INTERVAL '1 second' WHERE id = ?",
            oldLease.targetId,
        )
        val freshLease = requireNotNull(transaction.execute { dispatch.leaseNext() })
        assertNotEquals(oldLease.leaseToken, freshLease.leaseToken)
        assertEquals(
            false,
            transaction.execute {
                dispatch.finalize(oldLease, prepared, ReminderFinalization.InvalidRegistration, now)
            },
        )
        assertEquals(
            "ACTIVE",
            jdbcTemplate.queryForObject(
                "SELECT status FROM push_installations WHERE user_id = ?",
                String::class.java,
                fixture.bob.id,
            ),
        )
        assertEquals(
            "LEASED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                oldLease.targetId,
            ),
        )
    }

    @Test
    fun `same FID away and back registration ABA fences invalidation by version`() {
        val now = databaseNow()
        val fixture = seedReminder(now)
        val lease = requireNotNull(transaction.execute { dispatch.leaseNext() })
        val prepared = requireNotNull(transaction.execute { dispatch.prepareSend(lease, now) })
        val installationId = lease.installationId
        val beforeVersion = jdbcTemplate.queryForObject(
            "SELECT registration_version FROM push_installations WHERE id = ?",
            Long::class.java,
            installationId,
        )!!

        installations.unregister(requireNotNull(fixture.bob.id), installationId)
        installations.rotate(requireNotNull(fixture.bob.id), installationId, parseFid("fid-bob"))

        assertEquals(
            false,
            transaction.execute {
                dispatch.finalize(lease, prepared, ReminderFinalization.InvalidRegistration, now)
            },
        )
        assertEquals(
            beforeVersion + 2,
            jdbcTemplate.queryForObject(
                "SELECT registration_version FROM push_installations WHERE id = ?",
                Long::class.java,
                installationId,
            ),
        )
        assertEquals(
            "ACTIVE",
            jdbcTemplate.queryForObject(
                "SELECT status FROM push_installations WHERE id = ?",
                String::class.java,
                installationId,
            ),
        )
        assertEquals(
            "LEASED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_targets WHERE id = ?",
                String::class.java,
                lease.targetId,
            ),
        )
    }

    @Test
    fun `concurrent registration fence and stale invalid callback cannot retire the new owner`() {
        val now = databaseNow()
        val fixture = seedReminder(now)
        val lease = requireNotNull(transaction.execute { dispatch.leaseNext() })
        val prepared = requireNotNull(transaction.execute { dispatch.prepareSend(lease, now) })
        val userId = requireNotNull(fixture.bob.id)
        val oldVersion = prepared.registrationVersion
        val start = CountDownLatch(1)
        val rotationComplete = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val rotate = executor.submit {
                assertTrue(start.await(10, TimeUnit.SECONDS))
                installations.rotate(userId, lease.installationId, parseFid("fid-bob"))
                rotationComplete.countDown()
            }
            val staleCallback = executor.submit {
                assertTrue(start.await(10, TimeUnit.SECONDS))
                assertTrue(rotationComplete.await(10, TimeUnit.SECONDS))
                transaction.execute {
                    dispatch.finalize(lease, prepared, ReminderFinalization.InvalidRegistration, now)
                }
            }
            start.countDown()
            rotate.get(10, TimeUnit.SECONDS)
            staleCallback.get(10, TimeUnit.SECONDS)
        } finally {
            executor.shutdownNow()
        }

        assertEquals(
            "ACTIVE",
            jdbcTemplate.queryForObject(
                "SELECT status FROM push_installations WHERE id = ?",
                String::class.java,
                lease.installationId,
            ),
        )
        assertEquals(
            "fid-bob",
            jdbcTemplate.queryForObject(
                "SELECT fid FROM push_installations WHERE id = ?",
                String::class.java,
                lease.installationId,
            ),
        )
        assertTrue(
            jdbcTemplate.queryForObject(
                "SELECT registration_version FROM push_installations WHERE id = ?",
                Long::class.java,
                lease.installationId,
            )!! > oldVersion,
        )
    }

    @Test
    fun `sibling reduction covers every ordered terminal outcome permutation`() {
        val outcomes = TerminalOutcome.entries
        outcomes.forEach { first ->
            outcomes.forEach { second ->
                resetDatabase()
                val now = databaseNow()
                val fixture = seedReminderWithTwoInstallations(now)
                val firstLease = requireNotNull(transaction.execute { dispatch.leaseNext() })
                val secondLease = requireNotNull(transaction.execute { dispatch.leaseNext() })
                complete(firstLease, first, now)
                complete(secondLease, second, now)

                val expectedClaim = when {
                    first == TerminalOutcome.SENT || second == TerminalOutcome.SENT -> "SENT"
                    first == TerminalOutcome.INVALID || second == TerminalOutcome.INVALID ||
                        first == TerminalOutcome.FAILED || second == TerminalOutcome.FAILED -> "FAILED"
                    else -> "SKIPPED"
                }
                assertEquals(
                    expectedClaim,
                    jdbcTemplate.queryForObject(
                        "SELECT status FROM meeting_reminder_claims",
                        String::class.java,
                    ),
                    "$first then $second for user ${fixture.bob.id}",
                )
            }
        }
    }

    @Test
    fun `concurrent sibling reductions are serialized and retain sent precedence`() {
        val now = databaseNow()
        seedReminderWithTwoInstallations(now)
        val first = requireNotNull(transaction.execute { dispatch.leaseNext() })
        val second = requireNotNull(transaction.execute { dispatch.leaseNext() })
        val firstPrepared = requireNotNull(transaction.execute { dispatch.prepareSend(first, now) })
        val secondPrepared = requireNotNull(transaction.execute { dispatch.prepareSend(second, now) })
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val accepted = executor.submit<Boolean> {
                assertTrue(start.await(10, TimeUnit.SECONDS))
                transaction.execute {
                    dispatch.finalize(first, firstPrepared, ReminderFinalization.Accepted, now)
                } ?: false
            }
            val invalid = executor.submit<Boolean> {
                assertTrue(start.await(10, TimeUnit.SECONDS))
                transaction.execute {
                    dispatch.finalize(second, secondPrepared, ReminderFinalization.InvalidRegistration, now)
                } ?: false
            }
            start.countDown()
            assertTrue(accepted.get(10, TimeUnit.SECONDS))
            assertTrue(invalid.get(10, TimeUnit.SECONDS))
        } finally {
            executor.shutdownNow()
        }
        assertEquals(
            "SENT",
            jdbcTemplate.queryForObject("SELECT status FROM meeting_reminder_claims", String::class.java),
        )
        assertEquals(
            2L,
            jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM meeting_reminder_targets WHERE status IN ('SENT', 'INVALID')",
                Long::class.java,
            ),
        )
    }

    private enum class TerminalOutcome {
        SENT,
        INVALID,
        FAILED,
        SKIPPED,
    }

    private fun complete(lease: dev.whysoezzy.meet.service.push.ReminderLease, outcome: TerminalOutcome, now: Instant) {
        when (outcome) {
            TerminalOutcome.SENT -> {
                val prepared = requireNotNull(transaction.execute { dispatch.prepareSend(lease, now) })
                assertTrue(transaction.execute {
                    dispatch.finalize(lease, prepared, ReminderFinalization.Accepted, now)
                } == true)
            }
            TerminalOutcome.INVALID -> {
                val prepared = requireNotNull(transaction.execute { dispatch.prepareSend(lease, now) })
                assertTrue(transaction.execute {
                    dispatch.finalize(lease, prepared, ReminderFinalization.InvalidRegistration, now)
                } == true)
            }
            TerminalOutcome.FAILED -> {
                var current = lease
                repeat(4) {
                    val prepared = requireNotNull(transaction.execute { dispatch.prepareSend(current, now) })
                    assertTrue(transaction.execute {
                        dispatch.finalize(current, prepared, ReminderFinalization.TransientFailure, now)
                    } == true)
                    jdbcTemplate.update(
                        "UPDATE meeting_reminder_targets SET next_attempt_at = clock_timestamp() - INTERVAL '1 second' WHERE id = ?",
                        current.targetId,
                    )
                    val next = requireNotNull(transaction.execute { dispatch.leaseNext() })
                    assertEquals(current.targetId, next.targetId)
                    require(next.attempt == it + 2)
                    current = next
                }
                val prepared = requireNotNull(transaction.execute { dispatch.prepareSend(current, now) })
                assertTrue(transaction.execute {
                    dispatch.finalize(current, prepared, ReminderFinalization.TransientFailure, now)
                } == true)
            }
            TerminalOutcome.SKIPPED -> {
                jdbcTemplate.update(
                    """
                    UPDATE push_installations
                    SET fid = NULL, status = 'UNREGISTERED',
                        registration_version = registration_version + 1,
                        terminal_at = clock_timestamp(), updated_at = clock_timestamp()
                    WHERE id = ?
                    """.trimIndent(),
                    lease.installationId,
                )
                assertNull(transaction.execute { dispatch.prepareSend(lease, now) })
                assertTrue(transaction.execute { dispatch.skipIneligible(lease, now) } == true)
            }
        }
    }

    private fun seedReminderWithTwoInstallations(now: Instant): ApiFixture {
        val fixture = fixture()
        jdbcTemplate.update(
            "UPDATE meetings SET time = ? WHERE id = ?",
            now.plusSeconds(3_600).toEpochMilli(),
            fixture.meeting.id,
        )
        installations.register(requireNotNull(fixture.bob.id), parseFid("fid-sibling-a"))
        installations.register(requireNotNull(fixture.bob.id), parseFid("fid-sibling-b"))
        val candidate = reminders.findCandidates(now).single()
        requireNotNull(transaction.execute { reminders.discover(candidate, now) })
        jdbcTemplate.update(
            "UPDATE meeting_reminder_targets SET next_attempt_at = clock_timestamp() - INTERVAL '1 second'",
        )
        return fixture
    }

    private fun seedReminder(now: Instant): ApiFixture {
        val fixture = fixture()
        jdbcTemplate.update(
            "UPDATE meetings SET time = ? WHERE id = ?",
            now.plusSeconds(3_600).toEpochMilli(),
            fixture.meeting.id,
        )
        installations.register(requireNotNull(fixture.bob.id), parseFid("fid-bob"))
        val candidate = reminders.findCandidates(now).single()
        requireNotNull(reminders.discover(candidate, now))
        jdbcTemplate.update(
            "UPDATE meeting_reminder_targets SET next_attempt_at = clock_timestamp() - INTERVAL '1 second'",
        )
        return fixture
    }

    private fun databaseNow(): Instant =
        jdbcTemplate.queryForObject(
            "SELECT clock_timestamp()",
            java.sql.Timestamp::class.java,
        )!!.toInstant().truncatedTo(ChronoUnit.MILLIS)
}
