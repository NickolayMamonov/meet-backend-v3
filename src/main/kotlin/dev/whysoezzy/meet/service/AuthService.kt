package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.*
import dev.whysoezzy.meet.api.error.RateLimitException
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
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.LocalDateTime
import java.util.Base64
import java.util.HexFormat
import kotlin.random.Random

@Service
class AuthService(
    private val userRepository: UserRepository,
    private val otpRepository: OtpRepository,
    private val refreshTokenRepository: RefreshTokenRepository,
    private val jwtService: JwtService,
    private val jwtProperties: JwtProperties,
    private val otpProperties: OtpProperties,
) {

    /**
     * Отправить OTP-код на телефон.
     * Если пользователь не существует — создаём «заготовку» без имени.
     */
    @Transactional
    fun sendOtp(phone: String) {
        val normalizedPhone = normalizePhone(phone)

        // Rate limiting
        val recentAttempts = otpRepository.countRecentAttempts(
            normalizedPhone,
            LocalDateTime.now().minusHours(1)
        )
        if (recentAttempts >= otpProperties.maxAttemptsPerHour) {
            throw RateLimitException("Too many OTP requests. Please try again later.")
        }

        val code = generateOtpCode()
        val expiresAt = LocalDateTime.now().plusMinutes(otpProperties.expirationMinutes)

        val otp = OtpCode(
            phone = normalizedPhone,
            code = code,
            expiresAt = expiresAt
        )
        otpRepository.save(otp)

        // В реальном приложении здесь был бы вызов SMS-провайдера (Twilio, СМС.ру и т.д.)
        if (otpProperties.fakeSms) {
        } else {
            sendSmsViProvider(normalizedPhone, code)
        }
    }

    /**
     * Верифицировать OTP и вернуть токены.
     * Если пользователь новый — создаём его.
     */
    @Transactional
    fun verifyOtp(request: VerifyOtpRequest): AuthResponse {
        val normalizedPhone = normalizePhone(request.phone)

        val otp = otpRepository.findValidCode(normalizedPhone, request.code)
            ?: throw UnauthorizedException("Invalid or expired OTP code")

        // Помечаем код как использованный
        otp.isUsed = true
        otpRepository.save(otp)

        // Ищем или создаём пользователя
        var user = userRepository.findByPhone(normalizedPhone)
        val isNewUser = user == null

        if (isNewUser) {
            user = User(
                phone = normalizedPhone,
                name = request.name ?: "",
                surname = request.surname ?: ""
            )
            userRepository.save(user)
        } else {
            // Проверяем soft delete — восстанавливаем аккаунт
            if (user!!.isDeleted) {
                user.deletedAt = null
                userRepository.save(user)
            }
        }

        return issueTokens(user!!, isNewUser)
    }

    /**
     * Обновить access token по refresh token
     */
    @Transactional
    fun refreshToken(refreshToken: String): RefreshTokenResponse {
        val tokenHash = hashRefreshToken(refreshToken)
        val tokenCandidate = refreshTokenRepository.findByTokenHash(tokenHash)
            ?: throw UnauthorizedException("Invalid refresh token")
        val user = userRepository.findWithLockById(tokenCandidate.user.id!!)
            ?: throw UnauthorizedException("Invalid refresh token")
        val tokenEntity = refreshTokenRepository.findWithLockByTokenHash(tokenHash)
            ?: throw UnauthorizedException("Invalid refresh token")

        if (tokenEntity.isExpired) {
            refreshTokenRepository.delete(tokenEntity)
            throw UnauthorizedException("Invalid refresh token")
        }

        if (user.isDeleted || tokenEntity.authVersion != user.authVersion) {
            refreshTokenRepository.delete(tokenEntity)
            throw UnauthorizedException("Invalid refresh token")
        }
        val newAccessToken = jwtService.generateAccessToken(user.id!!, user.phone, user.authVersion)
        refreshTokenRepository.delete(tokenEntity)

        val replacementToken = generateRefreshToken()
        refreshTokenRepository.save(
            RefreshToken(
                user = user,
                tokenHash = hashRefreshToken(replacementToken),
                expiresAt = LocalDateTime.now().plusDays(jwtProperties.refreshTokenExpirationDays),
                authVersion = user.authVersion,
            )
        )

        return RefreshTokenResponse(
            accessToken = newAccessToken,
            refreshToken = replacementToken
        )
    }

    /**
     * Выход из системы — инвалидируем все refresh токены пользователя
     */
    @Transactional
    fun logout(userId: Long) {
        val user = userRepository.findWithLockById(userId)
            ?: throw UnauthorizedException("User not found")
        user.authVersion += 1
        userRepository.save(user)
        refreshTokenRepository.deleteAllByUserId(userId)
    }

    // ==================== Private ====================

    private fun issueTokens(user: User, isNewUser: Boolean): AuthResponse {
        val accessToken = jwtService.generateAccessToken(user.id!!, user.phone, user.authVersion)

        val refreshTokenValue = generateRefreshToken()
        val refreshTokenEntity = RefreshToken(
            user = user,
            tokenHash = hashRefreshToken(refreshTokenValue),
            expiresAt = LocalDateTime.now().plusDays(jwtProperties.refreshTokenExpirationDays),
            authVersion = user.authVersion,
        )
        refreshTokenRepository.save(refreshTokenEntity)

        val userProfile = UserProfileDto(
            id = user.id!!,
            name = user.name,
            surname = user.surname,
            email = user.email,
            phone = user.phone,
            city = user.city,
            description = user.bio,
            avatarUrl = user.avatarUrl,
            socialMedias = user.socialMedia.map { SocialMediaDto(it.platform.name.lowercase(), it.username) }
        )

        return AuthResponse(
            accessToken = accessToken,
            refreshToken = refreshTokenValue,
            isNewUser = isNewUser,
            user = userProfile
        )
    }

    private fun generateOtpCode(): String {
        return Random.nextInt(1000, 9999).toString()
    }

    private fun generateRefreshToken(): String {
        val tokenBytes = ByteArray(REFRESH_TOKEN_BYTES)
        secureRandom.nextBytes(tokenBytes)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(tokenBytes)
    }

    private fun hashRefreshToken(refreshToken: String): String =
        HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(refreshToken.toByteArray(Charsets.UTF_8)))

    private fun normalizePhone(phone: String): String {
        // Приводим к формату +7XXXXXXXXXX
        val digits = phone.filter { it.isDigit() }
        return when {
            digits.startsWith("8") && digits.length == 11 -> "+7${digits.substring(1)}"
            digits.startsWith("7") && digits.length == 11 -> "+$digits"
            digits.length == 10 -> "+7$digits"
            else -> phone
        }
    }

    @Suppress("UNUSED_PARAMETER")
    private fun sendSmsViProvider(phone: String, code: String): Nothing {
        throw IllegalStateException(
            "SMS delivery is not implemented. Use fake SMS only with the dev profile until a provider is integrated.",
        )
    }

    private companion object {
        const val REFRESH_TOKEN_BYTES = 32
        val secureRandom = SecureRandom()
    }
}
