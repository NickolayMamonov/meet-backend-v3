package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.error.RateLimitException
import dev.whysoezzy.meet.api.error.UnauthorizedException
import dev.whysoezzy.meet.domain.entity.RefreshToken
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.OtpRepository
import dev.whysoezzy.meet.domain.repository.RefreshTokenRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.security.JwtService
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentMatchers.anyString
import org.mockito.Mockito.doAnswer
import org.mockito.Mockito.mock
import org.mockito.Mockito.times
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
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
    fun `rotates refresh tokens and rejects replay while allowing the replacement`() {
        val user = User(name = "Test", surname = "User", phone = "+79990000000").apply { id = 1L }
        val originalToken = RefreshToken(
            user = user,
            token = "original-refresh-token",
            expiresAt = LocalDateTime.now().plusDays(1)
        )
        val activeTokens = mutableMapOf(originalToken.token to originalToken)

        `when`(refreshTokenRepository.findWithLockByToken(anyString())).thenAnswer {
            activeTokens[it.arguments[0] as String]
        }
        doAnswer {
            activeTokens.remove((it.arguments[0] as RefreshToken).token)
            null
        }.`when`(refreshTokenRepository).delete(any(RefreshToken::class.java))
        doAnswer {
            val savedToken = it.arguments[0] as RefreshToken
            activeTokens[savedToken.token] = savedToken
            savedToken
        }.`when`(refreshTokenRepository).save(any(RefreshToken::class.java))
        `when`(jwtService.generateAccessToken(1L, user.phone))
            .thenReturn("first-access-token", "second-access-token")

        val firstResponse = authService.refreshToken(originalToken.token)

        assertEquals("first-access-token", firstResponse.accessToken)
        assertNotEquals(originalToken.token, firstResponse.refreshToken)
        assertEquals(null, activeTokens[originalToken.token])
        assertEquals(1, activeTokens.size)
        verify(refreshTokenRepository).delete(originalToken)

        assertThrows<UnauthorizedException> {
            authService.refreshToken(originalToken.token)
        }

        val secondResponse = authService.refreshToken(firstResponse.refreshToken)

        assertEquals("second-access-token", secondResponse.accessToken)
        assertNotEquals(firstResponse.refreshToken, secondResponse.refreshToken)
        verify(refreshTokenRepository, times(3)).findWithLockByToken(anyString())
    }
}
