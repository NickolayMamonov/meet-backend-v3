package dev.whysoezzy.meet.service.push

import org.junit.jupiter.api.Test
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.TransactionDefinition
import org.springframework.transaction.TransactionException
import org.springframework.transaction.TransactionStatus
import org.springframework.transaction.support.SimpleTransactionStatus
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ReminderDispatcherTest {
    @Test
    fun `provider is called outside the lease transactions`() {
        val transactions = RecordingTransactionManager()
        var providerSawTransaction = true
        val store = FakeDispatchStore()
        val provider = object : PushProvider {
            override fun send(fid: PushFid, message: PushReminderMessage): PushDeliveryResult {
                providerSawTransaction = transactions.active
                return PushDeliveryResult.Accepted
            }
        }
        val dispatcher = ReminderDispatcher(
            store = store,
            provider = provider,
            transactionManager = transactions,
            clock = Clock.fixed(Instant.parse("2026-09-11T20:00:00Z"), ZoneOffset.UTC),
        )

        dispatcher.dispatchOne()

        assertFalse(providerSawTransaction)
        assertTrue(store.finalized)
    }

    private class FakeDispatchStore : ReminderDispatchStore {
        private val lease = ReminderLease(
            targetId = UUID.randomUUID(),
            claimId = UUID.randomUUID(),
            userId = 1,
            meetingId = 2,
            installationId = UUID.randomUUID(),
            leaseToken = UUID.randomUUID(),
            attempt = 1,
            leaseUntil = Instant.parse("2026-09-11T20:10:00Z"),
        )
        var finalized = false

        override fun leaseNext(): ReminderLease = lease

        override fun prepareSend(lease: ReminderLease, now: Instant) =
            PreparedReminderSend(
                fid = parseFid("opaque-fid"),
                registrationVersion = 1,
                message = ReminderMessageFactory.create(
                    lease.claimId,
                    lease.meetingId,
                    ReminderOffset.ONE_HOUR,
                    Instant.parse("2026-09-11T20:00:00Z"),
                ),
            )

        override fun skipIneligible(lease: ReminderLease, now: Instant) = false

        override fun finalize(
            lease: ReminderLease,
            send: PreparedReminderSend,
            outcome: ReminderFinalization,
            now: Instant,
        ): Boolean {
            finalized = true
            return true
        }

        override fun recoverAndExpire(limit: Int, now: Instant) = 0
    }

    private class RecordingTransactionManager : PlatformTransactionManager {
        var active = false

        override fun getTransaction(definition: TransactionDefinition?): TransactionStatus {
            active = true
            return SimpleTransactionStatus()
        }

        override fun commit(status: TransactionStatus) {
            active = false
        }

        override fun rollback(status: TransactionStatus) {
            active = false
        }
    }
}
