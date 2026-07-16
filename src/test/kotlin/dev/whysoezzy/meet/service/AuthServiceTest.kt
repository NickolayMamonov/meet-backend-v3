package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.error.RateLimitException
import dev.whysoezzy.meet.domain.repository.OtpRepository
import dev.whysoezzy.meet.domain.repository.RefreshTokenRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.security.JwtService
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentMatchers.anyString
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import java.time.LocalDateTime
import kotlin.test.assertEquals

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
}
