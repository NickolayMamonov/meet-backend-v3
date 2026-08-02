package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.AuthResponse
import dev.whysoezzy.meet.api.dto.RefreshTokenResponse
import dev.whysoezzy.meet.api.dto.UserProfileDto
import dev.whysoezzy.meet.api.dto.VerifyOtpRequest
import dev.whysoezzy.meet.api.error.EmailOtpInvalidException
import dev.whysoezzy.meet.api.error.RateLimitException
import dev.whysoezzy.meet.api.error.ServiceUnavailableException
import dev.whysoezzy.meet.api.error.UnauthorizedException
import dev.whysoezzy.meet.domain.entity.RefreshToken
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.RefreshTokenRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import dev.whysoezzy.meet.service.auth.identifier.EmailOtpVerifyCommand
import dev.whysoezzy.meet.service.auth.otp.OtpRequestCoordinator
import dev.whysoezzy.meet.service.auth.otp.OtpRequestOutcome
import dev.whysoezzy.meet.service.auth.otp.OtpRequestRateLimitExceeded
import dev.whysoezzy.meet.service.auth.otp.OtpVerificationExecutor
import dev.whysoezzy.meet.service.auth.otp.SensitiveOtpCode
import dev.whysoezzy.meet.service.auth.otp.VerificationOutcome
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.mockito.ArgumentMatchers.any
import org.mockito.Mockito.doThrow
import org.mockito.Mockito.doReturn
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.reset
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import java.time.LocalDateTime
import kotlin.test.assertEquals

class AuthServiceTest {
    private val userRepository = mock(UserRepository::class.java)
    private val refreshTokenRepository = mock(RefreshTokenRepository::class.java)
    private val requestCoordinator = mock(OtpRequestCoordinator::class.java)
    private val verificationExecutor = mock(OtpVerificationExecutor::class.java)
    private val tokenIssuer = mock(AuthTokenIssuer::class.java)
    private val authService = AuthService(
        userRepository,
        refreshTokenRepository,
        requestCoordinator,
        verificationExecutor,
        tokenIssuer,
    )

    @Test
    fun `maps phone request rate and delivery failures to the frozen contract`() {
        doThrow(OtpRequestRateLimitExceeded())
            .`when`(requestCoordinator)
            .request(anyValue(), anyValue())

        val rateLimit = assertThrows<RateLimitException> {
            authService.sendOtp("+79990000000", OtpRequestContext.EMPTY)
        }
        assertEquals("Too many OTP requests. Please try again later.", rateLimit.message)

        reset(requestCoordinator)
        doReturn(OtpRequestOutcome.DeliveryUnavailable)
            .`when`(requestCoordinator)
            .request(anyValue(), anyValue())

        val unavailable = assertThrows<ServiceUnavailableException> {
            authService.sendOtp("+79990000000", OtpRequestContext.EMPTY)
        }
        assertEquals("SMS delivery is not configured", unavailable.message)
    }

    @Test
    fun `maps invalid verification separately for phone and email`() {
        `when`(verificationExecutor.verify(anyValue())).thenReturn(VerificationOutcome.Invalid)

        val phone = assertThrows<UnauthorizedException> {
            authService.verifyOtp(VerifyOtpRequest("+79990000000", "123456"))
        }
        assertEquals("Invalid or expired OTP code", phone.message)

        val email = assertThrows<EmailOtpInvalidException> {
            authService.verifyEmailOtp(
                EmailOtpVerifyCommand(
                    identifier = AuthIdentifier.email("person@example.com"),
                    code = SensitiveOtpCode.validated("123456"),
                    name = null,
                    surname = null,
                    deviceId = null,
                ),
                OtpRequestContext.EMPTY,
            )
        }
        assertEquals("Invalid or expired OTP code.", email.message)
    }

    @Test
    fun `returns authenticated verification outcome unchanged`() {
        val expected = AuthResponse(
            accessToken = "access",
            refreshToken = "refresh",
            isNewUser = false,
            user = UserProfileDto(1, "", "", null, "+79990000000", "", "", null),
        )
        `when`(verificationExecutor.verify(anyValue()))
            .thenReturn(VerificationOutcome.Authenticated(expected))

        assertEquals(
            expected,
            authService.verifyOtp(VerifyOtpRequest("+79990000000", "123456")),
        )
    }

    @Test
    fun `rotates a valid refresh token through the shared issuer`() {
        val user = user()
        val raw = "raw-refresh-token"
        val hash = "a".repeat(64)
        val entity = RefreshToken(user, hash, LocalDateTime.now().plusDays(1))
        val expected = RefreshTokenResponse("access", "replacement")
        `when`(tokenIssuer.hashRefreshToken(raw)).thenReturn(hash)
        `when`(refreshTokenRepository.findByTokenHash(hash)).thenReturn(entity)
        `when`(userRepository.findWithLockById(1L)).thenReturn(user)
        `when`(refreshTokenRepository.findWithLockByTokenHash(hash)).thenReturn(entity)
        `when`(tokenIssuer.rotate(user, entity)).thenReturn(expected)

        assertEquals(expected, authService.refreshToken(raw))
        verify(tokenIssuer).rotate(user, entity)
    }

    @Test
    fun `rejects stale refresh versions and revokes the token`() {
        val user = user().also { it.authVersion = 2 }
        val hash = "b".repeat(64)
        val entity = RefreshToken(
            user,
            hash,
            LocalDateTime.now().plusDays(1),
            authVersion = 1,
        )
        `when`(tokenIssuer.hashRefreshToken("raw")).thenReturn(hash)
        `when`(refreshTokenRepository.findByTokenHash(hash)).thenReturn(entity)
        `when`(userRepository.findWithLockById(1L)).thenReturn(user)
        `when`(refreshTokenRepository.findWithLockByTokenHash(hash)).thenReturn(entity)

        assertThrows<UnauthorizedException> { authService.refreshToken("raw") }

        verify(refreshTokenRepository).delete(entity)
        verify(tokenIssuer, never()).rotate(user, entity)
    }

    @Test
    fun `logout increments auth version and deletes all refresh tokens`() {
        val user = user()
        `when`(userRepository.findWithLockById(1L)).thenReturn(user)

        authService.logout(1L)

        assertEquals(1, user.authVersion)
        verify(userRepository).save(user)
        verify(refreshTokenRepository).deleteAllByUserId(1L)
    }

    private fun user() = User("Test", "User", "+79990000000").also { it.id = 1L }

    @Suppress("UNCHECKED_CAST")
    private fun <T> anyValue(): T {
        any<T>()
        return null as T
    }
}
