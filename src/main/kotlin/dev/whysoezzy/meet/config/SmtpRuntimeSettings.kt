package dev.whysoezzy.meet.config

import jakarta.mail.internet.InternetAddress
import org.springframework.core.env.ConfigurableEnvironment
import org.springframework.core.env.EnumerablePropertySource
import org.springframework.mail.javamail.JavaMailSenderImpl
import java.nio.charset.StandardCharsets
import java.util.Properties

class SmtpRuntimeSettings private constructor(
    internal val fromAddress: String,
    internal val fromName: String,
    private val host: String,
    private val port: Int,
    private val username: String,
    private val password: String,
    private val connectTimeoutMs: Int,
    private val readTimeoutMs: Int,
    private val writeTimeoutMs: Int,
) {
    internal fun createMailSender(): JavaMailSenderImpl =
        JavaMailSenderImpl().also { sender ->
            sender.host = host
            sender.port = port
            sender.username = username
            sender.password = password
            sender.protocol = "smtp"
            sender.defaultEncoding = StandardCharsets.UTF_8.name()
            sender.javaMailProperties = Properties().apply {
                setProperty("mail.smtp.auth", "true")
                setProperty("mail.smtp.starttls.enable", "true")
                setProperty("mail.smtp.starttls.required", "true")
                setProperty("mail.smtp.ssl.checkserveridentity", "true")
                setProperty("mail.smtp.ssl.enable", "false")
                setProperty("mail.smtp.connectiontimeout", connectTimeoutMs.toString())
                setProperty("mail.smtp.timeout", readTimeoutMs.toString())
                setProperty("mail.smtp.writetimeout", writeTimeoutMs.toString())
                setProperty("mail.debug", "false")
                setProperty("mail.debug.auth", "false")
            }
        }

    internal fun internetAddress(): InternetAddress =
        InternetAddress(fromAddress, fromName, StandardCharsets.UTF_8.name())

    override fun toString(): String = "SmtpRuntimeSettings(redacted)"

    companion object {
        const val MINIMUM_TIMEOUT_MS = 1_000
        const val MAXIMUM_TIMEOUT_MS = 30_000

        fun from(email: EmailProperties, environment: ConfigurableEnvironment): SmtpRuntimeSettings {
            require(email.provider == EmailProvider.SMTP) {
                "SMTP runtime settings require the SMTP email provider"
            }
            require(email.connectTimeoutMs in MINIMUM_TIMEOUT_MS..MAXIMUM_TIMEOUT_MS) {
                "SMTP connect timeout must be between 1000 and 30000 milliseconds"
            }
            require(email.readTimeoutMs in MINIMUM_TIMEOUT_MS..MAXIMUM_TIMEOUT_MS) {
                "SMTP read timeout must be between 1000 and 30000 milliseconds"
            }
            require(email.writeTimeoutMs in MINIMUM_TIMEOUT_MS..MAXIMUM_TIMEOUT_MS) {
                "SMTP write timeout must be between 1000 and 30000 milliseconds"
            }
            validateMailbox(email.fromAddress)
            require('\r' !in email.fromName && '\n' !in email.fromName && email.fromName.length <= 100) {
                "SMTP sender name must be header-safe and at most 100 characters"
            }

            require(environment.getProperty("spring.mail.jndi-name").isNullOrBlank()) {
                "Spring Mail JNDI configuration is not supported"
            }
            require(environment.getProperty("spring.mail.protocol", "smtp").equals("smtp", ignoreCase = true)) {
                "Only the SMTP protocol is supported"
            }
            require(!environment.getProperty("spring.mail.test-connection", Boolean::class.java, false)) {
                "Spring Mail startup connection tests are not supported"
            }

            val host = required(environment, "spring.mail.host", "SMTP host")
            val username = required(environment, "spring.mail.username", "SMTP username")
            val password = required(environment, "spring.mail.password", "SMTP password")
            val port = environment.getProperty("spring.mail.port", Int::class.java, 587)
            require(port in 1..65_535) { "SMTP port must be between 1 and 65535" }

            validateProtectedOverrides(email, environment)

            return SmtpRuntimeSettings(
                fromAddress = email.fromAddress,
                fromName = email.fromName,
                host = host,
                port = port,
                username = username,
                password = password,
                connectTimeoutMs = email.connectTimeoutMs,
                readTimeoutMs = email.readTimeoutMs,
                writeTimeoutMs = email.writeTimeoutMs,
            )
        }

        private fun required(
            environment: ConfigurableEnvironment,
            property: String,
            label: String,
        ): String =
            environment.getProperty(property)?.takeIf(String::isNotBlank)
                ?: throw IllegalArgumentException("$label must be configured")

        private fun validateMailbox(address: String) {
            require(address.isNotBlank() && address.length <= 254) {
                "SMTP sender address must be exactly one supported ASCII mailbox"
            }
            require(address.all { it.code in 0x21..0x7e } && '\r' !in address && '\n' !in address) {
                "SMTP sender address must be exactly one supported ASCII mailbox"
            }
            require(isSupportedMailbox(address)) {
                "SMTP sender address must be exactly one supported ASCII mailbox"
            }
        }

        internal fun isSupportedMailbox(address: String): Boolean {
            if (
                address.isBlank() ||
                address.length > 254 ||
                address.any { it.code !in 0x21..0x7e } ||
                !ASCII_MAILBOX.matches(address)
            ) {
                return false
            }
            val local = address.substringBefore('@')
            val domain = address.substringAfterLast('@')
            return local.length in 1..64 &&
                domain.length <= 253 &&
                domain.split('.').size >= 2 &&
                domain.split('.').all { DOMAIN_LABEL.matches(it) }
        }

        private fun validateProtectedOverrides(
            email: EmailProperties,
            environment: ConfigurableEnvironment,
        ) {
            requireBoolean(environment, "spring.mail.properties.mail.smtp.auth", true)
            requireBoolean(environment, "spring.mail.properties.mail.smtp.starttls.enable", true)
            requireBoolean(environment, "spring.mail.properties.mail.smtp.starttls.required", true)
            requireBoolean(environment, "spring.mail.properties.mail.smtp.ssl.checkserveridentity", true)
            requireBoolean(environment, "spring.mail.properties.mail.smtp.ssl.enable", false)
            requireBoolean(environment, "spring.mail.properties.mail.debug", false)
            requireBoolean(environment, "spring.mail.properties.mail.debug.auth", false)
            requireTimeout(
                environment,
                "spring.mail.properties.mail.smtp.connectiontimeout",
                email.connectTimeoutMs,
            )
            requireTimeout(environment, "spring.mail.properties.mail.smtp.timeout", email.readTimeoutMs)
            requireTimeout(environment, "spring.mail.properties.mail.smtp.writetimeout", email.writeTimeoutMs)

            environment.propertySources
                .filterIsInstance<EnumerablePropertySource<*>>()
                .flatMap { source -> source.propertyNames.asSequence().map { it to source } }
                .forEach { (name, source) ->
                    val canonicalName = name.lowercase().replace(Regex("[^a-z0-9]+"), ".")
                    val isMailSetting =
                        canonicalName.startsWith("spring.mail.") ||
                            canonicalName.startsWith("spring.mail.properties.")
                    if (!isMailSetting) {
                        return@forEach
                    }
                    require(
                        "socketfactory" !in canonicalName &&
                            ".ssl.trust" !in canonicalName &&
                            ".ssl.protocols" !in canonicalName &&
                            ".ssl.ciphersuites" !in canonicalName &&
                            ".smtps." !in canonicalName &&
                            !canonicalName.endsWith(".smtps"),
                    ) {
                        "Unsafe Spring Mail trust, TLS, socket-factory, or SMTPS overrides are not supported"
                    }
                    if (canonicalName.contains("debug") || canonicalName.contains("trace")) {
                        require(!source.getProperty(name).toString().toBoolean()) {
                            "Spring Mail debug and trace output must be disabled"
                        }
                    }
                }

            listOf(
                "logging.level.org.springframework.mail",
                "logging.level.jakarta.mail",
                "logging.level.org.eclipse.angus.mail",
                "logging.level.com.sun.mail",
            ).forEach { property ->
                val level = environment.getProperty(property)?.uppercase()
                require(level != "DEBUG" && level != "TRACE" && level != "ALL") {
                    "Spring Mail debug and trace logging must be disabled"
                }
            }
        }

        private fun requireBoolean(
            environment: ConfigurableEnvironment,
            property: String,
            expected: Boolean,
        ) {
            environment.getProperty(property)?.let { configured ->
                require(configured.equals(expected.toString(), ignoreCase = true)) {
                    "Unsafe Spring Mail authentication or TLS override"
                }
            }
        }

        private fun requireTimeout(
            environment: ConfigurableEnvironment,
            property: String,
            expected: Int,
        ) {
            environment.getProperty(property)?.let { configured ->
                require(configured.toIntOrNull() == expected) {
                    "Spring Mail timeout overrides must match the bounded application timeout"
                }
            }
        }

        private val ASCII_MAILBOX = Regex(
            "^[A-Za-z0-9!#\$%&'*+/=?^_`{|}~-]+(?:\\.[A-Za-z0-9!#\$%&'*+/=?^_`{|}~-]+)*@" +
                "[A-Za-z0-9.-]+$",
        )
        private val DOMAIN_LABEL = Regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
    }
}
