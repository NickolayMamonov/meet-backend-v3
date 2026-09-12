package dev.whysoezzy.meet.service.push.firebase

import com.google.firebase.FirebaseApp
import com.google.firebase.ErrorCode
import com.google.firebase.FirebaseException
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingException
import com.google.firebase.messaging.Message
import com.google.firebase.messaging.MulticastMessage
import com.google.firebase.messaging.MessagingErrorCode
import dev.whysoezzy.meet.config.GoogleSdkLogGuard
import dev.whysoezzy.meet.service.push.PushDeliveryResult
import dev.whysoezzy.meet.service.push.PushReminderMessage
import dev.whysoezzy.meet.service.push.parseFid
import org.junit.jupiter.api.Test
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentCaptor
import org.mockito.Mockito.never
import org.mockito.Mockito.doReturn
import org.mockito.Mockito.doAnswer
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeoutException
import kotlin.test.assertEquals
import kotlin.test.assertNull

class FirebasePushProviderTest {
    @Suppress("DEPRECATION")
    @Test
    fun `accepted send contains only the exact FID target and seven data strings`() {
        val messaging = mock(FirebaseMessaging::class.java)
        doReturn("message-id").`when`(messaging).send(any<Message>())
        val provider = FirebasePushProvider(
            messaging,
            mock(FirebaseApp::class.java),
            GoogleSdkLogGuard.install(),
        )

        val reminder = reminder()
        val result = provider.send(parseFid("fid-test"), reminder)

        assertEquals(PushDeliveryResult.Accepted, result)

        val captured = ArgumentCaptor.forClass(Message::class.java)
        verify(messaging).send(captured.capture())
        val message = captured.value
        assertEquals("fid-test", messageProperty<String>(message, "getFid"))
        assertEquals(
            mapOf(
                "eventType" to "MEETING_REMINDER",
                "schemaVersion" to "1",
                "eventId" to "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "meetingId" to "42",
                "reminderOffsetMinutes" to "60",
                "issuedAt" to "2026-09-11T19:00:00Z",
                "destination" to "MEETING_DETAILS",
            ),
            messageProperty<Map<String, String>>(message, "getData"),
        )
        assertEquals(7, messageProperty<Map<String, String>>(message, "getData")!!.size)
        assertNull(messageProperty<Any>(message, "getNotification"))
        assertNull(messageProperty<Any>(message, "getToken"))
        assertNull(messageProperty<Any>(message, "getTopic"))
        assertNull(messageProperty<Any>(message, "getCondition"))
        assertNull(messageProperty<Any>(message, "getAndroidConfig"))
        assertNull(messageProperty<Any>(message, "getWebpushConfig"))
        assertNull(messageProperty<Any>(message, "getApnsConfig"))
        assertNull(messageProperty<Any>(message, "getFcmOptions"))
        verify(messaging, never()).sendMulticast(any<MulticastMessage>())
        verify(messaging, never()).sendEachForMulticast(any<MulticastMessage>())
    }

    @Test
    fun `Firebase and transport failures map to stable delivery results`() {
        val cases = listOf(
            "UNREGISTERED" to (messagingFailure(MessagingErrorCode.UNREGISTERED) to PushDeliveryResult.InvalidRegistration),
            "messaging internal" to (messagingFailure(MessagingErrorCode.INTERNAL) to PushDeliveryResult.TransientFailure),
            "messaging unavailable" to (messagingFailure(MessagingErrorCode.UNAVAILABLE) to PushDeliveryResult.TransientFailure),
            "auth" to (messagingFailure(MessagingErrorCode.THIRD_PARTY_AUTH_ERROR) to PushDeliveryResult.Unavailable),
            "project" to (messagingFailure(MessagingErrorCode.SENDER_ID_MISMATCH) to PushDeliveryResult.Unavailable),
            "messaging invalid argument" to (messagingFailure(MessagingErrorCode.INVALID_ARGUMENT) to PushDeliveryResult.Unavailable),
            "messaging unknown code" to (messagingFailure(null) to PushDeliveryResult.Unavailable),
            "messaging quota" to (messagingFailure(MessagingErrorCode.QUOTA_EXCEEDED) to PushDeliveryResult.TransientFailure),
            "Firebase internal" to (firebaseFailure(ErrorCode.INTERNAL) to PushDeliveryResult.TransientFailure),
            "Firebase unavailable" to (firebaseFailure(ErrorCode.UNAVAILABLE) to PushDeliveryResult.TransientFailure),
            "Firebase auth" to (firebaseFailure(ErrorCode.UNAUTHENTICATED) to PushDeliveryResult.Unavailable),
            "Firebase project" to (firebaseFailure(ErrorCode.NOT_FOUND) to PushDeliveryResult.Unavailable),
            "Firebase quota" to (firebaseFailure(ErrorCode.RESOURCE_EXHAUSTED) to PushDeliveryResult.TransientFailure),
            "Firebase timeout" to (firebaseFailure(ErrorCode.DEADLINE_EXCEEDED) to PushDeliveryResult.TransientFailure),
            "socket timeout" to (SocketTimeoutException("timeout") to PushDeliveryResult.TransientFailure),
            "transport" to (SocketException("transport") to PushDeliveryResult.TransientFailure),
            "DNS transport" to (UnknownHostException("dns") to PushDeliveryResult.TransientFailure),
            "timeout" to (TimeoutException("timeout") to PushDeliveryResult.TransientFailure),
            "unknown" to (IllegalStateException("unknown") to PushDeliveryResult.Unavailable),
        )

        cases.forEach { (name, expectedCase) ->
            val (failure, expected) = expectedCase
            val messaging = mock(FirebaseMessaging::class.java)
            doAnswer { throw failure }.`when`(messaging).send(any<Message>())
            val provider = FirebasePushProvider(
                messaging,
                mock(FirebaseApp::class.java),
                GoogleSdkLogGuard.install(),
            )

            assertEquals(expected, provider.send(parseFid("fid-test"), reminder()), name)
            verify(messaging).send(any<Message>())
        }
    }

    private fun messagingFailure(code: MessagingErrorCode?): FirebaseMessagingException =
        mock<FirebaseMessagingException>().also {
            doReturn(code).`when`(it).messagingErrorCode
        }

    private fun firebaseFailure(code: ErrorCode): FirebaseException =
        mock<FirebaseException>().also {
            doReturn(code).`when`(it).errorCode
        }

    @Suppress("UNCHECKED_CAST")
    private fun <T> messageProperty(message: Message, methodName: String): T? =
        message.javaClass.getDeclaredMethod(methodName).apply { isAccessible = true }.invoke(message) as T?

    private fun reminder(): PushReminderMessage =
        PushReminderMessage.meetingReminder(
            eventId = UUID.fromString("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            meetingId = 42,
            reminderOffsetMinutes = 60,
            issuedAt = Instant.parse("2026-09-11T19:00:00Z"),
        )
}
