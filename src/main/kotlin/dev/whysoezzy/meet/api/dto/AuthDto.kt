package dev.whysoezzy.meet.api.dto

import java.io.Serializable

// ===== AUTH DTOs =====

/** Запрос отправки OTP кода на телефон */
data class SendOtpRequest(
    val phone: String
) : Serializable

/** Запрос верификации OTP кода */
data class VerifyOtpRequest(
    val phone: String,
    val code: String,
    val name: String? = null,   // Только для новых пользователей
    val surname: String? = null
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
    val refreshToken: String
) : Serializable

/** Ответ с новым access токеном */
data class RefreshTokenResponse(
    val accessToken: String
) : Serializable

/** Запрос регистрации FCM токена */
data class FcmTokenRequest(
    val fcmToken: String
) : Serializable
