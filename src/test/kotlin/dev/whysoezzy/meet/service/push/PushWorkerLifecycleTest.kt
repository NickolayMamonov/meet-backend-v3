package dev.whysoezzy.meet.service.push

import dev.whysoezzy.meet.config.PushRuntimeSettings
import org.junit.jupiter.api.Test
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.springframework.mock.env.MockEnvironment
import org.mockito.Mockito
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.TransactionDefinition
import org.springframework.transaction.TransactionStatus
import org.springframework.transaction.support.SimpleTransactionStatus

class PushWorkerLifecycleTest {
    @Test
    fun `discovery condition requires provider and discovery flags`() {
        val condition = DiscoveryPushCondition()
        val metadata = org.springframework.core.type.AnnotationMetadata.introspect(PushWorkerLifecycle::class.java)
        fun matches(provider: Boolean, discovery: Boolean): Boolean {
            val environment = MockEnvironment()
                .withProperty("app.push.provider-enabled", provider.toString())
                .withProperty("app.push.discovery-enabled", discovery.toString())
            val context = Mockito.mock(org.springframework.context.annotation.ConditionContext::class.java)
            Mockito.`when`(context.environment).thenReturn(environment)
            return condition.matches(context, metadata)
        }
        assertFalse(matches(false, false))
        assertFalse(matches(true, false))
        assertFalse(matches(false, true))
        assertTrue(matches(true, true))
    }

    @Test
    fun `lifecycle is auto-starting and can stop admission`() {
        val dispatcher = ReminderDispatcher(
            store = object : ReminderDispatchStore {
                override fun leaseNext(): ReminderLease? = null
                override fun prepareSend(lease: ReminderLease, now: Instant): PreparedReminderSend? = null
                override fun skipIneligible(lease: ReminderLease, now: Instant) = false
                override fun finalize(
                    lease: ReminderLease,
                    send: PreparedReminderSend,
                    outcome: ReminderFinalization,
                    now: Instant,
                ) = false
                override fun recoverAndExpire(limit: Int, now: Instant) = 0
            },
            provider = object : PushProvider {
                override fun send(fid: PushFid, message: PushReminderMessage) = PushDeliveryResult.Accepted
            },
            transactionManager = ImmediateTransactionManager(),
            clock = Clock.fixed(Instant.EPOCH, ZoneOffset.UTC),
        )
        val lifecycle = PushWorkerLifecycle(dispatcher)

        assertTrue(lifecycle.isAutoStartup)
        assertFalse(lifecycle.isRunning)
        lifecycle.start()
        assertTrue(lifecycle.isRunning)
        lifecycle.stop()
        assertFalse(lifecycle.isRunning)
    }

    @Test
    fun `dispatch condition requires provider and dispatch flags`() {
        val condition = DispatchPushCondition()
        val metadata = org.springframework.core.type.AnnotationMetadata.introspect(PushWorkerLifecycle::class.java)
        fun matches(provider: Boolean, dispatch: Boolean): Boolean {
            val environment = org.springframework.mock.env.MockEnvironment()
                .withProperty("app.push.provider-enabled", provider.toString())
                .withProperty("app.push.dispatch-enabled", dispatch.toString())
            val context = org.mockito.Mockito.mock(org.springframework.context.annotation.ConditionContext::class.java)
            org.mockito.Mockito.`when`(context.environment).thenReturn(environment)
            return condition.matches(context, metadata)
        }
        assertFalse(matches(false, false))
        assertFalse(matches(true, false))
        assertFalse(matches(false, true))
        assertTrue(matches(true, true))
    }

    @Test
    fun `start is idempotent and repeated stop callbacks complete`() {
        val dispatcher = org.mockito.Mockito.mock(ReminderDispatcher::class.java)
        val lifecycle = PushWorkerLifecycle(dispatcher)
        val callbacks = AtomicInteger()

        lifecycle.start()
        lifecycle.start()
        assertTrue(lifecycle.isRunning)
        lifecycle.stop { callbacks.incrementAndGet() }
        lifecycle.stop { callbacks.incrementAndGet() }

        assertFalse(lifecycle.isRunning)
        assertEquals(2, callbacks.get())
    }

    @Test
    fun `four synchronous workers are the finite admission capacity`() {
        val entered = CountDownLatch(PushRuntimeSettings.DISPATCH_WORKERS)
        val release = CountDownLatch(1)
        val active = AtomicInteger()
        val maximum = AtomicInteger()
        val dispatcher = org.mockito.Mockito.mock(ReminderDispatcher::class.java)
        org.mockito.Mockito.doAnswer {
            val current = active.incrementAndGet()
            maximum.accumulateAndGet(current) { left, right -> maxOf(left, right) }
            entered.countDown()
            release.await(5, TimeUnit.SECONDS)
            active.decrementAndGet()
            null
        }.`when`(dispatcher).dispatchOne()

        val lifecycle = PushWorkerLifecycle(dispatcher)
        try {
            lifecycle.start()
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertEquals(PushRuntimeSettings.DISPATCH_WORKERS, maximum.get())
            assertEquals(PushRuntimeSettings.DISPATCH_WORKERS, active.get())
        } finally {
            release.countDown()
            lifecycle.stop()
        }
    }

    @Test
    fun `provider call runs outside every transaction boundary`() {
        val lease = ReminderLease(
            targetId = UUID.randomUUID(),
            claimId = UUID.randomUUID(),
            userId = 7,
            meetingId = 42,
            installationId = UUID.randomUUID(),
            leaseToken = UUID.randomUUID(),
            attempt = 1,
            leaseUntil = Instant.EPOCH.plusSeconds(600),
        )
        val prepared = PreparedReminderSend(
            fid = parseFid("fid-1"),
            registrationVersion = 1,
            message = PushReminderMessage.meetingReminder(
                eventId = lease.claimId,
                meetingId = lease.meetingId,
                reminderOffsetMinutes = 60,
                issuedAt = Instant.EPOCH,
            ),
        )
        val calls = mutableListOf<String>()
        val store = object : ReminderDispatchStore {
            override fun leaseNext(): ReminderLease? {
                calls += "lease"
                return lease
            }

            override fun prepareSend(lease: ReminderLease, now: Instant): PreparedReminderSend? {
                calls += "prepare"
                return prepared
            }

            override fun skipIneligible(lease: ReminderLease, now: Instant) = error("not expected")

            override fun finalize(
                lease: ReminderLease,
                send: PreparedReminderSend,
                outcome: ReminderFinalization,
                now: Instant,
            ): Boolean {
                calls += "finalize"
                assertEquals(ReminderFinalization.Accepted, outcome)
                return true
            }

            override fun recoverAndExpire(limit: Int, now: Instant) = 0
        }
        val transactionManager = TrackingTransactionManager()
        val provider = object : PushProvider {
            override fun send(fid: PushFid, message: PushReminderMessage): PushDeliveryResult {
                assertFalse(transactionManager.inTransaction)
                calls += "provider"
                return PushDeliveryResult.Accepted
            }
        }
        ReminderDispatcher(
            store = store,
            provider = provider,
            transactionManager = transactionManager,
            clock = Clock.fixed(Instant.EPOCH, ZoneOffset.UTC),
        ).dispatchOne()

        assertEquals(listOf("lease", "prepare", "provider", "finalize"), calls)
        assertFalse(transactionManager.inTransaction)
    }

    private class ImmediateTransactionManager : PlatformTransactionManager {
        override fun getTransaction(definition: TransactionDefinition?): TransactionStatus = SimpleTransactionStatus()
        override fun commit(status: TransactionStatus) = Unit
        override fun rollback(status: TransactionStatus) = Unit
    }

    private class TrackingTransactionManager : PlatformTransactionManager {
        var inTransaction = false

        override fun getTransaction(definition: TransactionDefinition?): TransactionStatus {
            check(!inTransaction)
            inTransaction = true
            return SimpleTransactionStatus()
        }

        override fun commit(status: TransactionStatus) {
            inTransaction = false
        }

        override fun rollback(status: TransactionStatus) {
            inTransaction = false
        }
    }
}
