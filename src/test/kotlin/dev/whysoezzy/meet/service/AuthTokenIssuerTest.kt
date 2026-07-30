package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.config.JwtProperties
import dev.whysoezzy.meet.domain.entity.RefreshToken
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.RefreshTokenRepository
import dev.whysoezzy.meet.security.JwtService
import org.junit.jupiter.api.Test
import org.mockito.ArgumentCaptor
import org.mockito.ArgumentMatchers.any
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import java.security.MessageDigest
import java.util.HexFormat
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals

class AuthTokenIssuerTest {
    private val refreshTokens = mock(RefreshTokenRepository::class.java)
    private val jwtService = mock(JwtService::class.java)
    private val issuer = AuthTokenIssuer(
        refreshTokens,
        jwtService,
        JwtProperties(secret = "test-jwt-signing-secret-that-is-at-least-32-bytes"),
        UserProfileMapper(),
    )

    @Test
    fun `persists only the refresh token hash and preserves auth projection defaults`() {
        val user = User("Email", "User", phone = null, email = "person@example.com").also {
            it.id = 7L
            it.showMeetings = false
        }
        `when`(jwtService.generateAccessToken(7L, null, 0)).thenReturn("access")
        `when`(refreshTokens.save(any(RefreshToken::class.java))).thenAnswer { it.arguments[0] }

        val response = issuer.issue(user, isNewUser = true)

        val captor = ArgumentCaptor.forClass(RefreshToken::class.java)
        verify(refreshTokens).save(captor.capture())
        assertNotEquals(response.refreshToken, captor.value.tokenHash)
        assertEquals(sha256(response.refreshToken), captor.value.tokenHash)
        assertEquals(64, captor.value.tokenHash.length)
        assertFalse(response.user.showMeetings.not())
        assertEquals(emptyList(), response.user.interests)
        verify(jwtService).generateAccessToken(7L, null, 0)
    }

    private fun sha256(value: String): String =
        HexFormat.of().formatHex(
            MessageDigest.getInstance("SHA-256").digest(value.toByteArray()),
        )
}
