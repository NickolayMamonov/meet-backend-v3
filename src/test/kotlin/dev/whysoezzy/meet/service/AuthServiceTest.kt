package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.VerifyOtpRequest
import dev.whysoezzy.meet.api.error.RateLimitException
import dev.whysoezzy.meet.api.error.ServiceUnavailableException
import dev.whysoezzy.meet.api.error.UnauthorizedException
import dev.whysoezzy.meet.config.JwtProperties
import dev.whysoezzy.meet.config.OtpProperties
import dev.whysoezzy.meet.domain.entity.OtpCode
import dev.whysoezzy.meet.domain.entity.RefreshToken
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.OtpRepository
import dev.whysoezzy.meet.domain.repository.RefreshTokenRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.security.JwtService
import dev.whysoezzy.meet.service.sms.SmsSender
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.mockito.ArgumentCaptor
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentMatchers.anyString
import org.mockito.Mockito.doAnswer
import org.mockito.Mockito.mock
import org.mockito.Mockito.times
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import java.security.MessageDigest
import java.time.LocalDateTime
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class AuthServiceTest {
    private val userRepository = mock(UserRepository::class.java)
    private val otpRepository = mock(OtpRepository::class.java)
    private val refreshTokenRepository = mock(RefreshTokenRepository::class.java)
    private val jwtService = mock(JwtService::class.java)
    private val smsSender = TestSmsSender()
    private val authService = AuthService(
        userRepository = userRepository,
        otpRepository = otpRepository,
        refreshTokenRepository = refreshTokenRepository,
        jwtService = jwtService,
        jwtProperties = JwtProperties(secret = "test-jwt-signing-secret-that-is-at-least-32-bytes"),
        otpProperties = OtpProperties(),
        smsSender = smsSender,
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
    fun `persists a normalized phone with a six-digit numeric OTP`() {
        authService.sendOtp("8 (999) 000-00-00")

        val otpCaptor = ArgumentCaptor.forClass(OtpCode::class.java)
        verify(otpRepository).save(otpCaptor.capture())
        val savedOtp = otpCaptor.value

        assertEquals("+79990000000", savedOtp.phone)
        assertEquals(savedOtp.phone, smsSender.deliveries.single().phone)
        assertTrue(savedOtp.code.matches(Regex("^\\d{6}$")))
        assertEquals(savedOtp.code, smsSender.deliveries.single().code)
    }

    @Test
    fun `does not persist OTP when SMS delivery is unavailable`() {
        smsSender.failure = ServiceUnavailableException("SMS delivery is not configured")

        assertThrows<ServiceUnavailableException> {
            authService.sendOtp("+79990000000")
        }

        verify(otpRepository, org.mockito.Mockito.never()).save(any(OtpCode::class.java))
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
        `when`(jwtService.generateAccessToken(1L, "+79990000000", 0)).thenReturn("access-token")

        val response = authService.verifyOtp(VerifyOtpRequest("+79990000000", "123456"))

        val refreshTokenCaptor = ArgumentCaptor.forClass(RefreshToken::class.java)
        verify(refreshTokenRepository).save(refreshTokenCaptor.capture())
        val storedToken = refreshTokenCaptor.value
        assertNotEquals(response.refreshToken, storedToken.tokenHash)
        assertEquals(64, storedToken.tokenHash.length)
        assertEquals(sha256(response.refreshToken), storedToken.tokenHash)
    }

    @Test
    fun `rotates refresh token, rejects old-token replay, and accepts replacement`() {
        val user = user()
        val oldRawToken = "raw-refresh-token"
        val oldToken = RefreshToken(user, sha256(oldRawToken), LocalDateTime.now().plusDays(1))
        val tokensByHash = mutableMapOf(oldToken.tokenHash to oldToken)
        `when`(refreshTokenRepository.findByTokenHash(anyString())).thenAnswer {
            tokensByHash[it.getArgument(0)]
        }
        `when`(refreshTokenRepository.findWithLockByTokenHash(anyString())).thenAnswer {
            tokensByHash[it.getArgument(0)]
        }
        doAnswer {
            tokensByHash.remove((it.arguments[0] as RefreshToken).tokenHash)
            null
        }.`when`(refreshTokenRepository).delete(any(RefreshToken::class.java))
        doAnswer {
            val replacement = it.arguments[0] as RefreshToken
            tokensByHash[replacement.tokenHash] = replacement
            replacement
        }.`when`(refreshTokenRepository).save(any(RefreshToken::class.java))
        `when`(userRepository.findWithLockById(1L)).thenReturn(user)
        `when`(jwtService.generateAccessToken(1L, "+79990000000", 0)).thenReturn("new-access-token")

        val firstResponse = authService.refreshToken(oldRawToken)

        assertEquals("new-access-token", firstResponse.accessToken)
        assertNotEquals(oldRawToken, firstResponse.refreshToken)
        verify(refreshTokenRepository).delete(oldToken)
        assertEquals(sha256(firstResponse.refreshToken), tokensByHash.keys.single())

        assertThrows<UnauthorizedException> {
            authService.refreshToken(oldRawToken)
        }

        val replacementResponse = authService.refreshToken(firstResponse.refreshToken)

        assertEquals("new-access-token", replacementResponse.accessToken)
        assertNotEquals(firstResponse.refreshToken, replacementResponse.refreshToken)
        verify(refreshTokenRepository).findWithLockByTokenHash(sha256(oldRawToken))
        verify(refreshTokenRepository).findWithLockByTokenHash(sha256(firstResponse.refreshToken))
    }

    @Test
    fun `rejects an unknown refresh token after hashed lookup`() {
        val rawToken = "unknown-refresh-token"
        `when`(refreshTokenRepository.findByTokenHash(sha256(rawToken))).thenReturn(null)
        `when`(refreshTokenRepository.findWithLockByTokenHash(sha256(rawToken))).thenReturn(null)

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
        `when`(refreshTokenRepository.findWithLockByTokenHash(sha256(rawToken))).thenReturn(token)
        `when`(userRepository.findWithLockById(1L)).thenReturn(user)

        assertThrows<UnauthorizedException> {
            authService.refreshToken(rawToken)
        }

        verify(refreshTokenRepository).delete(token)
    }

    @Test
    fun `logout increments auth version and revokes every refresh token`() {
        val user = user()
        `when`(userRepository.findWithLockById(1L)).thenReturn(user)

        authService.logout(1L)

        assertEquals(1, user.authVersion)
        verify(userRepository).save(user)
        verify(refreshTokenRepository).deleteAllByUserId(1L)
    }

    @Test
    fun `rejects refresh token from a prior authentication version`() {
        val user = user().also { it.authVersion = 1 }
        val rawToken = "old-version-token"
        val token = RefreshToken(user, sha256(rawToken), LocalDateTime.now().plusDays(1), authVersion = 0)
        `when`(refreshTokenRepository.findByTokenHash(sha256(rawToken))).thenReturn(token)
        `when`(refreshTokenRepository.findWithLockByTokenHash(sha256(rawToken))).thenReturn(token)
        `when`(userRepository.findWithLockById(1L)).thenReturn(user)

        assertThrows<UnauthorizedException> { authService.refreshToken(rawToken) }

        verify(refreshTokenRepository).delete(token)
    }

    private fun user(): User = User("Test", "User", "+79990000000").also { it.id = 1L }

    private fun sha256(value: String): String =
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }

    private class TestSmsSender : SmsSender {
        val deliveries = mutableListOf<Delivery>()
        var failure: RuntimeException? = null

        override fun sendOtp(phone: String, code: String) {
            failure?.let { throw it }
            deliveries += Delivery(phone, code)
        }
    }

    private data class Delivery(val phone: String, val code: String)
}
