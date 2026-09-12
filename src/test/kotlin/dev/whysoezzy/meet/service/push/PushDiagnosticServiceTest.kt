package dev.whysoezzy.meet.service.push

import org.junit.jupiter.api.Test
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.TransactionDefinition
import org.springframework.transaction.TransactionStatus
import org.springframework.transaction.support.SimpleTransactionStatus
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class PushDiagnosticServiceTest {
    @Test
    fun `dedup pair sends byte-identical message twice`() {
        val selection = selection()
        val store = FakeDiagnosticStore(selection)
        val messages = mutableListOf<PushReminderMessage>()
        val service = PushDiagnosticService(
            store = store,
            provider = object : PushProvider {
                override fun send(fid: PushFid, message: PushReminderMessage): PushDeliveryResult {
                    messages += message
                    return PushDeliveryResult.Accepted
                }
            },
            transactionManager = ImmediateTransactionManager(),
            clock = Clock.fixed(Instant.parse("2026-09-11T20:00:00Z"), ZoneOffset.UTC),
        )

        val response = service.send(
            PushDiagnosticCommand(
                userId = selection.userId,
                installationId = selection.installationId,
                meetingId = selection.meetingId,
                reminderOffsetMinutes = 60,
                mode = PushDiagnosticMode.DEDUP_PAIR,
            ),
        )

        assertEquals(DiagnosticAggregateResult.ACCEPTED_PAIR, (response as PushDiagnosticResponse.Pair).result)
        assertEquals(2, messages.size)
        assertEquals(messages[0], messages[1])
        assertTrue(messages[0].data["eventId"]!!.isNotBlank())
    }

    @Test
    fun `selection infrastructure failure is sanitized as unavailable`() {
        val service = PushDiagnosticService(
            store = object : PushDiagnosticStore {
                override fun selectEligible(command: PushDiagnosticCommand, now: Instant): DiagnosticSelection? =
                    error("database unavailable")

                override fun recheckEligible(selection: DiagnosticSelection, now: Instant): DiagnosticSelection? = null

                override fun invalidateExact(
                    selection: DiagnosticSelection,
                    expectedFid: PushFid,
                    expectedRegistrationVersion: Long,
                ) = DiagnosticInvalidation.FAILED
            },
            provider = errorProvider(),
            transactionManager = ImmediateTransactionManager(),
            clock = Clock.systemUTC(),
        )

        val exception = kotlin.test.assertFailsWith<dev.whysoezzy.meet.api.error.ApiException> {
            service.send(
                PushDiagnosticCommand(1, UUID.randomUUID(), 2, 60, PushDiagnosticMode.SINGLE),
            )
        }
        assertEquals(503, exception.status.value())
    }

    @Test
    fun `unexpected provider failure is sanitized for single diagnostic`() {
        val selection = selection()
        val service = PushDiagnosticService(
            store = FakeDiagnosticStore(selection),
            provider = object : PushProvider {
                override fun send(fid: PushFid, message: PushReminderMessage): PushDeliveryResult =
                    error("provider failure")
            },
            transactionManager = ImmediateTransactionManager(),
            clock = Clock.fixed(Instant.parse("2026-09-11T20:00:00Z"), ZoneOffset.UTC),
        )

        val exception = assertFailsWith<dev.whysoezzy.meet.api.error.ApiException> {
            service.send(
                PushDiagnosticCommand(1, selection.installationId, 2, 60, PushDiagnosticMode.SINGLE),
            )
        }
        assertEquals(503, exception.status.value())
        assertEquals("PUSH_UNAVAILABLE", exception.code)
    }

    @Test
    fun `unexpected first provider failure stops pair without a second call`() {
        val selection = selection()
        var calls = 0
        val service = PushDiagnosticService(
            store = FakeDiagnosticStore(selection),
            provider = object : PushProvider {
                override fun send(fid: PushFid, message: PushReminderMessage): PushDeliveryResult {
                    calls += 1
                    error("provider failure")
                }
            },
            transactionManager = ImmediateTransactionManager(),
            clock = Clock.fixed(Instant.parse("2026-09-11T20:00:00Z"), ZoneOffset.UTC),
        )

        val response = service.send(
            PushDiagnosticCommand(1, selection.installationId, 2, 60, PushDiagnosticMode.DEDUP_PAIR),
        ) as PushDiagnosticResponse.Pair

        assertEquals(DiagnosticAggregateResult.INCONCLUSIVE, response.result)
        assertEquals(DiagnosticCallResult.ProviderUnavailable, response.first)
        assertEquals(DiagnosticCallResult.NotAttempted, response.second)
        assertEquals(1, calls)
    }

    @Test
    fun `typed provider unavailability still permits the second pair call`() {
        val selection = selection()
        var calls = 0
        val service = PushDiagnosticService(
            store = FakeDiagnosticStore(selection),
            provider = object : PushProvider {
                override fun send(fid: PushFid, message: PushReminderMessage): PushDeliveryResult {
                    calls += 1
                    return if (calls == 1) {
                        PushDeliveryResult.Unavailable
                    } else {
                        PushDeliveryResult.Accepted
                    }
                }
            },
            transactionManager = ImmediateTransactionManager(),
            clock = Clock.fixed(Instant.parse("2026-09-11T20:00:00Z"), ZoneOffset.UTC),
        )

        val response = service.send(
            PushDiagnosticCommand(1, selection.installationId, 2, 60, PushDiagnosticMode.DEDUP_PAIR),
        ) as PushDiagnosticResponse.Pair

        assertEquals(DiagnosticAggregateResult.INCONCLUSIVE, response.result)
        assertEquals(DiagnosticCallResult.ProviderUnavailable, response.first)
        assertEquals(DiagnosticCallResult.Accepted, response.second)
        assertEquals(2, calls)
    }

    private fun selection() = DiagnosticSelection(
        userId = 1,
        installationId = UUID.randomUUID(),
        meetingId = 2,
        fid = parseFid("opaque-fid"),
        registrationVersion = 1,
    )

    private class FakeDiagnosticStore(
        private val selected: DiagnosticSelection,
    ) : PushDiagnosticStore {
        override fun selectEligible(command: PushDiagnosticCommand, now: Instant) = selected
        override fun recheckEligible(selection: DiagnosticSelection, now: Instant) = selected
        override fun invalidateExact(
            selection: DiagnosticSelection,
            expectedFid: PushFid,
            expectedRegistrationVersion: Long,
        ) = DiagnosticInvalidation.APPLIED
    }

    private fun errorProvider() = object : PushProvider {
        override fun send(fid: PushFid, message: PushReminderMessage): PushDeliveryResult =
            PushDeliveryResult.Unavailable
    }

    private class ImmediateTransactionManager : PlatformTransactionManager {
        override fun getTransaction(definition: TransactionDefinition?): TransactionStatus = SimpleTransactionStatus()
        override fun commit(status: TransactionStatus) = Unit
        override fun rollback(status: TransactionStatus) = Unit
    }
}
