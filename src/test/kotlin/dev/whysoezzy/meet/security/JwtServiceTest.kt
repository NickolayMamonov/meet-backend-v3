package dev.whysoezzy.meet.security

import dev.whysoezzy.meet.config.JwtConfigurationInitializer
import dev.whysoezzy.meet.config.JwtProperties
import io.jsonwebtoken.Jwts
import io.jsonwebtoken.security.Keys
import org.assertj.core.api.Assertions.assertThat
import org.springframework.boot.context.properties.EnableConfigurationProperties
import org.springframework.boot.test.context.runner.ApplicationContextRunner
import org.springframework.context.annotation.Configuration
import java.util.Date
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class JwtServiceTest {

    private val properties = JwtProperties(
        secret = "test-jwt-signing-secret-that-is-at-least-32-bytes",
        accessTokenExpirationMs = 60_000,
    )

    @Test
    fun `generates and validates access token`() {
        val service = JwtService(properties)
        val token = service.generateAccessToken(userId = 42, phone = "+15551234567", authVersion = 3)

        assertTrue(service.validateToken(token))
        assertEquals(42, service.getUserIdFromToken(token))
        assertEquals(3, service.getAuthVersionFromToken(token))
    }

    @Test
    fun `rejects tampered tokens`() {
        val service = JwtService(properties)
        val token = service.generateAccessToken(userId = 42, phone = "+15551234567", authVersion = 0)

        assertFalse(service.validateToken("${token}tampered"))
    }

    @Test
    fun `rejects expired tokens`() {
        val expiredToken = Jwts.builder()
            .subject("42")
            .expiration(Date(System.currentTimeMillis() - 1_000))
            .signWith(Keys.hmacShaKeyFor(properties.secret.toByteArray()))
            .compact()

        assertFalse(JwtService(properties).validateToken(expiredToken))
    }

    @Test
    fun `rejects missing or short signing secrets`() {
        assertFailsWith<IllegalArgumentException> { JwtProperties(secret = "") }
        assertFailsWith<IllegalArgumentException> { JwtProperties(secret = "too-short") }
    }

    @Test
    fun `accepts a 32 byte signing secret`() {
        assertEquals(
            JwtProperties.MINIMUM_SECRET_BYTES,
            JwtProperties(secret = "a".repeat(JwtProperties.MINIMUM_SECRET_BYTES)).secret.length,
        )
    }

    @Test
    fun `fails startup initialization for missing or weak signing secrets`() {
        startupContextRunner
            .run { context -> assertThat(context.startupFailure).isNotNull }

        startupContextRunner
            .withPropertyValues(*validProductionProperties(), "app.jwt.secret=too-short")
            .run { context -> assertThat(context.startupFailure).isNotNull }

    }

    @Test
    fun `fails startup initialization for missing or blank JWT secrets and database settings`() {
        listOf(
            "spring.datasource.url=",
            "spring.datasource.username=",
            "spring.datasource.password=",
        ).forEach { invalidProperty ->
            val propertyName = invalidProperty.substringBefore("=")
            startupContextRunner
                .withPropertyValues(
                    *validProductionProperties().filterNot { it.startsWith("$propertyName=") }.toTypedArray(),
                    invalidProperty,
                )
                .run { context -> assertThat(context.startupFailure).isNotNull }
        }

        startupContextRunner
            .withPropertyValues(
                *validProductionProperties().filterNot { it.startsWith("app.sms.provider=") }.toTypedArray(),
                "app.sms.provider=fake",
            )
            .run { context -> assertThat(context.startupFailure).isNotNull }
    }

    @Test
    fun `allows startup without an admin key`() {
        startupContextRunner
            .withPropertyValues(*validDevProperties())
            .run { context -> assertThat(context.startupFailure).isNull() }

        startupContextRunner
            .withPropertyValues(*validDevProperties(), "app.admin.api-key=")
            .run { context -> assertThat(context.startupFailure).isNull() }
    }

    @Test
    fun `allows fake SMS only for the dev profile`() {
        startupContextRunner
            .withPropertyValues(
                "spring.profiles.active=dev",
                "app.jwt.secret=dev-only-jwt-signing-secret-not-for-production",
                "spring.datasource.url=jdbc:postgresql://localhost:5432/meet_db",
                "spring.datasource.username=postgres",
                "spring.datasource.password=postgres",
                "app.sms.provider=fake",
            )
            .run { context -> assertThat(context.startupFailure).isNull() }
    }

    @Test
    fun `allows startup with the default disabled SMS provider outside dev`() {
        startupContextRunner
            .withPropertyValues(
                *validProductionProperties(),
            )
            .run { context ->
                assertThat(context.startupFailure).isNull()
            }
    }

    @Test
    fun `fails startup binding for unsafe access token durations`() {
        contextRunner
            .withPropertyValues(
                "app.jwt.secret=${"a".repeat(JwtProperties.MINIMUM_SECRET_BYTES)}",
                "app.jwt.access-token-expiration-ms=59999",
            )
            .run { context -> assertThat(context.startupFailure).isNotNull }
    }

    private companion object {
        val contextRunner = ApplicationContextRunner()
            .withUserConfiguration(JwtPropertiesTestConfiguration::class.java)

        val startupContextRunner = ApplicationContextRunner()
            .withInitializer(JwtConfigurationInitializer())

        fun validProductionProperties(): Array<String> = arrayOf(
            "app.jwt.secret=${"a".repeat(JwtProperties.MINIMUM_SECRET_BYTES)}",
            "app.admin.api-key=production-admin-key",
            "spring.datasource.url=jdbc:postgresql://db.example:5432/meet",
            "spring.datasource.username=meet",
            "spring.datasource.password=production-db-password",
            "app.sms.provider=disabled",
        )

        fun validDevProperties(): Array<String> = arrayOf(
            "spring.profiles.active=dev",
            "app.jwt.secret=dev-only-jwt-signing-secret-not-for-production",
            "spring.datasource.url=jdbc:postgresql://localhost:5432/meet_db",
            "spring.datasource.username=postgres",
            "spring.datasource.password=postgres",
            "app.sms.provider=fake",
        )
    }
}

@Configuration(proxyBeanMethods = false)
@EnableConfigurationProperties(JwtProperties::class)
private class JwtPropertiesTestConfiguration
