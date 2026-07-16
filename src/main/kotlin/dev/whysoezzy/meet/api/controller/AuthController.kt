package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.*
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.service.AuthService
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import jakarta.validation.Valid
import mu.KotlinLogging
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.*

private val logger = KotlinLogging.logger {}

@RestController
@RequestMapping("/auth")
@Tag(name = "Auth", description = "SMS OTP authentication flow")
class AuthController(
    private val authService: AuthService,
    private val authUtils: AuthUtils
) {

    /**
     * Шаг 1: Отправить OTP на телефон
     * Appointment / 11 — ввод телефона, кнопка "Получить код"
     */
    @PostMapping("/send-otp")
    @Operation(summary = "Send OTP code to phone number")
    fun sendOtp(@Valid @RequestBody request: SendOtpRequest): ResponseEntity<Map<String, String>> {
        logger.info { "POST /auth/send-otp" }
        authService.sendOtp(request.phone)
        return ResponseEntity.ok(mapOf("message" to "OTP sent successfully"))
    }

    /**
     * Шаг 2: Верифицировать код и получить токены
     * Appointment / 15–17 — ввод кода, кнопка "Отправить и подтвердить запись"
     */
    @PostMapping("/verify-otp")
    @Operation(summary = "Verify OTP code and get JWT tokens")
    fun verifyOtp(@Valid @RequestBody request: VerifyOtpRequest): AuthResponse {
        logger.info { "POST /auth/verify-otp" }
        return authService.verifyOtp(request)
    }

    /**
     * Обновление access токена по refresh токену
     */
    @PostMapping("/refresh")
    @Operation(summary = "Refresh access token")
    fun refreshToken(@Valid @RequestBody request: RefreshTokenRequest): RefreshTokenResponse {
        logger.info { "POST /auth/refresh" }
        return authService.refreshToken(request.refreshToken)
    }

    /**
     * Выход из системы
     */
    @PostMapping("/logout")
    @Operation(summary = "Logout - invalidate refresh tokens", security = [SecurityRequirement(name = "bearerAuth")])
    fun logout(): ResponseEntity<Map<String, String>> {
        val userId = authUtils.getCurrentUserId()
        logger.info { "POST /auth/logout - user: $userId" }
        authService.logout(userId)
        return ResponseEntity.ok(mapOf("message" to "Logged out successfully"))
    }
}
