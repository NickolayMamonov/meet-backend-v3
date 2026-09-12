package dev.whysoezzy.meet.service.push

import org.junit.jupiter.api.Test
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID
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

    private class ImmediateTransactionManager : PlatformTransactionManager {
        override fun getTransaction(definition: TransactionDefinition?): TransactionStatus = SimpleTransactionStatus()
        override fun commit(status: TransactionStatus) = Unit
        override fun rollback(status: TransactionStatus) = Unit
    }
}
