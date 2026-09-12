package dev.whysoezzy.meet.service.push

import dev.whysoezzy.meet.api.error.BadRequestException
import dev.whysoezzy.meet.api.error.NotFoundException
import dev.whysoezzy.meet.api.error.PushUnavailableException
import org.junit.jupiter.api.Test
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.TransactionDefinition
import org.springframework.transaction.TransactionStatus
import org.springframework.transaction.support.SimpleTransactionStatus
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

class PushDiagnosticServiceTest {
    private val now = Instant.parse("2026-09-11T20:00:00.123456Z")
    private val clock = Clock.fixed(now, ZoneOffset.UTC)
    private val installationId = UUID.fromString("123e4567-e89b-12d3-a456-426614174000")

    @Test
    fun `validation rejects nonpositive IDs and unsupported offsets before selection`() {
        listOf(
            command(userId = 0),
            command(userId = -1),
            command(meetingId = 0),
            command(meetingId = -1),
            command(offset = 59),
            command(offset = 61),
            command(offset = 1_439),
            command(offset = 1_441),
        ).forEach { command ->
            val store = RecordingStore(selection())
            val provider = QueueProvider(PushDeliveryResult.Accepted)

            val failure = assertFailsWith<BadRequestException> {
                service(store, provider).send(command)
            }

            assertEquals("BAD_REQUEST", failure.code)
            assertTrue(store.calls.isEmpty())
            assertTrue(provider.messages.isEmpty())
        }
    }

    @Test
    fun `selection receives exact target and clock while ineligible is indistinguishable not-found`() {
        val command = command(userId = 7, meetingId = 42, offset = 1_440)
        val store = RecordingStore(null)
        val provider = QueueProvider(PushDeliveryResult.Accepted)
        val transactions = RecordingTransactionManager()

        val failure = assertFailsWith<NotFoundException> {
            service(store, provider, transactions).send(command)
        }

        assertEquals("NOT_FOUND", failure.code)
        assertEquals(command, store.selectedCommand)
        assertEquals(now, store.selectionTime)
        assertEquals(listOf("select"), store.calls)
        assertTrue(provider.messages.isEmpty())
        assertEquals(1, transactions.begins)
        assertEquals(1, transactions.commits)
    }

    @Test
    fun `selection infrastructure failure is sanitized and releases permit`() {
        val store = RecordingStore(selection()).apply {
            selectFailure = IllegalStateException("database secret")
        }
        val provider = QueueProvider(PushDeliveryResult.Accepted)
        val service = service(store, provider)

        repeat(2) {
            val failure = assertFailsWith<PushUnavailableException> { service.send(command()) }
            assertEquals("PUSH_UNAVAILABLE", failure.code)
            assertFalse(failure.message.orEmpty().contains("database secret"))
        }
        assertTrue(provider.messages.isEmpty())
    }

    @Test
    fun `single maps every noninvalid typed provider outcome`() {
        listOf(
            PushDeliveryResult.Accepted to DiagnosticCallResult.Accepted,
            PushDeliveryResult.TransientFailure to DiagnosticCallResult.RetryableFailure,
            PushDeliveryResult.Unavailable to DiagnosticCallResult.ProviderUnavailable,
        ).forEach { (providerResult, expected) ->
            val selected = selection()
            val store = RecordingStore(selected)
            val provider = QueueProvider(providerResult)

            val response = service(store, provider).send(command()) as PushDiagnosticResponse.Single

            assertEquals(expected, response.result)
            assertEquals(listOf("select"), store.calls)
            assertEquals(listOf(selected.fid), provider.fids)
        }
    }

    @Test
    fun `single invalid target uses exact registration invalidation outcomes`() {
        listOf(
            DiagnosticInvalidation.APPLIED,
            DiagnosticInvalidation.ALREADY_CHANGED,
        ).forEach { invalidation ->
            val selected = selection(version = 17)
            val store = RecordingStore(selected).apply { invalidations += invalidation }
            val provider = QueueProvider(PushDeliveryResult.InvalidRegistration)

            val response = service(store, provider).send(command()) as PushDiagnosticResponse.Single

            assertEquals(DiagnosticCallResult.InvalidTarget, response.result)
            assertEquals(listOf("select", "lockOwner", "invalidate"), store.calls)
            assertEquals(selected, store.invalidatedSelection)
            assertEquals(selected.fid, store.expectedFid)
            assertEquals(17, store.expectedVersion)
        }
    }

    @Test
    fun `single invalidation failure cannot claim cleanup success`() {
        val store = RecordingStore(selection()).apply {
            invalidations += DiagnosticInvalidation.FAILED
        }
        val provider = QueueProvider(PushDeliveryResult.InvalidRegistration)

        val failure = assertFailsWith<PushUnavailableException> {
            service(store, provider).send(command())
        }

        assertEquals("PUSH_UNAVAILABLE", failure.code)
        assertEquals(1, provider.messages.size)
    }

    @Test
    fun `single local provider failure is sanitized unavailable`() {
        val failure = assertFailsWith<PushUnavailableException> {
            service(
                RecordingStore(selection()),
                QueueProvider(IllegalStateException("provider secret")),
            ).send(command())
        }
        assertEquals("PUSH_UNAVAILABLE", failure.code)
        assertFalse(failure.message.orEmpty().contains("provider secret"))
    }

    @Test
    fun `all ordered typed pair outcomes are categorized`() {
        val first = listOf(
            PushDeliveryResult.Accepted to DiagnosticCallResult.Accepted,
            PushDeliveryResult.TransientFailure to DiagnosticCallResult.RetryableFailure,
            PushDeliveryResult.Unavailable to DiagnosticCallResult.ProviderUnavailable,
        )
        val second = listOf(
            PushDeliveryResult.Accepted to DiagnosticCallResult.Accepted,
            PushDeliveryResult.InvalidRegistration to DiagnosticCallResult.InvalidTarget,
            PushDeliveryResult.TransientFailure to DiagnosticCallResult.RetryableFailure,
            PushDeliveryResult.Unavailable to DiagnosticCallResult.ProviderUnavailable,
        )

        first.forEach { (firstProvider, firstExpected) ->
            second.forEach { (secondProvider, secondExpected) ->
                val store = RecordingStore(selection()).apply {
                    invalidations += DiagnosticInvalidation.APPLIED
                }
                val provider = QueueProvider(firstProvider, secondProvider)

                val response = service(store, provider).send(
                    command(mode = PushDiagnosticMode.DEDUP_PAIR),
                ) as PushDiagnosticResponse.Pair

                assertEquals(firstExpected, response.first)
                assertEquals(secondExpected, response.second)
                assertEquals(
                    if (
                        firstExpected == DiagnosticCallResult.Accepted &&
                        secondExpected == DiagnosticCallResult.Accepted
                    ) {
                        DiagnosticAggregateResult.ACCEPTED_PAIR
                    } else {
                        DiagnosticAggregateResult.INCONCLUSIVE
                    },
                    response.result,
                )
                assertEquals(2, provider.messages.size)
                assertEquals(
                    if (secondProvider == PushDeliveryResult.InvalidRegistration) {
                        listOf("select", "recheck", "lockOwner", "invalidate")
                    } else {
                        listOf("select", "recheck")
                    },
                    store.calls,
                )
            }
        }
    }

    @Test
    fun `first invalid target stops pair for every invalidation outcome`() {
        DiagnosticInvalidation.entries.forEach { invalidation ->
            val store = RecordingStore(selection()).apply {
                invalidations += invalidation
                if (invalidation == DiagnosticInvalidation.APPLIED) rechecked = null
            }
            val provider = QueueProvider(
                PushDeliveryResult.InvalidRegistration,
                PushDeliveryResult.Accepted,
            )

            val response = service(store, provider).send(
                command(mode = PushDiagnosticMode.DEDUP_PAIR),
            ) as PushDiagnosticResponse.Pair

            assertEquals(DiagnosticAggregateResult.INCONCLUSIVE, response.result)
            assertEquals(DiagnosticCallResult.InvalidTarget, response.first)
            assertEquals(DiagnosticCallResult.NotAttempted, response.second)
            assertEquals(1, provider.messages.size)
            if (invalidation == DiagnosticInvalidation.APPLIED) {
                assertEquals(listOf("select", "lockOwner", "invalidate", "recheck"), store.calls)
            } else {
                assertFalse(store.calls.contains("recheck"))
            }
        }
    }

    @Test
    fun `second invalid target preserves ordered result for every invalidation outcome`() {
        DiagnosticInvalidation.entries.forEach { invalidation ->
            val store = RecordingStore(selection()).apply { invalidations += invalidation }
            val provider = QueueProvider(
                PushDeliveryResult.Accepted,
                PushDeliveryResult.InvalidRegistration,
            )

            val response = service(store, provider).send(
                command(mode = PushDiagnosticMode.DEDUP_PAIR),
            ) as PushDiagnosticResponse.Pair

            assertEquals(DiagnosticAggregateResult.INCONCLUSIVE, response.result)
            assertEquals(DiagnosticCallResult.Accepted, response.first)
            assertEquals(DiagnosticCallResult.InvalidTarget, response.second)
            assertEquals(2, provider.messages.size)
            assertEquals(listOf("select", "recheck", "lockOwner", "invalidate"), store.calls)
        }
    }

    @Test
    fun `recheck null changed FID and changed version stop before call two`() {
        val selected = selection(version = 5)
        listOf<DiagnosticSelection?>(
            null,
            selected.copy(fid = parseFid("replacement-fid")),
            selected.copy(registrationVersion = 6),
        ).forEach { rechecked ->
            val store = RecordingStore(selected).apply { this.rechecked = rechecked }
            val provider = QueueProvider(
                PushDeliveryResult.Accepted,
                PushDeliveryResult.Accepted,
            )

            val response = service(store, provider).send(
                command(mode = PushDiagnosticMode.DEDUP_PAIR),
            ) as PushDiagnosticResponse.Pair

            assertEquals(DiagnosticCallResult.Accepted, response.first)
            assertEquals(DiagnosticCallResult.NotAttempted, response.second)
            assertEquals(DiagnosticAggregateResult.INCONCLUSIVE, response.result)
            assertEquals(1, provider.messages.size)
            assertEquals(listOf("select", "recheck"), store.calls)
        }
    }

    @Test
    fun `recheck failure is sanitized and never starts call two`() {
        val store = RecordingStore(selection()).apply {
            recheckFailure = IllegalStateException("recheck secret")
        }
        val provider = QueueProvider(
            PushDeliveryResult.Accepted,
            PushDeliveryResult.Accepted,
        )

        val failure = assertFailsWith<PushUnavailableException> {
            service(store, provider).send(command(mode = PushDiagnosticMode.DEDUP_PAIR))
        }

        assertEquals("PUSH_UNAVAILABLE", failure.code)
        assertFalse(failure.message.orEmpty().contains("recheck secret"))
        assertEquals(1, provider.messages.size)
    }

    @Test
    fun `local failure on either pair call preserves known ordered categories`() {
        val firstProvider = QueueProvider(IllegalStateException("first failure"))
        val firstStore = RecordingStore(selection())
        val first = service(firstStore, firstProvider).send(
            command(mode = PushDiagnosticMode.DEDUP_PAIR),
        ) as PushDiagnosticResponse.Pair
        assertEquals(DiagnosticCallResult.ProviderUnavailable, first.first)
        assertEquals(DiagnosticCallResult.NotAttempted, first.second)
        assertEquals(DiagnosticAggregateResult.INCONCLUSIVE, first.result)
        assertEquals(1, firstProvider.messages.size)
        assertEquals(listOf("select"), firstStore.calls)

        val secondProvider = QueueProvider(
            PushDeliveryResult.Accepted,
            IllegalStateException("second failure"),
        )
        val secondStore = RecordingStore(selection())
        val second = service(secondStore, secondProvider).send(
            command(mode = PushDiagnosticMode.DEDUP_PAIR),
        ) as PushDiagnosticResponse.Pair
        assertEquals(DiagnosticCallResult.Accepted, second.first)
        assertEquals(DiagnosticCallResult.ProviderUnavailable, second.second)
        assertEquals(DiagnosticAggregateResult.INCONCLUSIVE, second.result)
        assertEquals(2, secondProvider.messages.size)
        assertEquals(listOf("select", "recheck"), secondStore.calls)
    }

    @Test
    fun `dedup pair reuses exact immutable message and selected registration`() {
        val selected = selection()
        val provider = QueueProvider(
            PushDeliveryResult.Accepted,
            PushDeliveryResult.Accepted,
        )

        val response = service(RecordingStore(selected), provider).send(
            command(mode = PushDiagnosticMode.DEDUP_PAIR),
        ) as PushDiagnosticResponse.Pair

        assertEquals(DiagnosticAggregateResult.ACCEPTED_PAIR, response.result)
        assertSame(provider.messages[0], provider.messages[1])
        assertEquals(listOf(selected.fid, selected.fid), provider.fids)
        val message = provider.messages.first()
        assertEquals("42", message.data["meetingId"])
        assertEquals("60", message.data["reminderOffsetMinutes"])
        assertEquals("2026-09-11T20:00:00.123Z", message.data["issuedAt"])
        assertTrue(message.data["eventId"]!!.isNotBlank())
    }

    @Test
    fun `separate diagnostic reruns use fresh event IDs`() {
        val provider = QueueProvider(
            PushDeliveryResult.Accepted,
            PushDeliveryResult.Accepted,
        )
        val service = service(RecordingStore(selection()), provider)

        service.send(command())
        service.send(command())

        assertNotEquals(provider.messages[0].data["eventId"], provider.messages[1].data["eventId"])
    }

    @Test
    fun `nonblocking permit covers whole operation without oversubscription`() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val messages = mutableListOf<PushReminderMessage>()
        val provider = object : PushProvider {
            override fun send(fid: PushFid, message: PushReminderMessage): PushDeliveryResult {
                messages += message
                entered.countDown()
                check(release.await(10, TimeUnit.SECONDS))
                return PushDeliveryResult.Accepted
            }
        }
        val service = service(RecordingStore(selection()), provider)
        val executor = Executors.newSingleThreadExecutor()

        try {
            val admitted = executor.submit<PushDiagnosticResponse> { service.send(command()) }
            assertTrue(entered.await(10, TimeUnit.SECONDS))

            val saturated = assertFailsWith<PushUnavailableException> { service.send(command()) }
            assertEquals("PUSH_UNAVAILABLE", saturated.code)
            assertEquals(1, messages.size)

            release.countDown()
            assertEquals(
                DiagnosticCallResult.Accepted,
                (admitted.get(10, TimeUnit.SECONDS) as PushDiagnosticResponse.Single).result,
            )
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `accepted pair performs only selection and recheck transactions with no scheduled writes`() {
        val store = RecordingStore(selection())
        val transactions = RecordingTransactionManager()
        val provider = QueueProvider(
            PushDeliveryResult.Accepted,
            PushDeliveryResult.Accepted,
        )

        service(store, provider, transactions).send(
            command(mode = PushDiagnosticMode.DEDUP_PAIR),
        )

        assertEquals(listOf("select", "recheck"), store.calls)
        assertEquals(2, transactions.begins)
        assertEquals(2, transactions.commits)
        assertEquals(0, transactions.rollbacks)
        assertTrue(transactions.timeouts.all { it == 5 })
        assertEquals(2, provider.messages.size)
    }

    private fun command(
        userId: Long = 1,
        meetingId: Long = 42,
        offset: Int = 60,
        mode: PushDiagnosticMode = PushDiagnosticMode.SINGLE,
    ) = PushDiagnosticCommand(userId, installationId, meetingId, offset, mode)

    private fun selection(
        fid: String = "opaque-fid",
        version: Long = 1,
    ) = DiagnosticSelection(1, installationId, 42, parseFid(fid), version)

    private fun service(
        store: PushDiagnosticStore,
        provider: PushProvider,
        transactions: PlatformTransactionManager = ImmediateTransactionManager(),
    ) = PushDiagnosticService(store, provider, transactions, clock)

    private class RecordingStore(
        private val selected: DiagnosticSelection?,
    ) : PushDiagnosticStore {
        val calls = mutableListOf<String>()
        var rechecked: DiagnosticSelection? = selected
        var selectFailure: RuntimeException? = null
        var recheckFailure: RuntimeException? = null
        val invalidations = ArrayDeque<DiagnosticInvalidation>()
        var selectedCommand: PushDiagnosticCommand? = null
        var selectionTime: Instant? = null
        var invalidatedSelection: DiagnosticSelection? = null
        var expectedFid: PushFid? = null
        var expectedVersion: Long? = null

        override fun selectEligible(command: PushDiagnosticCommand, now: Instant): DiagnosticSelection? {
            calls += "select"
            selectedCommand = command
            selectionTime = now
            selectFailure?.let { throw it }
            return selected
        }

        override fun recheckEligible(selection: DiagnosticSelection, now: Instant): DiagnosticSelection? {
            calls += "recheck"
            recheckFailure?.let { throw it }
            return rechecked
        }

        override fun lockOwner(userId: Long) {
            calls += "lockOwner"
        }

        override fun invalidateExact(
            selection: DiagnosticSelection,
            expectedFid: PushFid,
            expectedRegistrationVersion: Long,
        ): DiagnosticInvalidation {
            calls += "invalidate"
            invalidatedSelection = selection
            this.expectedFid = expectedFid
            expectedVersion = expectedRegistrationVersion
            return if (invalidations.isEmpty()) DiagnosticInvalidation.APPLIED else invalidations.removeFirst()
        }
    }

    private class QueueProvider(vararg outcomes: Any) : PushProvider {
        private val outcomes = ArrayDeque(outcomes.toList())
        val fids = mutableListOf<PushFid>()
        val messages = mutableListOf<PushReminderMessage>()

        override fun send(fid: PushFid, message: PushReminderMessage): PushDeliveryResult {
            fids += fid
            messages += message
            return when (val outcome = outcomes.removeFirst()) {
                is PushDeliveryResult -> outcome
                is RuntimeException -> throw outcome
                else -> error("Unsupported provider outcome")
            }
        }
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
