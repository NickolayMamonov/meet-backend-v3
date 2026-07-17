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
            .withPropertyValues("app.jwt.secret=too-short")
            .run { context -> assertThat(context.startupFailure).isNotNull }

        startupContextRunner
            .withPropertyValues("app.jwt.secret=${"a".repeat(JwtProperties.MINIMUM_SECRET_BYTES)}")
            .run { context -> assertThat(context.startupFailure).isNull() }
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
    }
}

@Configuration(proxyBeanMethods = false)
@EnableConfigurationProperties(JwtProperties::class)
private class JwtPropertiesTestConfiguration
