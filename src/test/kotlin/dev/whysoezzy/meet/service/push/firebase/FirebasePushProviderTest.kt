package dev.whysoezzy.meet.service.push.firebase

import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingException
import com.google.firebase.messaging.MessagingErrorCode
import dev.whysoezzy.meet.config.GoogleSdkLogGuard
import dev.whysoezzy.meet.service.push.PushDeliveryResult
import dev.whysoezzy.meet.service.push.PushReminderMessage
import dev.whysoezzy.meet.service.push.parseFid
import org.junit.jupiter.api.Test
import org.mockito.ArgumentMatchers.any
import org.mockito.Mockito.doReturn
import org.mockito.Mockito.doThrow
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals

class FirebasePushProviderTest {
    @Test
    fun `accepted send invokes Firebase exactly once`() {
        val messaging = mock(FirebaseMessaging::class.java)
        doReturn("message-id").`when`(messaging).send(any())
        val provider = FirebasePushProvider(
            messaging,
            mock(FirebaseApp::class.java),
            GoogleSdkLogGuard.install(),
        )

        val result = provider.send(parseFid("fid-test"), reminder())

        assertEquals(PushDeliveryResult.Accepted, result)
        verify(messaging).send(any())
    }

    @Test
    fun `only UNREGISTERED invalidates the installation`() {
        val messaging = mock(FirebaseMessaging::class.java)
        val failure = mock(FirebaseMessagingException::class.java)
        doReturn(MessagingErrorCode.UNREGISTERED).`when`(failure).messagingErrorCode
        doThrow(failure).`when`(messaging).send(any())
        val provider = FirebasePushProvider(
            messaging,
            mock(FirebaseApp::class.java),
            GoogleSdkLogGuard.install(),
        )

        assertEquals(
            PushDeliveryResult.InvalidRegistration,
            provider.send(parseFid("fid-test"), reminder()),
        )
    }

    private fun reminder(): PushReminderMessage =
        PushReminderMessage.meetingReminder(
            eventId = UUID.randomUUID(),
            meetingId = 42,
            reminderOffsetMinutes = 60,
            issuedAt = Instant.parse("2026-09-11T19:00:00Z"),
        )
}
