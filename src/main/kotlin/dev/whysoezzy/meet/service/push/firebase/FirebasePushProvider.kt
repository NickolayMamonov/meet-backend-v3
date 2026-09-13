package dev.whysoezzy.meet.service.push.firebase

import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseException
import com.google.firebase.ErrorCode
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingException
import com.google.firebase.messaging.Message
import com.google.firebase.messaging.MessagingErrorCode
import dev.whysoezzy.meet.config.GoogleSdkLogGuard
import dev.whysoezzy.meet.service.push.Fid
import dev.whysoezzy.meet.service.push.PushProvider
import dev.whysoezzy.meet.service.push.PushDeliveryResult
import dev.whysoezzy.meet.service.push.ReminderMessage
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.TimeoutException

/**
 * The only class allowed to cross the domain/provider boundary into Firebase.
 * SDK objects, message IDs, response bodies, and exception causes never escape.
 */
class FirebasePushProvider internal constructor(
    private val messaging: FirebaseMessaging,
    private val app: FirebaseApp,
    @Suppress("UNUSED_PARAMETER") private val logGuard: GoogleSdkLogGuard,
) : PushProvider, AutoCloseable {
    override fun send(fid: Fid, message: ReminderMessage): PushDeliveryResult =
        try {
            val sdkMessage = Message.builder()
                .setFid(fid.value)
                .putAllData(message.data)
                .build()
            messaging.send(sdkMessage)
            PushDeliveryResult.Accepted
        } catch (exception: FirebaseMessagingException) {
            mapMessagingFailure(exception)
        } catch (exception: FirebaseException) {
            mapFirebaseFailure(exception)
        } catch (_: SocketTimeoutException) {
            PushDeliveryResult.TransientFailure
        } catch (_: SocketException) {
            PushDeliveryResult.TransientFailure
        } catch (_: UnknownHostException) {
            PushDeliveryResult.TransientFailure
        } catch (_: TimeoutException) {
            PushDeliveryResult.TransientFailure
        } catch (_: Exception) {
            PushDeliveryResult.Unavailable
        }

    override fun close() {
        try {
            app.delete()
        } catch (_: Exception) {
            // Destruction must not reintroduce provider details into shutdown diagnostics.
        }
    }

    private fun mapMessagingFailure(exception: FirebaseMessagingException): PushDeliveryResult =
        when (exception.messagingErrorCode) {
            MessagingErrorCode.UNREGISTERED -> PushDeliveryResult.InvalidRegistration
            MessagingErrorCode.INTERNAL,
            MessagingErrorCode.UNAVAILABLE,
            MessagingErrorCode.QUOTA_EXCEEDED,
            -> PushDeliveryResult.TransientFailure
            MessagingErrorCode.INVALID_ARGUMENT,
            MessagingErrorCode.SENDER_ID_MISMATCH,
            MessagingErrorCode.THIRD_PARTY_AUTH_ERROR,
            null,
            -> PushDeliveryResult.Unavailable
        }

    private fun mapFirebaseFailure(exception: FirebaseException): PushDeliveryResult =
        when (exception.errorCode) {
            ErrorCode.INTERNAL,
            ErrorCode.UNAVAILABLE,
            ErrorCode.RESOURCE_EXHAUSTED,
            ErrorCode.DEADLINE_EXCEEDED,
            -> PushDeliveryResult.TransientFailure
            else -> PushDeliveryResult.Unavailable
        }
}
