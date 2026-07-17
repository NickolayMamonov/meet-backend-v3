package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.VerifyOtpRequest
import dev.whysoezzy.meet.api.error.RateLimitException
import dev.whysoezzy.meet.api.error.UnauthorizedException
import dev.whysoezzy.meet.domain.entity.OtpCode
import dev.whysoezzy.meet.domain.entity.RefreshToken
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.OtpRepository
import dev.whysoezzy.meet.domain.repository.RefreshTokenRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.security.JwtService
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.mockito.ArgumentCaptor
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentMatchers.anyString
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import java.security.MessageDigest
import java.time.LocalDateTime
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

class AuthServiceTest {
    private val userRepository = mock(UserRepository::class.java)
    private val otpRepository = mock(OtpRepository::class.java)
    private val refreshTokenRepository = mock(RefreshTokenRepository::class.java)
    private val jwtService = mock(JwtService::class.java)
    private val authService = AuthService(
        userRepository = userRepository,
        otpRepository = otpRepository,
        refreshTokenRepository = refreshTokenRepository,
        jwtService = jwtService,
        otpExpirationMinutes = 5,
        maxAttemptsPerHour = 5,
        refreshTokenExpirationDays = 30,
        fakeSms = true,
    )

    @Test
    fun `rejects OTP requests over the rolling window limit with rate limit exception`() {
        `when`(
            otpRepository.countRecentAttempts(
                anyString(),
                any(LocalDateTime::class.java) ?: LocalDateTime.MIN,
            ),
        ).thenReturn(5)

        val exception = assertThrows<RateLimitException> {
            authService.sendOtp("+79990000000")
        }

        assertEquals("Too many OTP requests. Please try again later.", exception.message)
        verify(otpRepository).countRecentAttempts(
            anyString(),
            any(LocalDateTime::class.java) ?: LocalDateTime.MIN,
        )
    }

    @Test
    fun `persists a hash while returning the raw refresh token after OTP verification`() {
        val user = user()
        val otp = OtpCode("+79990000000", "123456", LocalDateTime.now().plusMinutes(1))
        `when`(
            otpRepository.findValidCode(
                anyString(),
                anyString(),
                any(LocalDateTime::class.java) ?: LocalDateTime.MIN,
            ),
        ).thenReturn(otp)
        `when`(userRepository.findByPhone("+79990000000")).thenReturn(user)
        `when`(jwtService.generateAccessToken(1L, "+79990000000")).thenReturn("access-token")

        val response = authService.verifyOtp(VerifyOtpRequest("+79990000000", "123456"))

        val refreshTokenCaptor = ArgumentCaptor.forClass(RefreshToken::class.java)
        verify(refreshTokenRepository).save(refreshTokenCaptor.capture())
        val storedToken = refreshTokenCaptor.value
        assertNotEquals(response.refreshToken, storedToken.tokenHash)
        assertEquals(64, storedToken.tokenHash.length)
        assertEquals(sha256(response.refreshToken), storedToken.tokenHash)
    }

    @Test
    fun `looks up refresh tokens by their hash`() {
        val user = user()
        val rawToken = "raw-refresh-token"
        val token = RefreshToken(user, sha256(rawToken), LocalDateTime.now().plusDays(1))
        `when`(refreshTokenRepository.findByTokenHash(sha256(rawToken))).thenReturn(token)
        `when`(jwtService.generateAccessToken(1L, "+79990000000")).thenReturn("new-access-token")

        val response = authService.refreshToken(rawToken)

        assertEquals("new-access-token", response.accessToken)
        verify(refreshTokenRepository).findByTokenHash(sha256(rawToken))
    }

    @Test
    fun `rejects an unknown refresh token after hashed lookup`() {
        val rawToken = "unknown-refresh-token"
        `when`(refreshTokenRepository.findByTokenHash(sha256(rawToken))).thenReturn(null)

        assertThrows<UnauthorizedException> {
            authService.refreshToken(rawToken)
        }

        verify(refreshTokenRepository).findByTokenHash(sha256(rawToken))
    }

    @Test
    fun `deletes expired refresh tokens found by their hash`() {
        val user = user()
        val rawToken = "expired-refresh-token"
        val token = RefreshToken(user, sha256(rawToken), LocalDateTime.now().minusSeconds(1))
        `when`(refreshTokenRepository.findByTokenHash(sha256(rawToken))).thenReturn(token)

        assertThrows<UnauthorizedException> {
            authService.refreshToken(rawToken)
        }

        verify(refreshTokenRepository).delete(token)
    }

    private fun user(): User = User("Test", "User", "+79990000000").also { it.id = 1L }

    private fun sha256(value: String): String =
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
}
