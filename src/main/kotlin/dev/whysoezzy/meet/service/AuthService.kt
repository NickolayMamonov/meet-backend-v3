package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.*
import dev.whysoezzy.meet.api.error.RateLimitException
import dev.whysoezzy.meet.api.error.UnauthorizedException
import dev.whysoezzy.meet.domain.entity.OtpCode
import dev.whysoezzy.meet.domain.entity.RefreshToken
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.OtpRepository
import dev.whysoezzy.meet.domain.repository.RefreshTokenRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.security.JwtService
import mu.KotlinLogging
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime
import java.util.UUID
import kotlin.random.Random

private val logger = KotlinLogging.logger {}

@Service
class AuthService(
    private val userRepository: UserRepository,
    private val otpRepository: OtpRepository,
    private val refreshTokenRepository: RefreshTokenRepository,
    private val jwtService: JwtService,
    @Value("\${app.otp.expiration-minutes:5}") private val otpExpirationMinutes: Long,
    @Value("\${app.otp.max-attempts-per-hour:5}") private val maxAttemptsPerHour: Long,
    @Value("\${app.jwt.refresh-token-expiration-days:30}") private val refreshTokenExpirationDays: Long,
    @Value("\${app.otp.fake-sms:true}") private val fakeSms: Boolean
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
        if (recentAttempts >= maxAttemptsPerHour) {
            throw RateLimitException("Too many OTP requests. Please try again later.")
        }

        val code = generateOtpCode()
        val expiresAt = LocalDateTime.now().plusMinutes(otpExpirationMinutes)

        val otp = OtpCode(
            phone = normalizedPhone,
            code = code,
            expiresAt = expiresAt
        )
        otpRepository.save(otp)

        // В реальном приложении здесь был бы вызов SMS-провайдера (Twilio, СМС.ру и т.д.)
        if (fakeSms) {
            logger.info { "📱 [FAKE SMS] Phone: $normalizedPhone, Code: $code (expires in $otpExpirationMinutes min)" }
        } else {
            sendSmsViProvider(normalizedPhone, code)
        }

        logger.info { "OTP sent to $normalizedPhone" }
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
            logger.info { "New user created: $normalizedPhone" }
        } else {
            // Проверяем soft delete — восстанавливаем аккаунт
            if (user!!.isDeleted) {
                user.deletedAt = null
                userRepository.save(user)
                logger.info { "Account restored for: $normalizedPhone" }
            }
        }

        return issueTokens(user!!, isNewUser)
    }

    /**
     * Обновить access token по refresh token
     */
    @Transactional
    fun refreshToken(refreshToken: String): RefreshTokenResponse {
        val tokenEntity = refreshTokenRepository.findByToken(refreshToken)
            ?: throw UnauthorizedException("Invalid refresh token")

        if (tokenEntity.isExpired) {
            refreshTokenRepository.delete(tokenEntity)
            throw UnauthorizedException("Invalid refresh token")
        }

        val user = tokenEntity.user
        val newAccessToken = jwtService.generateAccessToken(user.id!!, user.phone)

        return RefreshTokenResponse(accessToken = newAccessToken)
    }

    /**
     * Выход из системы — инвалидируем все refresh токены пользователя
     */
    @Transactional
    fun logout(userId: Long) {
        refreshTokenRepository.deleteAllByUserId(userId)
        logger.info { "User $userId logged out" }
    }

    // ==================== Private ====================

    private fun issueTokens(user: User, isNewUser: Boolean): AuthResponse {
        val accessToken = jwtService.generateAccessToken(user.id!!, user.phone)

        val refreshTokenValue = UUID.randomUUID().toString()
        val refreshTokenEntity = RefreshToken(
            user = user,
            token = refreshTokenValue,
            expiresAt = LocalDateTime.now().plusDays(refreshTokenExpirationDays)
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

    private fun sendSmsViProvider(phone: String, code: String) {
        // TODO: подключить реального SMS-провайдера
        // Например, СМС.ру: https://sms.ru/api/send
        // Twilio, Vonage и т.д.
        logger.info { "Sending SMS to $phone with code $code" }
    }
}
