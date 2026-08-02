package dev.whysoezzy.meet.api.dto

import jakarta.validation.constraints.NotBlank
import jakarta.validation.constraints.Pattern
import jakarta.validation.constraints.Size
import java.io.Serializable

// ===== AUTH DTOs =====

/** Запрос отправки OTP кода на телефон */
data class SendOtpRequest(
    @field:Pattern(
        regexp = "^\\+[1-9]\\d{7,14}$",
        message = "Phone must be in E.164 format",
    )
    val phone: String
) : Serializable

/** Запрос верификации OTP кода */
data class VerifyOtpRequest(
    @field:Pattern(
        regexp = "^\\+[1-9]\\d{7,14}$",
        message = "Phone must be in E.164 format",
    )
    val phone: String,
    @field:Pattern(regexp = "^[0-9]{6}$", message = "OTP code must be a six-digit number")
    val code: String,
    @field:Size(max = 100, message = "Name must not exceed 100 characters")
    val name: String? = null,   // Только для новых пользователей
    @field:Size(max = 100, message = "Surname must not exceed 100 characters")
    val surname: String? = null
) : Serializable

data class SendEmailOtpRequest(
    val email: String? = null,
) : Serializable

data class VerifyEmailOtpRequest(
    val email: String? = null,
    val code: String? = null,
    val name: String? = null,
    val surname: String? = null,
) : Serializable

data class OtpAcceptedResponse(
    val message: String,
) : Serializable

/** Ответ с токенами */
data class AuthResponse(
    val accessToken: String,
    val refreshToken: String,
    val isNewUser: Boolean,
    val user: UserProfileDto
) : Serializable

/** Запрос обновления access токена */
data class RefreshTokenRequest(
    @field:NotBlank(message = "Refresh token is required")
    @field:Size(max = 4096, message = "Refresh token is too long")
    val refreshToken: String
) : Serializable

/** Ответ с новым access токеном */
data class RefreshTokenResponse(
    val accessToken: String,
    val refreshToken: String
) : Serializable

/** Запрос регистрации FCM токена */
data class FcmTokenRequest(
    @field:NotBlank(message = "FCM token is required")
    @field:Size(max = 4096, message = "FCM token is too long")
    val fcmToken: String
) : Serializable
