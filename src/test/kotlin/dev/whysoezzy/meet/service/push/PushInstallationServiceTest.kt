package dev.whysoezzy.meet.service.push

import dev.whysoezzy.meet.api.error.ConflictException
import dev.whysoezzy.meet.api.error.NotFoundException
import dev.whysoezzy.meet.api.error.PushUnavailableException
import org.junit.jupiter.api.Test
import org.mockito.Answers
import org.mockito.Mockito
import org.mockito.invocation.InvocationOnMock
import org.springframework.dao.DataAccessResourceFailureException
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.TransactionDefinition
import org.springframework.transaction.TransactionStatus
import org.springframework.transaction.support.SimpleTransactionStatus
import java.sql.SQLException
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

class PushInstallationServiceTest {
    private val now = Instant.parse("2026-09-11T20:00:00.123456Z")
    private val persistedNow = Instant.parse("2026-09-11T20:00:00.123Z")
    private val clock = Clock.fixed(now, ZoneOffset.UTC)
    private val id = UUID.fromString("123e4567-e89b-12d3-a456-426614174000")
    private val otherId = UUID.fromString("123e4567-e89b-12d3-a456-426614174001")

    @Test
    fun `register creates new row with caller as locked owner`() {
        val created = record(id, 7, "new-fid")
        var insertedId: UUID? = null
        val calls = mutableListOf<String>()
        val store = store { call ->
            calls += call.method.name
            when (call.method.name) {
                "ownerIdsForFid", "installationIdsForFid" -> emptyList<Any>()
                "findByFid" -> null
                "insert" -> {
                    insertedId = call.getArgument(0)
                    assertEquals(7L, call.getArgument(1))
                    assertEquals(parseFid("new-fid"), call.getArgument(2))
                    assertEquals(persistedNow, call.getArgument(3))
                    created.copy(id = insertedId!!)
                }
                else -> defaults(call)
            }
        }

        val result = service(store).register(7, parseFid("new-fid"))

        assertTrue(result.created)
        assertEquals(insertedId, result.installation.id)
        assertEquals(InstallationStatus.ACTIVE, result.installation.status)
        assertTrue(calls.indexOf("lockUser") < calls.indexOf("insert"))
        Mockito.verify(store).lockUser(7)
        Mockito.verify(store).lockInstallations(emptyList())
    }

    @Test
    fun `register heartbeat preserves UUID FID status and generation`() {
        val current = record(id, 7, "same-fid", version = 9)
        val heartbeat = current.copy(updatedAt = persistedNow, lastSeenAt = persistedNow)
        val store = store { call ->
            when (call.method.name) {
                "ownerIdsForFid" -> listOf(7L)
                "installationIdsForFid" -> listOf(id)
                "findByFid" -> current
                "heartbeat" -> heartbeat
                else -> defaults(call)
            }
        }

        val result = service(store).register(7, parseFid("same-fid"))

        assertFalse(result.created)
        assertEquals(id, result.installation.id)
        assertEquals("same-fid", result.installation.fid?.value)
        assertEquals(InstallationStatus.ACTIVE, result.installation.status)
        assertEquals(9, result.installation.registrationVersion)
        assertEquals(persistedNow, result.installation.lastSeenAt)
        Mockito.verify(store).heartbeat(id, 7, persistedNow)
        verifyNoActivate(store)
        verifyNoTransfer(store)
    }

    @Test
    fun `register transfer locks owners ascending retires source then creates fresh UUID`() {
        val old = record(id, 7, "transfer-fid")
        val created = record(otherId, 8, "transfer-fid")
        val lockedUsers = mutableListOf<Long>()
        val mutations = mutableListOf<String>()
        val store = store { call ->
            when (call.method.name) {
                "ownerIdsForFid" -> listOf(7L)
                "installationIdsForFid" -> listOf(id)
                "findByFid" -> old
                "lockUser" -> {
                    lockedUsers += call.getArgument<Long>(0)
                    null
                }
                "transfer" -> {
                    mutations += "transfer"
                    1
                }
                "insert" -> {
                    mutations += "insert"
                    created
                }
                else -> defaults(call)
            }
        }

        val result = service(store).register(8, parseFid("transfer-fid"))

        assertTrue(result.created)
        assertEquals(created, result.installation)
        assertEquals(listOf(7L, 8L), lockedUsers)
        assertEquals(listOf("transfer", "insert"), mutations)
        Mockito.verify(store).lockInstallations(listOf(id))
        Mockito.verify(store).transfer(id, persistedNow)
    }

    @Test
    fun `rotate and all permitted reactivations preserve UUID and advance generation`() {
        listOf(
            InstallationStatus.ACTIVE to "same-fid",
            InstallationStatus.UNREGISTERED to null,
            InstallationStatus.INVALID to null,
            InstallationStatus.EXPIRED to null,
        ).forEach { (status, oldFid) ->
            val current = record(id, 7, oldFid, status, version = 4)
            val activated = record(id, 7, "replacement-$status", version = 5)
            val store = rotationStore(
                current,
                activated,
                if (status == InstallationStatus.ACTIVE) current else null,
            )

            val result = service(store).rotate(7, id, activated.fid!!)

            assertFalse(result.created)
            assertEquals(id, result.installation.id, status.name)
            assertEquals(InstallationStatus.ACTIVE, result.installation.status, status.name)
            assertEquals(5, result.installation.registrationVersion, status.name)
            Mockito.verify(store).activate(id, 7, activated.fid!!, persistedNow)
            verifyNoTransfer(store)
        }
    }

    @Test
    fun `rotate retires conflicting holder before activating owned UUID`() {
        val current = record(id, 8, "old-fid", version = 2)
        val conflict = record(otherId, 7, "new-fid", version = 4)
        val activated = record(id, 8, "new-fid", version = 3)
        val lockedUsers = mutableListOf<Long>()
        val mutations = mutableListOf<String>()
        val store = store { call ->
            when (call.method.name) {
                "ownerIdsForFid" -> listOf(7L)
                "installationIdsForFid" -> listOf(otherId)
                "lockUser" -> {
                    lockedUsers += call.getArgument<Long>(0)
                    null
                }
                "findById" -> current
                "findByFid" -> conflict
                "transfer" -> {
                    mutations += "transfer"
                    1
                }
                "activate" -> {
                    mutations += "activate"
                    activated
                }
                else -> defaults(call)
            }
        }

        val result = service(store).rotate(8, id, parseFid("new-fid"))

        assertEquals(activated, result.installation)
        assertEquals(listOf(7L, 8L), lockedUsers)
        assertEquals(listOf("transfer", "activate"), mutations)
        Mockito.verify(store).lockInstallations(listOf(id, otherId))
    }

    @Test
    fun `rotate hides unknown foreign transferred and account-deleted rows`() {
        listOf(
            null,
            record(id, 8, "foreign"),
            record(id, 7, null, InstallationStatus.TRANSFERRED),
            record(id, 7, null, InstallationStatus.ACCOUNT_DELETED),
        ).forEach { current ->
            val store = store { call ->
                when (call.method.name) {
                    "ownerIdsForFid", "installationIdsForFid" -> emptyList<Any>()
                    "findById" -> current
                    else -> defaults(call)
                }
            }

            val failure = assertFailsWith<NotFoundException> {
                service(store).rotate(7, id, parseFid("replacement"))
            }
            assertEquals("NOT_FOUND", failure.code)
            verifyNoActivate(store)
        }
    }

    @Test
    fun `rotate rechecks owner after installation locking`() {
        val beforeLock = record(id, 7, "old-fid")
        val afterLock = beforeLock.copy(userId = 8)
        var reads = 0
        val store = store { call ->
            when (call.method.name) {
                "ownerIdsForFid", "installationIdsForFid" -> emptyList<Any>()
                "findById" -> if (reads++ == 0) beforeLock else afterLock
                else -> defaults(call)
            }
        }

        assertFailsWith<NotFoundException> {
            service(store).rotate(7, id, parseFid("replacement"))
        }
        Mockito.verify(store).lockInstallations(listOf(id))
        verifyNoActivate(store)
    }

    @Test
    fun `rotate rejects a status change observed by the locked read`() {
        val initial = record(id, 7, "old-fid")
        val locked = initial.copy(status = InstallationStatus.TRANSFERRED, fid = null)
        val store = store { call ->
            when (call.method.name) {
                "ownerIdsForFid", "installationIdsForFid" -> emptyList<Any>()
                "findById" -> if (call.getArgument<Boolean>(1)) locked else initial
                else -> defaults(call)
            }
        }

        assertFailsWith<NotFoundException> {
            service(store).rotate(7, id, parseFid("replacement"))
        }
        verifyNoActivate(store)
        verifyNoTransfer(store)
    }

    @Test
    fun `rotate treats a null activation result as a failed mutation without transfer`() {
        val current = record(id, 7, "old-fid")
        val store = store { call ->
            when (call.method.name) {
                "ownerIdsForFid", "installationIdsForFid" -> emptyList<Any>()
                "findById" -> current
                "findByFid" -> null
                "activate" -> null
                else -> defaults(call)
            }
        }

        assertFailsWith<IllegalArgumentException> {
            service(store).rotate(7, id, parseFid("replacement"))
        }
        Mockito.verify(store).activate(id, 7, parseFid("replacement"), persistedNow)
        verifyNoTransfer(store)
    }

    @Test
    fun `unregister clears ACTIVE once accepts repeat cleanup and hides forbidden rows`() {
        val activeStore = store { call ->
            when (call.method.name) {
                "findById" -> record(id, 7, "active-fid")
                "unregister" -> true
                else -> defaults(call)
            }
        }
        service(activeStore).unregister(7, id)
        Mockito.verify(activeStore).lockUser(7)
        Mockito.verify(activeStore).unregister(id, 7, persistedNow)

        listOf(
            InstallationStatus.UNREGISTERED,
            InstallationStatus.INVALID,
            InstallationStatus.EXPIRED,
        ).forEach { status ->
            val store = store { call ->
                if (call.method.name == "findById") record(id, 7, null, status) else defaults(call)
            }
            service(store).unregister(7, id)
            verifyNoUnregister(store)
        }

        listOf(
            null,
            record(id, 8, "foreign"),
            record(id, 7, null, InstallationStatus.TRANSFERRED),
            record(id, 7, null, InstallationStatus.ACCOUNT_DELETED),
        ).forEach { current ->
            val store = store { call ->
                if (call.method.name == "findById") current else defaults(call)
            }
            assertFailsWith<NotFoundException> { service(store).unregister(7, id) }
            verifyNoUnregister(store)
        }
    }

    @Test
    fun `unregister retries each retryable SQL state and sanitizes exhaustion`() {
        listOf("23505", "40001", "40P01").forEach { state ->
            var attempts = 0
            val transactions = RecordingTransactionManager()
            val store = store { call ->
                when (call.method.name) {
                    "setLockTimeout" -> {
                        if (attempts++ == 0) throw SQLException("retryable detail", state)
                        null
                    }
                    "findById" -> record(id, 7, "active-fid")
                    "unregister" -> true
                    else -> defaults(call)
                }
            }

            service(store, transactions).unregister(7, id)

            assertEquals(2, attempts, state)
            assertEquals(2, transactions.begins, state)
            assertEquals(1, transactions.rollbacks, state)
            assertEquals(1, transactions.commits, state)
            Mockito.verify(store).unregister(id, 7, persistedNow)
        }

        val transactions = RecordingTransactionManager()
        val exhaustedStore = store { call ->
            if (call.method.name == "setLockTimeout") {
                throw SQLException("secret retry detail", "40P01")
            }
            defaults(call)
        }

        val failure = assertFailsWith<PushUnavailableException> {
            service(exhaustedStore, transactions).unregister(7, id)
        }
        assertEquals("PUSH_UNAVAILABLE", failure.code)
        assertFalse(failure.message.orEmpty().contains("secret retry detail"))
        assertEquals(3, transactions.begins)
        assertEquals(3, transactions.rollbacks)
        Mockito.verify(exhaustedStore, Mockito.times(3)).setLockTimeout()
    }

    @Test
    fun `heartbeat then same-FID rotation advances ABA fence exactly once`() {
        var state = record(id, 7, "aba-fid", version = 11)
        val store = store { call ->
            when (call.method.name) {
                "ownerIdsForFid" -> listOf(7L)
                "installationIdsForFid" -> listOf(id)
                "findByFid", "findById" -> state
                "heartbeat" -> state.copy(
                    updatedAt = persistedNow,
                    lastSeenAt = persistedNow,
                ).also { state = it }
                "activate" -> state.copy(
                    registrationVersion = state.registrationVersion + 1,
                    updatedAt = persistedNow,
                    lastSeenAt = persistedNow,
                ).also { state = it }
                else -> defaults(call)
            }
        }
        val service = service(store)

        val heartbeat = service.register(7, parseFid("aba-fid"))
        val rotation = service.rotate(7, id, parseFid("aba-fid"))

        assertEquals(id, heartbeat.installation.id)
        assertEquals(id, rotation.installation.id)
        assertEquals("aba-fid", heartbeat.installation.fid?.value)
        assertEquals("aba-fid", rotation.installation.fid?.value)
        assertEquals(11, heartbeat.installation.registrationVersion)
        assertEquals(12, rotation.installation.registrationVersion)
    }

    @Test
    fun `owner-set change reruns whole transaction and stable retry succeeds`() {
        var ownerReads = 0
        var inserts = 0
        val transactions = RecordingTransactionManager()
        val created = record(otherId, 9, "race-fid")
        val store = store { call ->
            when (call.method.name) {
                "ownerIdsForFid" -> when (ownerReads++) {
                    0 -> listOf(7L)
                    1 -> listOf(7L, 8L)
                    else -> listOf(7L, 8L)
                }
                "installationIdsForFid" -> emptyList<UUID>()
                "findByFid" -> null
                "insert" -> {
                    inserts++
                    created
                }
                else -> defaults(call)
            }
        }

        assertEquals(created, service(store, transactions).register(9, parseFid("race-fid")).installation)
        assertEquals(2, transactions.begins)
        assertEquals(1, transactions.rollbacks)
        assertEquals(1, transactions.commits)
        assertTrue(transactions.timeouts.all { it == 5 })
        assertEquals(1, inserts)
        Mockito.verify(store, Mockito.atLeastOnce()).lockUser(8)
    }

    @Test
    fun `owner-set churn exhausts three transactions as sanitized unavailable`() {
        var reads = 0
        val transactions = RecordingTransactionManager()
        val store = store { call ->
            if (call.method.name == "ownerIdsForFid") {
                if (reads++ % 2 == 0) listOf(7L) else listOf(7L, 8L)
            } else {
                defaults(call)
            }
        }

        val failure = assertFailsWith<PushUnavailableException> {
            service(store, transactions).register(9, parseFid("churn-fid"))
        }
        assertEquals("PUSH_UNAVAILABLE", failure.code)
        assertEquals(3, transactions.begins)
        assertEquals(3, transactions.rollbacks)
        verifyNoInsert(store)
    }

    @Test
    fun `all SQL retry states and wrapped causes rerun complete transactions`() {
        listOf("23505", "40001", "40P01").forEach { state ->
            var attempts = 0
            val transactions = RecordingTransactionManager()
            val created = record(otherId, 7, "fid-$state")
            val store = store { call ->
                when (call.method.name) {
                    "setLockTimeout" -> {
                        if (attempts++ == 0) throw SQLException("redacted", state)
                        null
                    }
                    "ownerIdsForFid", "installationIdsForFid" -> emptyList<Any>()
                    "findByFid" -> null
                    "insert" -> created
                    else -> defaults(call)
                }
            }

            assertEquals(created, service(store, transactions).register(7, parseFid("fid-$state")).installation)
            assertEquals(2, attempts, state)
            assertEquals(2, transactions.begins, state)
            assertEquals(1, transactions.rollbacks, state)
            assertEquals(1, transactions.commits, state)
        }

        var attempts = 0
        val created = record(otherId, 7, "wrapped-fid")
        val store = store { call ->
            when (call.method.name) {
                "setLockTimeout" -> {
                    if (attempts++ == 0) {
                        throw IllegalStateException(
                            "wrapper",
                            DataAccessResourceFailureException(
                                "jdbc",
                                SQLException("secret detail", "40P01"),
                            ),
                        )
                    }
                    null
                }
                "ownerIdsForFid", "installationIdsForFid" -> emptyList<Any>()
                "findByFid" -> null
                "insert" -> created
                else -> defaults(call)
            }
        }
        assertEquals(created, service(store).register(7, parseFid("wrapped-fid")).installation)
        assertEquals(2, attempts)
    }

    @Test
    fun `rotation uniqueness contention reruns pre-read locks and activation`() {
        val current = record(id, 7, "old-fid", version = 3)
        val activated = record(id, 7, "new-fid", version = 4)
        val transactions = RecordingTransactionManager()
        var reads = 0
        var lockPasses = 0
        var activations = 0
        val store = store { call ->
            when (call.method.name) {
                "ownerIdsForFid", "installationIdsForFid" -> emptyList<Any>()
                "findById" -> {
                    reads++
                    current
                }
                "lockInstallations" -> {
                    lockPasses++
                    null
                }
                "findByFid" -> null
                "activate" -> {
                    if (activations++ == 0) throw SQLException("unique contention", "23505")
                    activated
                }
                else -> defaults(call)
            }
        }

        val result = service(store, transactions).rotate(7, id, parseFid("new-fid"))

        assertEquals(activated, result.installation)
        assertEquals(2, transactions.begins)
        assertEquals(1, transactions.rollbacks)
        assertEquals(4, reads)
        assertEquals(2, lockPasses)
        assertEquals(2, activations)
    }

    @Test
    fun `retry exhaustion sanitizes and nonretryable or domain failures never rerun`() {
        val transactions = RecordingTransactionManager()
        val exhaustedStore = store { call ->
            if (call.method.name == "setLockTimeout") {
                throw SQLException("secret database detail", "40001")
            }
            defaults(call)
        }
        val exhausted = assertFailsWith<PushUnavailableException> {
            service(exhaustedStore, transactions).register(7, parseFid("exhausted"))
        }
        assertEquals("PUSH_UNAVAILABLE", exhausted.code)
        assertFalse(exhausted.message.orEmpty().contains("secret"))
        assertEquals(3, transactions.begins)
        Mockito.verify(exhaustedStore, Mockito.times(3)).setLockTimeout()

        listOf<RuntimeException>(
            DataAccessResourceFailureException("constraint", SQLException("detail", "23514")),
            IllegalStateException("programming failure"),
            ConflictException("blocked"),
            NotFoundException("missing"),
        ).forEach { expected ->
            val manager = RecordingTransactionManager()
            val store = store { call ->
                if (call.method.name == "setLockTimeout") throw expected
                defaults(call)
            }
            val actual = assertFailsWith<RuntimeException> {
                service(store, manager).register(7, parseFid("not-retried"))
            }
            assertSame(expected, actual)
            assertEquals(1, manager.begins)
            assertEquals(1, manager.rollbacks)
        }
    }

    @Test
    fun `FID parser enforces blank NUL malformed and UTF-8 byte boundaries without trimming`() {
        assertFailsWith<IllegalArgumentException> { parseFid(" \t\r\n") }
        assertFailsWith<IllegalArgumentException> { parseFid("a\u0000b") }
        assertFailsWith<IllegalArgumentException> { parseFid("\uD800") }
        assertFailsWith<IllegalArgumentException> { parseFid("é".repeat(513)) }
        assertEquals("é".repeat(512), parseFid("é".repeat(512)).value)
        assertEquals(" fid ", parseFid(" fid ").value)
    }

    private fun rotationStore(
        current: PushInstallationRecord,
        activated: PushInstallationRecord,
        holder: PushInstallationRecord?,
    ) = store { call ->
        when (call.method.name) {
            "ownerIdsForFid", "installationIdsForFid" -> emptyList<Any>()
            "findById" -> current
            "findByFid" -> holder
            "activate" -> activated
            else -> defaults(call)
        }
    }

    private fun service(
        store: PushInstallationStore,
        transactions: PlatformTransactionManager = ImmediateTransactionManager(),
    ) = PushInstallationService(store, transactions, clock)

    private fun record(
        id: UUID,
        userId: Long,
        fid: String?,
        status: InstallationStatus = InstallationStatus.ACTIVE,
        version: Long = 1,
    ) = PushInstallationRecord(
        id = id,
        userId = userId,
        fid = fid?.let(::parseFid),
        status = status,
        registrationVersion = version,
        createdAt = persistedNow,
        updatedAt = persistedNow,
        lastSeenAt = persistedNow,
        terminalAt = if (status == InstallationStatus.ACTIVE) null else persistedNow,
    )

    private fun store(answer: (InvocationOnMock) -> Any?): PushInstallationStore =
        Mockito.mock(PushInstallationStore::class.java) { call -> answer(call) }

    private fun defaults(call: InvocationOnMock): Any? = Answers.RETURNS_DEFAULTS.answer(call)

    private fun verifyNoActivate(store: PushInstallationStore) {
        Mockito.verify(store, Mockito.never()).activate(
            Mockito.any(UUID::class.java) ?: id,
            Mockito.anyLong(),
            Mockito.any(PushFid::class.java) ?: parseFid("matcher"),
            Mockito.any(Instant::class.java) ?: persistedNow,
        )
    }

    private fun verifyNoTransfer(store: PushInstallationStore) {
        Mockito.verify(store, Mockito.never()).transfer(
            Mockito.any(UUID::class.java) ?: id,
            Mockito.any(Instant::class.java) ?: persistedNow,
        )
    }

    private fun verifyNoUnregister(store: PushInstallationStore) {
        Mockito.verify(store, Mockito.never()).unregister(
            Mockito.any(UUID::class.java) ?: id,
            Mockito.anyLong(),
            Mockito.any(Instant::class.java) ?: persistedNow,
        )
    }

    private fun verifyNoInsert(store: PushInstallationStore) {
        Mockito.verify(store, Mockito.never()).insert(
            Mockito.any(UUID::class.java) ?: id,
            Mockito.anyLong(),
            Mockito.any(PushFid::class.java) ?: parseFid("matcher"),
            Mockito.any(Instant::class.java) ?: persistedNow,
        )
    }

    private class ImmediateTransactionManager : PlatformTransactionManager {
        override fun getTransaction(definition: TransactionDefinition?): TransactionStatus = SimpleTransactionStatus()
        override fun commit(status: TransactionStatus) = Unit
        override fun rollback(status: TransactionStatus) = Unit
    }

    private class RecordingTransactionManager : PlatformTransactionManager {
        var begins = 0
        var commits = 0
        var rollbacks = 0
        val timeouts = mutableListOf<Int>()

        override fun getTransaction(definition: TransactionDefinition?): TransactionStatus {
            begins++
            timeouts += requireNotNull(definition).timeout
            return SimpleTransactionStatus()
        }

        override fun commit(status: TransactionStatus) {
            commits++
        }

        override fun rollback(status: TransactionStatus) {
            rollbacks++
        }
    }
}
