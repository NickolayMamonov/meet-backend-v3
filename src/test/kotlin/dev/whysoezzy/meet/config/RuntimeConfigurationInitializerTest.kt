package dev.whysoezzy.meet.config

import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.springframework.boot.test.context.runner.ApplicationContextRunner

class RuntimeConfigurationInitializerTest {
    @Test
    fun `default and production profiles require safe SMTP and HMAC settings`() {
        runner.withPropertyValues(*validProductionProperties()).run { context ->
            assertThat(context.startupFailure).isNull()
        }
        runner.withPropertyValues(*validProductionProperties(), "spring.profiles.active=prod").run { context ->
            assertThat(context.startupFailure).isNull()
        }

        listOf(
            "app.email.provider=disabled",
            "spring.mail.host=",
            "spring.mail.username=",
            "spring.mail.password=",
            "app.email.from-address=",
            "app.otp.hash.current-key-id=",
            "app.otp.hash.current-key-base64=",
        ).forEach { invalid ->
            val name = invalid.substringBefore('=')
            runner.withPropertyValues(
                *validProductionProperties().filterNot { it.startsWith("$name=") }.toTypedArray(),
                invalid,
            ).run { context ->
                assertThat(context.startupFailure).isNotNull
            }
        }
    }

    @Test
    fun `exact dev and test are nonproduction while weakening mixed profiles fail`() {
        runner.withPropertyValues(*validNonProductionProperties("dev"), "app.sms.provider=fake").run { context ->
            assertThat(context.startupFailure).isNull()
        }
        runner.withPropertyValues(*validNonProductionProperties("test")).run { context ->
            assertThat(context.startupFailure).isNull()
        }

        listOf("prod,dev", "dev,test", "test,staging").forEach { profiles ->
            runner.withPropertyValues(
                *validNonProductionProperties("dev")
                    .filterNot { it.startsWith("spring.profiles.active=") }
                    .toTypedArray(),
                "spring.profiles.active=$profiles",
            ).run { context ->
                assertThat(context.startupFailure).isNotNull
            }
        }
    }

    @Test
    fun `rejects unsafe effective Spring Mail overrides`() {
        listOf(
            "spring.mail.jndi-name=java:comp/env/mail/session",
            "spring.mail.protocol=smtps",
            "spring.mail.test-connection=true",
            "spring.mail.properties.mail.smtp.auth=false",
            "spring.mail.properties.mail.smtp.starttls.enable=false",
            "spring.mail.properties.mail.smtp.starttls.required=false",
            "spring.mail.properties.mail.smtp.ssl.checkserveridentity=false",
            "spring.mail.properties.mail.smtp.ssl.enable=true",
            "spring.mail.properties.mail.smtp.ssl.trust=*",
            "spring.mail.properties.mail.smtp.ssl.protocols=TLSv1",
            "spring.mail.properties.mail.smtp.ssl.ciphersuites=TLS_RSA_WITH_AES_128_CBC_SHA",
            "spring.mail.properties.mail.smtp.ssl.socketFactory.class=unsafe.Factory",
            "spring.mail.properties.mail.debug=true",
            "spring.mail.properties.mail.smtp.timeout=999",
            "logging.level.org.eclipse.angus.mail=TRACE",
        ).forEach { unsafe ->
            runner.withPropertyValues(*validProductionProperties(), unsafe).run { context ->
                assertThat(context.startupFailure).isNotNull
            }
        }
    }

    @Test
    fun `startup failures do not retain secret values`() {
        val passwordMarker = "smtp-password-marker"
        val keyMarker = "key-material-marker"
        runner.withPropertyValues(
            *validProductionProperties()
                .filterNot {
                    it.startsWith("spring.mail.password=") ||
                        it.startsWith("app.otp.hash.current-key-base64=")
                }
                .toTypedArray(),
            "spring.mail.password=$passwordMarker",
            "app.otp.hash.current-key-base64=$keyMarker",
        ).run { context ->
            val failure = context.startupFailure
            assertThat(failure).isNotNull
            assertThat(failure!!.stackTraceToString())
                .doesNotContain(passwordMarker)
                .doesNotContain(keyMarker)
        }
    }

    private companion object {
        val runner = ApplicationContextRunner().withInitializer(RuntimeConfigurationInitializer())

        fun validProductionProperties(): Array<String> = arrayOf(
            "app.jwt.secret=${"j".repeat(32)}",
            "spring.datasource.url=jdbc:postgresql://db.example:5432/meet",
            "spring.datasource.username=meet",
            "spring.datasource.password=database-password",
            "app.sms.provider=disabled",
            "app.email.provider=smtp",
            "app.email.from-address=no-reply@example.com",
            "app.email.from-name=Meet",
            "spring.mail.host=smtp.example.com",
            "spring.mail.port=587",
            "spring.mail.username=smtp-user",
            "spring.mail.password=smtp-password",
            "app.otp.hash.current-key-id=production-current",
            "app.otp.hash.current-key-base64=${java.util.Base64.getEncoder().encodeToString(ByteArray(32) { 7 })}",
        )

        fun validNonProductionProperties(profile: String): Array<String> = arrayOf(
            "spring.profiles.active=$profile",
            "app.jwt.secret=${"j".repeat(32)}",
            "spring.datasource.url=jdbc:postgresql://localhost:5432/meet",
            "spring.datasource.username=meet",
            "spring.datasource.password=database-password",
            "app.sms.provider=disabled",
            "app.email.provider=fake",
            "app.otp.hash.current-key-id=${if (profile == "test") "test-current" else "dev-current"}",
            "app.otp.hash.current-key-base64=${
                if (profile == "test") {
                    RuntimeConfigurationValidator.NON_PRODUCTION_TEST_KEY_BASE64
                } else {
                    RuntimeConfigurationValidator.NON_PRODUCTION_DEV_KEY_BASE64
                }
            }",
        )
    }
}
