package dev.whysoezzy.meet.service.auth.otp

import dev.whysoezzy.meet.api.error.ServiceUnavailableException
import dev.whysoezzy.meet.config.OtpProperties
import dev.whysoezzy.meet.service.OtpRequestContext
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import dev.whysoezzy.meet.service.email.EmailOtpMessage
import dev.whysoezzy.meet.service.email.EmailOtpSender
import dev.whysoezzy.meet.service.sms.SmsSender
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import org.springframework.transaction.CannotCreateTransactionException
import org.springframework.transaction.TransactionSystemException
import org.springframework.transaction.support.TransactionSynchronizationManager
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class OtpRequestCoordinatorTest {
    private val requestRateLimiter = mock(OtpRequestRateLimiter::class.java)
    private val codeGenerator = mock(OtpCodeGenerator::class.java)
    private val hasher = mock(OtpHasher::class.java)
    private val lifecycle = mock(OtpChallengeLifecycle::class.java)
    private val smsSender = RecordingSmsSender()
    private val deliveryRouter = OtpDeliveryRouter(
        smsSender,
        object : EmailOtpSender {
            override fun send(message: EmailOtpMessage) = Unit
        },
    )
    private val coordinator = OtpRequestCoordinator(
        requestRateLimiter,
        codeGenerator,
        hasher,
        lifecycle,
        deliveryRouter,
        OtpProperties(),
    )

    @Test
    fun `pending transaction failure prevents provider invocation`() {
        val fixture = fixture()
        `when`(lifecycle.createPending(fixture.identifier, fixture.material))
            .thenThrow(CannotCreateTransactionException("safe category"))

        assertEquals(
            OtpRequestOutcome.PersistenceUnavailable,
            coordinator.request(fixture.identifier, OtpRequestContext.EMPTY),
        )
        assertFalse(smsSender.wasInvoked)
    }

    @Test
    fun `provider runs outside transactions and compensation failure preserves delivery outcome`() {
        val fixture = fixture()
        `when`(lifecycle.createPending(fixture.identifier, fixture.material))
            .thenReturn(PendingChallenge(7))
        smsSender.failure = ServiceUnavailableException("SMS delivery is not configured")
        `when`(lifecycle.markDeliveryFailed(7)).thenThrow(TransactionSystemException("safe category"))

        assertEquals(
            OtpRequestOutcome.DeliveryUnavailable,
            coordinator.request(fixture.identifier, OtpRequestContext.EMPTY),
        )
        assertFalse(smsSender.transactionWasActive)
        verify(lifecycle).markDeliveryFailed(7)
        verify(lifecycle, never()).activate(7)
    }

    @Test
    fun `activation transaction failures map to activation unavailable`() {
        val fixture = fixture()
        `when`(lifecycle.createPending(fixture.identifier, fixture.material))
            .thenReturn(PendingChallenge(9))
        `when`(lifecycle.activate(9))
            .thenThrow(CannotCreateTransactionException("safe category"))

        assertEquals(
            OtpRequestOutcome.ActivationUnavailable,
            coordinator.request(fixture.identifier, OtpRequestContext.EMPTY),
        )
        assertFalse(smsSender.transactionWasActive)
    }

    private fun fixture(): Fixture {
        val identifier = AuthIdentifier.phone("+15550000001")
        val code = SensitiveOtpCode.validated("123456")
        val material = OtpHashMaterial(ByteArray(32), ByteArray(16), "test-current")
        `when`(codeGenerator.generate()).thenReturn(code)
        `when`(hasher.hash(identifier, code)).thenReturn(material)
        return Fixture(identifier, material)
    }

    private data class Fixture(
        val identifier: AuthIdentifier,
        val material: OtpHashMaterial,
    )

    private class RecordingSmsSender : SmsSender {
        var wasInvoked = false
        var transactionWasActive = false
        var failure: RuntimeException? = null

        override fun sendOtp(phone: String, code: String) {
            wasInvoked = true
            transactionWasActive = TransactionSynchronizationManager.isActualTransactionActive()
            failure?.let { throw it }
        }
    }
}
