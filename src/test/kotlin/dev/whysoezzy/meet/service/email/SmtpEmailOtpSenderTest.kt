package dev.whysoezzy.meet.service.email

import dev.whysoezzy.meet.config.EmailProperties
import dev.whysoezzy.meet.config.EmailProvider
import dev.whysoezzy.meet.config.SmtpRuntimeSettings
import jakarta.mail.internet.MimeMessage
import org.springframework.mail.MailSendException
import org.springframework.mail.javamail.JavaMailSenderImpl
import org.springframework.mock.env.MockEnvironment
import java.net.SocketTimeoutException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SmtpEmailOtpSenderTest {
    @Test
    fun `runtime settings force safe authenticated STARTTLS SMTP`() {
        val sender = settings().createMailSender()

        assertEquals("smtp.example.com", sender.host)
        assertEquals(587, sender.port)
        assertEquals("smtp", sender.protocol)
        assertEquals("true", sender.javaMailProperties.getProperty("mail.smtp.auth"))
        assertEquals("true", sender.javaMailProperties.getProperty("mail.smtp.starttls.enable"))
        assertEquals("true", sender.javaMailProperties.getProperty("mail.smtp.starttls.required"))
        assertEquals("true", sender.javaMailProperties.getProperty("mail.smtp.ssl.checkserveridentity"))
        assertEquals("false", sender.javaMailProperties.getProperty("mail.smtp.ssl.enable"))
        assertEquals("5000", sender.javaMailProperties.getProperty("mail.smtp.connectiontimeout"))
        assertEquals("5000", sender.javaMailProperties.getProperty("mail.smtp.timeout"))
        assertEquals("5000", sender.javaMailProperties.getProperty("mail.smtp.writetimeout"))
        assertEquals("false", sender.javaMailProperties.getProperty("mail.debug"))
        assertEquals("false", sender.javaMailProperties.getProperty("mail.debug.auth"))
    }

    @Test
    fun `sender builds only fixed plain text content`() {
        val mailSender = RecordingMailSender()
        val sender = SmtpEmailOtpSender(mailSender, settings())
        val message = EmailOtpMessage("person@example.com", "012345", 5)

        sender.send(message)

        val sent = mailSender.sent.also(MimeMessage::saveChanges)
        assertEquals("Your Meet verification code", sent.subject)
        assertEquals("person@example.com", sent.allRecipients.single().toString())
        assertTrue(sent.contentType.startsWith("text/plain"))
        assertEquals(
            """
            Your Meet verification code is:

            012345

            This code expires in 5 minutes.
            If you did not request this code, you can ignore this email.
            """.trimIndent(),
            sent.content.toString().replace("\r\n", "\n").trimEnd(),
        )
        assertEquals("EmailOtpMessage(redacted)", message.toString())
    }

    @Test
    fun `provider failures become fixed safe exceptions without retained details`() {
        val providerMarker = "provider-exception-marker"
        val mailSender = FailingMailSender(
            MailSendException(providerMarker, SocketTimeoutException(providerMarker)),
        )
        val sender = SmtpEmailOtpSender(mailSender, settings())

        val exception = assertFailsWith<EmailOtpDeliveryException> {
            sender.send(EmailOtpMessage("person@example.com", "123456", 5))
        }

        assertEquals(1, mailSender.invocationCount, "delivery must make one provider attempt without automatic retry")
        assertEquals(EmailDeliveryFailureReason.TIMEOUT, exception.reason)
        assertEquals("Email OTP delivery failed", exception.message)
        assertNull(exception.cause)
        assertTrue(providerMarker !in exception.stackTraceToString())
    }

    @Test
    fun `invalid message material fails before the provider`() {
        val mailSender = RecordingMailSender()
        val sender = SmtpEmailOtpSender(mailSender, settings())

        val exception = assertFailsWith<EmailOtpDeliveryException> {
            sender.send(EmailOtpMessage("person@example.com", "123456\r\nBcc:x", 5))
        }

        assertEquals(EmailDeliveryFailureReason.INVALID_MESSAGE, exception.reason)
        assertTrue(!mailSender.wasInvoked)
    }

    @Test
    fun `rejects malformed From addresses before creating a sender`() {
        listOf(
            "",
            "two@example.com,other@example.com",
            "Meet <no-reply@example.com>",
            "no reply@example.com",
            "n\u00F8-reply@example.com",
            "no-reply@example",
            "no-reply@-example.com",
            "${"a".repeat(65)}@example.com",
            "no-reply@example.com\r\nBcc: victim@example.com",
        ).forEach { invalidAddress ->
            assertFailsWith<IllegalArgumentException> {
                settings(fromAddress = invalidAddress)
            }
        }
    }

    @Test
    fun `accepts timeout boundaries and applies each bounded timeout`() {
        listOf(1_000, 30_000).forEach { boundary ->
            val sender = settings(
                connectTimeoutMs = boundary,
                readTimeoutMs = boundary,
                writeTimeoutMs = boundary,
            ).createMailSender()

            assertEquals(boundary.toString(), sender.javaMailProperties.getProperty("mail.smtp.connectiontimeout"))
            assertEquals(boundary.toString(), sender.javaMailProperties.getProperty("mail.smtp.timeout"))
            assertEquals(boundary.toString(), sender.javaMailProperties.getProperty("mail.smtp.writetimeout"))
        }
    }

    @Test
    fun `rejects every timeout immediately outside the approved bounds`() {
        listOf(999, 30_001).forEach { invalid ->
            listOf<(Int) -> SmtpRuntimeSettings>(
                { settings(connectTimeoutMs = it) },
                { settings(readTimeoutMs = it) },
                { settings(writeTimeoutMs = it) },
            ).forEach { createSettings ->
                assertFailsWith<IllegalArgumentException> {
                    createSettings(invalid)
                }
            }
        }
    }

    @Test
    fun `allows a private JVM truststore without weakening SMTP properties`() {
        val property = "javax.net.ssl.trustStore"
        val previous = System.getProperty(property)
        try {
            System.setProperty(property, "private-jvm-truststore-marker.p12")

            val sender = settings().createMailSender()

            assertNull(sender.javaMailProperties.getProperty("mail.smtp.ssl.trust"))
            assertEquals("true", sender.javaMailProperties.getProperty("mail.smtp.ssl.checkserveridentity"))
            assertEquals("true", sender.javaMailProperties.getProperty("mail.smtp.starttls.required"))
        } finally {
            if (previous == null) {
                System.clearProperty(property)
            } else {
                System.setProperty(property, previous)
            }
        }
    }

    private fun settings(
        fromAddress: String = "no-reply@example.com",
        connectTimeoutMs: Int = 5_000,
        readTimeoutMs: Int = 5_000,
        writeTimeoutMs: Int = 5_000,
    ): SmtpRuntimeSettings =
        SmtpRuntimeSettings.from(
            EmailProperties(
                provider = EmailProvider.SMTP,
                fromAddress = fromAddress,
                fromName = "Meet",
                connectTimeoutMs = connectTimeoutMs,
                readTimeoutMs = readTimeoutMs,
                writeTimeoutMs = writeTimeoutMs,
            ),
            MockEnvironment()
                .withProperty("spring.mail.host", "smtp.example.com")
                .withProperty("spring.mail.port", "587")
                .withProperty("spring.mail.username", "smtp-user")
                .withProperty("spring.mail.password", "smtp-password"),
        )

    private class RecordingMailSender : JavaMailSenderImpl() {
        lateinit var sent: MimeMessage
        var wasInvoked = false

        override fun send(mimeMessage: MimeMessage) {
            wasInvoked = true
            sent = mimeMessage
        }
    }

    private class FailingMailSender(
        private val failure: RuntimeException,
    ) : JavaMailSenderImpl() {
        var invocationCount = 0

        override fun send(mimeMessage: MimeMessage): Nothing {
            invocationCount++
            throw failure
        }
    }
}
