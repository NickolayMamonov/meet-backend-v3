package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.service.push.MeetingReminderStore
import dev.whysoezzy.meet.service.push.ReminderClaimRecord
import dev.whysoezzy.meet.service.push.PushInstallationMutation
import dev.whysoezzy.meet.service.push.PushInstallationService
import dev.whysoezzy.meet.service.push.PushDiagnosticStore
import dev.whysoezzy.meet.service.push.DiagnosticInvalidation
import dev.whysoezzy.meet.service.push.DiagnosticSelection
import dev.whysoezzy.meet.service.push.PushInstallationStore
import dev.whysoezzy.meet.service.push.ReminderOffset
import dev.whysoezzy.meet.service.push.parseFid
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentMatchers.anyLong
import org.mockito.ArgumentMatchers.anyString
import org.mockito.Mockito.doAnswer
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.dao.DataAccessException
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.core.RowMapper
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean
import java.time.Instant
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MeetingReminderDiscoveryPostgresTest : IntegrationTestSupport() {
    @MockitoSpyBean
    private lateinit var observedJdbc: JdbcTemplate

    @MockitoSpyBean
    private lateinit var observedInstallationStore: PushInstallationStore

    @Autowired
    private lateinit var reminders: MeetingReminderStore

    @Autowired
    private lateinit var installations: PushInstallationService

    @Autowired
    private lateinit var transactionManager: PlatformTransactionManager

    @Autowired
    private lateinit var diagnosticStore: PushDiagnosticStore

    private var activeProbe: DiscoveryJdbcProbe? = null
    private val now = Instant.parse("2026-09-11T20:00:00Z")

    @BeforeEach
    fun clearDatabase() {
        activeProbe = null
        installDiscoveryProbe()
        resetDatabase()
    }

    @Test
    fun `discovery snapshots active fresh installations and is idempotent per offset`() {
        val fixture = fixture()
        val meetingTime = now.plusSeconds(3_600).toEpochMilli()
        jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", meetingTime, fixture.meeting.id)
        installations.register(requireNotNull(fixture.bob.id), parseFid("fid-bob"))

        val candidate = reminders.findCandidates(now).single()
        assertEquals(ReminderOffset.ONE_HOUR, candidate.offset)
        val claim = reminders.discover(candidate, now)

        assertNotNull(claim)
        assertEquals(1L, jdbcTemplate.queryForObject(
            "SELECT COUNT(*) FROM meeting_reminder_targets WHERE claim_id = ?",
            Long::class.java,
            claim.id,
        ))
        assertNull(reminders.discover(candidate, now))
        assertEquals(
            "PENDING",
            jdbcTemplate.queryForObject(
                "SELECT status FROM meeting_reminder_claims WHERE id = ?",
                String::class.java,
                claim.id,
            ),
        )
    }

    @Test
    fun `discovery rejects a candidate when mutable opt in changes before claim`() {
        val fixture = fixture()
        val meetingTime = now.plusSeconds(3_600).toEpochMilli()
        jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", meetingTime, fixture.meeting.id)
        installations.register(requireNotNull(fixture.bob.id), parseFid("fid-bob"))
        val candidate = reminders.findCandidates(now).single()
        jdbcTemplate.update("UPDATE users SET notifications_enabled = false WHERE id = ?", fixture.bob.id)

        assertNull(reminders.discover(candidate, now))
        assertEquals(
            0L,
            jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM meeting_reminder_claims",
                Long::class.java,
            ),
        )
    }

    @Test
    fun `discovery rechecks membership after the candidate snapshot`() {
        val fixture = fixture()
        val meetingTime = now.plusSeconds(3_600).toEpochMilli()
        jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", meetingTime, fixture.meeting.id)
        installations.register(requireNotNull(fixture.bob.id), parseFid("fid-bob"))
        val candidate = reminders.findCandidates(now).single()

        jdbcTemplate.update(
            "DELETE FROM meeting_participants WHERE user_id = ? AND meeting_id = ?",
            fixture.bob.id,
            fixture.meeting.id,
        )

        assertNull(reminders.discover(candidate, now))
        assertEquals(
            0L,
            jdbcTemplate.queryForObject("SELECT COUNT(*) FROM meeting_reminder_claims", Long::class.java),
        )
    }

    @Test
    fun `due and inclusive grace boundaries are executable for both reminder offsets`() {
        listOf(ReminderOffset.ONE_DAY to 1_440, ReminderOffset.ONE_HOUR to 60).forEach { (_, offsetMinutes) ->
            listOf(
                "exact due" to 0L,
                "exact grace" to 15 * 60_000L,
            ).forEach { (_, elapsedMs) ->
                resetDatabase()
                val fixture = fixture()
                val due = now.plusMillis(elapsedMs)
                val meetingTime = due.plusSeconds(offsetMinutes.toLong() * 60).toEpochMilli()
                jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", meetingTime, fixture.meeting.id)
                installations.register(requireNotNull(fixture.bob.id), parseFid("fid-$offsetMinutes-$elapsedMs"))

                val candidates = reminders.findCandidates(due)
                assertEquals(1, candidates.size)
                assertEquals(offsetMinutes, candidates.single().offset.minutes)
                assertNotNull(reminders.discover(candidates.single(), due))
            }
        }
    }

    @Test
    fun `discovery excludes one millisecond outside either due or grace boundary`() {
        resetDatabase()
        val beforeDueFixture = fixture()
        jdbcTemplate.update(
            "UPDATE meetings SET time = ? WHERE id = ?",
            now.plusSeconds(60 * 60).minusMillis(1).toEpochMilli(),
            beforeDueFixture.meeting.id,
        )
        installations.register(requireNotNull(beforeDueFixture.bob.id), parseFid("fid-before-due"))
        assertTrue(reminders.findCandidates(now).isEmpty())

        resetDatabase()
        val afterGraceFixture = fixture()
        jdbcTemplate.update(
            "UPDATE meetings SET time = ? WHERE id = ?",
            now.plusSeconds(60 * 60).toEpochMilli(),
            afterGraceFixture.meeting.id,
        )
        installations.register(requireNotNull(afterGraceFixture.bob.id), parseFid("fid-after-grace"))
        assertTrue(reminders.findCandidates(now.plusMillis(15 * 60_000L + 1)).isEmpty())
    }

    @Test
    fun `away and back start changes invalidate the captured candidate through the version trigger`() {
        val fixture = fixture()
        val meetingTime = now.plusSeconds(3_600).toEpochMilli()
        jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", meetingTime, fixture.meeting.id)
        installations.register(requireNotNull(fixture.bob.id), parseFid("fid-away-back"))
        val candidate = reminders.findCandidates(now).single()

        jdbcTemplate.update("UPDATE meetings SET time = time + 1000 WHERE id = ?", fixture.meeting.id)
        jdbcTemplate.update("UPDATE meetings SET time = time - 1000 WHERE id = ?", fixture.meeting.id)

        assertNull(reminders.discover(candidate, now))
        assertEquals(
            0L,
            jdbcTemplate.queryForObject("SELECT COUNT(*) FROM meeting_reminder_claims", Long::class.java),
        )
        assertEquals(
            candidate.startVersion + 2,
            jdbcTemplate.queryForObject(
                "SELECT push_start_version FROM meetings WHERE id = ?",
                Long::class.java,
                fixture.meeting.id,
            ),
        )
    }

    @Test
    fun `concurrent discovery has one durable claim winner and one complete snapshot`() {
        val fixture = fixture()
        val meetingTime = now.plusSeconds(3_600).toEpochMilli()
        jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", meetingTime, fixture.meeting.id)
        installations.register(requireNotNull(fixture.bob.id), parseFid("fid-concurrent"))
        val candidate = reminders.findCandidates(now).single()
        val transaction = TransactionTemplate(transactionManager)
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val futures = (1..2).map {
                executor.submit<ReminderClaimRecord?> {
                    assertTrue(start.await(10, TimeUnit.SECONDS))
                    transaction.execute { reminders.discover(candidate, now) }
                }
            }
            start.countDown()
            val results = futures.map { it.get(10, TimeUnit.SECONDS) }

            assertEquals(1, results.count { it != null })
            assertEquals(
                1L,
                jdbcTemplate.queryForObject("SELECT COUNT(*) FROM meeting_reminder_claims", Long::class.java),
            )
            assertEquals(
                1L,
                jdbcTemplate.queryForObject("SELECT COUNT(*) FROM meeting_reminder_targets", Long::class.java),
            )
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `discovery snapshot linearizes before a concurrent fid transfer and never crosses owners`() {
        val fixture = fixture()
        val meetingTime = now.plusSeconds(3_600).toEpochMilli()
        jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", meetingTime, fixture.meeting.id)
        val bobId = requireNotNull(fixture.bob.id)
        val aliceId = requireNotNull(fixture.alice.id)
        val fid = parseFid("fid-transfer-race")
        val original = installations.register(bobId, fid).installation
        val candidate = reminders.findCandidates(now).single()
        val probe = DiscoveryJdbcProbe(pauseFirstPage = true)
        activeProbe = probe
        val transaction = TransactionTemplate(transactionManager)
        val executor = Executors.newFixedThreadPool(2)

        try {
            val discovery = executor.submit<ReminderClaimRecord?> {
                transaction.execute { reminders.discover(candidate, now) }
            }
            assertTrue(probe.firstPageStarted.await(10, TimeUnit.SECONDS))

            // discover() already owns the candidate user's row lock before it
            // reaches this page query. The transfer can therefore only commit
            // after this snapshot transaction commits. Wait until register()
            // has reached its second owner lock (the candidate user) so this
            // is an actual overlap, rather than only task submission order.
            val transfer = executor.submit<PushInstallationMutation> {
                installations.register(aliceId, fid)
            }
            assertTrue(probe.transferLockAttempted.await(10, TimeUnit.SECONDS))
            probe.releaseFirstPage.countDown()

            val claim = requireNotNull(discovery.get(10, TimeUnit.SECONDS))
            val transferred = transfer.get(10, TimeUnit.SECONDS)
            val target = jdbcTemplate.queryForMap(
                "SELECT user_id, installation_id FROM meeting_reminder_targets WHERE claim_id = ?",
                claim.id,
            )

            assertEquals(bobId, target["user_id"])
            assertEquals(original.id, target["installation_id"])
            assertEquals(aliceId, transferred.installation.userId)
            assertEquals(
                1L,
                jdbcTemplate.queryForObject(
                    "SELECT COUNT(*) FROM push_installations WHERE user_id = ? AND fid = ? AND status = 'ACTIVE'",
                    Long::class.java,
                    aliceId,
                    fid.value,
                ),
            )
            assertEquals(
                0L,
                jdbcTemplate.queryForObject(
                    "SELECT COUNT(*) FROM meeting_reminder_targets t " +
                        "JOIN push_installations p ON p.id = t.installation_id " +
                        "WHERE t.claim_id = ? AND (t.user_id <> p.user_id OR p.user_id = ?)",
                    Long::class.java,
                    claim.id,
                    aliceId,
                ),
            )
        } finally {
            probe.releaseFirstPage.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `diagnostic invalidation waits for discovery snapshot owner lock`() {
        val fixture = fixture()
        val meetingTime = now.plusSeconds(3_600).toEpochMilli()
        jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", meetingTime, fixture.meeting.id)
        val userId = requireNotNull(fixture.bob.id)
        val fid = parseFid("fid-diagnostic-discovery-race")
        val installation = installations.register(userId, fid).installation
        val candidate = reminders.findCandidates(now).single()
        val selection = DiagnosticSelection(
            userId = userId,
            installationId = installation.id,
            meetingId = requireNotNull(fixture.meeting.id),
            fid = fid,
            registrationVersion = installation.registrationVersion,
        )
        val probe = DiscoveryJdbcProbe(pauseFirstPage = true)
        activeProbe = probe
        val transaction = TransactionTemplate(transactionManager)
        val diagnosticStarted = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)

        try {
            val discovery = executor.submit<ReminderClaimRecord?> {
                transaction.execute { reminders.discover(candidate, now) }
            }
            assertTrue(probe.firstPageStarted.await(10, TimeUnit.SECONDS))

            val invalidation = executor.submit<DiagnosticInvalidation> {
                diagnosticStarted.countDown()
                transaction.execute {
                    diagnosticStore.lockOwner(userId)
                    diagnosticStore.invalidateExact(selection, fid, installation.registrationVersion)
                } ?: error("diagnostic transaction did not run")
            }
            assertTrue(diagnosticStarted.await(10, TimeUnit.SECONDS))
            assertTrue(!invalidation.isDone)

            probe.releaseFirstPage.countDown()
            val claim = requireNotNull(discovery.get(10, TimeUnit.SECONDS))
            assertEquals(DiagnosticInvalidation.APPLIED, invalidation.get(10, TimeUnit.SECONDS))
            assertEquals(
                1L,
                jdbcTemplate.queryForObject(
                    "SELECT COUNT(*) FROM meeting_reminder_targets WHERE claim_id = ? AND user_id = ? AND installation_id = ?",
                    Long::class.java,
                    claim.id,
                    userId,
                    installation.id,
                ),
            )
            assertEquals(
                "UNREGISTERED",
                jdbcTemplate.queryForObject(
                    "SELECT status FROM push_installations WHERE id = ?",
                    String::class.java,
                    installation.id,
                ),
            )
        } finally {
            probe.releaseFirstPage.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `claim and target snapshot roll back together after an injected transaction failure`() {
        val fixture = fixture()
        val meetingTime = now.plusSeconds(3_600).toEpochMilli()
        jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", meetingTime, fixture.meeting.id)
        val userId = requireNotNull(fixture.bob.id)
        val timestamp = java.sql.Timestamp.from(now)
        val installationRows = (1..129).map { index ->
            arrayOf<Any>(
                UUID.nameUUIDFromBytes("rollback-installation-$index".toByteArray()),
                userId,
                "fid-rollback-$index",
                timestamp,
                timestamp,
                timestamp,
            )
        }
        jdbcTemplate.batchUpdate(
            """
            INSERT INTO push_installations
                (id, user_id, fid, status, registration_version, created_at, updated_at, last_seen_at, terminal_at)
            VALUES (?, ?, ?, 'ACTIVE', 1, ?, ?, ?, NULL)
            """.trimIndent(),
            installationRows,
        )
        val candidate = reminders.findCandidates(now).single()
        val transaction = TransactionTemplate(transactionManager)
        val suffix = UUID.randomUUID().toString().replace("-", "")
        val sequence = "test_snapshot_failure_$suffix"
        val function = "test_snapshot_failure_fn_$suffix"
        val trigger = "test_snapshot_failure_trigger_$suffix"
        jdbcTemplate.execute("CREATE SEQUENCE $sequence START WITH 1")
        jdbcTemplate.execute(
            """
            CREATE FUNCTION $function() RETURNS trigger
            LANGUAGE plpgsql AS $$
            BEGIN
                IF nextval('$sequence') > 1 THEN
                    RAISE EXCEPTION 'injected snapshot failure';
                END IF;
                RETURN NEW;
            END;
            $$;
            """.trimIndent(),
        )
        jdbcTemplate.execute(
            "CREATE TRIGGER $trigger BEFORE INSERT ON meeting_reminder_targets " +
                "FOR EACH ROW EXECUTE FUNCTION $function()",
        )

        try {
            assertFailsWith<DataAccessException> {
                transaction.execute {
                    reminders.discover(candidate, now)
                }
            }
        } finally {
            jdbcTemplate.execute("DROP TRIGGER $trigger ON meeting_reminder_targets")
            jdbcTemplate.execute("DROP FUNCTION $function()")
            jdbcTemplate.execute("DROP SEQUENCE $sequence")
        }

        assertEquals(0L, jdbcTemplate.queryForObject("SELECT COUNT(*) FROM meeting_reminder_claims", Long::class.java))
        assertEquals(0L, jdbcTemplate.queryForObject("SELECT COUNT(*) FROM meeting_reminder_targets", Long::class.java))
        val claim = requireNotNull(transaction.execute { reminders.discover(candidate, now) })
        assertEquals(
            129L,
            jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM meeting_reminder_targets WHERE claim_id = ?",
                Long::class.java,
                claim.id,
            ),
        )
    }

    @Test
    fun `high cardinality discovery uses a complete bounded keyset snapshot with no late append`() {
        val fixture = fixture()
        val meetingTime = now.plusSeconds(3_600).toEpochMilli()
        jdbcTemplate.update("UPDATE meetings SET time = ? WHERE id = ?", meetingTime, fixture.meeting.id)
        val userId = requireNotNull(fixture.bob.id)
        val installationCount = 257
        val timestamp = java.sql.Timestamp.from(now)
        val rows = (1..installationCount).map { index ->
            arrayOf<Any>(
                UUID.nameUUIDFromBytes("installation-$index".toByteArray()),
                userId,
                "fid-high-cardinality-$index",
                timestamp,
                timestamp,
                timestamp,
            )
        }
        jdbcTemplate.batchUpdate(
            """
            INSERT INTO push_installations
                (id, user_id, fid, status, registration_version, created_at, updated_at, last_seen_at, terminal_at)
            VALUES (?, ?, ?, 'ACTIVE', 1, ?, ?, ?, NULL)
            """.trimIndent(),
            rows,
        )
        val candidate = reminders.findCandidates(now).single()
        val probe = DiscoveryJdbcProbe(pauseFirstPage = false)
        activeProbe = probe
        val claim = requireNotNull(reminders.discover(candidate, now))

        jdbcTemplate.update(
            """
            INSERT INTO push_installations
                (id, user_id, fid, status, registration_version, created_at, updated_at, last_seen_at, terminal_at)
            VALUES (?, ?, ?, 'ACTIVE', 1, ?, ?, ?, NULL)
            """.trimIndent(),
            UUID.nameUUIDFromBytes("late-installation".toByteArray()),
            userId,
            "fid-late-after-snapshot",
            timestamp,
            timestamp,
            timestamp,
        )

        assertEquals(
            installationCount.toLong(),
            jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM meeting_reminder_targets WHERE claim_id = ?",
                Long::class.java,
                claim.id,
            ),
        )
        assertEquals(
            1L,
            jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM push_installations WHERE fid = 'fid-late-after-snapshot'",
                Long::class.java,
            ),
        )
        assertTrue(probe.pageQueries.get() >= 3)
        assertTrue(probe.pageSqls.all { "LIMIT 128" in it })
    }

    private fun installDiscoveryProbe() {
        val query = JdbcTemplate::class.java.getMethod(
            "query",
            String::class.java,
            RowMapper::class.java,
            Array<Any>::class.java,
        )
        // Calling the Java vararg overload reflectively lets Mockito match the
        // complete Object[] argument without changing JdbcTemplate's behavior.
        doAnswer { invocation ->
            activeProbe?.observe(invocation.getArgument<String>(0))
            invocation.callRealMethod()
        }.`when`(observedJdbc)
        query.invoke(
            observedJdbc,
            *arrayOf(anyString(), any(RowMapper::class.java), any(Array<Any>::class.java)),
        )
        doAnswer { invocation ->
            activeProbe?.observeTransferLock()
            invocation.callRealMethod()
        }.`when`(observedInstallationStore).lockUser(anyLong())
    }

    private class DiscoveryJdbcProbe(
        private val pauseFirstPage: Boolean,
    ) {
        val pageQueries = AtomicInteger()
        val pageSqls = mutableListOf<String>()
        val firstPageStarted = CountDownLatch(1)
        val releaseFirstPage = CountDownLatch(1)
        val transferLockAttempted = CountDownLatch(1)
        private val transferLockCalls = AtomicInteger()

        @Synchronized
        fun observe(sql: String) {
            val normalized = sql.replace(Regex("\\s+"), " ").trim().uppercase()
            if (!normalized.startsWith("SELECT ID, USER_ID FROM PUSH_INSTALLATIONS")) return

            pageQueries.incrementAndGet()
            pageSqls += normalized
            if (pauseFirstPage && pageQueries.get() == 1) {
                firstPageStarted.countDown()
                check(releaseFirstPage.await(10, TimeUnit.SECONDS))
            }
        }

        fun observeTransferLock() {
            if (transferLockCalls.incrementAndGet() == 2) {
                transferLockAttempted.countDown()
            }
        }
    }

}
