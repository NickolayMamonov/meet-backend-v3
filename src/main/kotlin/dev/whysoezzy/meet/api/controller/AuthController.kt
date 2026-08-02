package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.AuthResponse
import dev.whysoezzy.meet.api.dto.OtpAcceptedResponse
import dev.whysoezzy.meet.api.dto.RefreshTokenRequest
import dev.whysoezzy.meet.api.dto.RefreshTokenResponse
import dev.whysoezzy.meet.api.dto.SendEmailOtpRequest
import dev.whysoezzy.meet.api.dto.SendOtpRequest
import dev.whysoezzy.meet.api.dto.VerifyEmailOtpRequest
import dev.whysoezzy.meet.api.dto.VerifyOtpRequest
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.service.AuthService
import dev.whysoezzy.meet.service.auth.identifier.ClientRequestContextResolver
import dev.whysoezzy.meet.service.auth.identifier.DeviceIdParser
import dev.whysoezzy.meet.service.auth.identifier.EmailOtpRequestValidator
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import jakarta.servlet.http.HttpServletRequest
import jakarta.validation.Valid
import mu.KotlinLogging
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestHeader
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

private val logger = KotlinLogging.logger {}

@RestController
@RequestMapping("/auth")
@Tag(name = "Auth", description = "OTP authentication flow")
class AuthController(
    private val authService: AuthService,
    private val authUtils: AuthUtils,
    private val emailValidator: EmailOtpRequestValidator,
    private val deviceIdParser: DeviceIdParser,
    private val contextResolver: ClientRequestContextResolver,
) {
    @PostMapping("/send-otp")
    @Operation(summary = "Send OTP code to phone number")
    fun sendOtp(
        @Valid @RequestBody request: SendOtpRequest,
        @RequestHeader(name = DEVICE_HEADER, required = false) rawDeviceId: String?,
        httpRequest: HttpServletRequest,
    ): ResponseEntity<Map<String, String>> {
        logger.info { "POST /auth/send-otp" }
        val context = contextResolver.resolve(httpRequest, deviceIdParser.parse(rawDeviceId))
        authService.sendOtp(request.phone, context)
        return ResponseEntity.ok(mapOf("message" to "OTP sent successfully"))
    }

    @PostMapping("/verify-otp")
    @Operation(summary = "Verify OTP code and get JWT tokens")
    fun verifyOtp(
        @Valid @RequestBody request: VerifyOtpRequest,
        @RequestHeader(name = DEVICE_HEADER, required = false) rawDeviceId: String?,
        httpRequest: HttpServletRequest,
    ): AuthResponse {
        logger.info { "POST /auth/verify-otp" }
        val context = contextResolver.resolve(httpRequest, deviceIdParser.parse(rawDeviceId))
        return authService.verifyOtp(request, context)
    }

    @PostMapping("/email/send-otp")
    @Operation(summary = "Send OTP code to an email address")
    fun sendEmailOtp(
        @RequestBody request: SendEmailOtpRequest,
        @RequestHeader(name = DEVICE_HEADER, required = false) rawDeviceId: String?,
        httpRequest: HttpServletRequest,
    ): ResponseEntity<OtpAcceptedResponse> {
        logger.info { "POST /auth/email/send-otp" }
        val command = emailValidator.validate(request, rawDeviceId)
        authService.sendEmailOtp(
            command.identifier,
            contextResolver.resolve(httpRequest, command.deviceId),
        )
        return ResponseEntity.accepted().body(
            OtpAcceptedResponse(
                "If the address can receive email, a verification code will be sent.",
            ),
        )
    }

    @PostMapping("/email/verify-otp")
    @Operation(summary = "Verify an email OTP code and get JWT tokens")
    fun verifyEmailOtp(
        @RequestBody request: VerifyEmailOtpRequest,
        @RequestHeader(name = DEVICE_HEADER, required = false) rawDeviceId: String?,
        httpRequest: HttpServletRequest,
    ): AuthResponse {
        logger.info { "POST /auth/email/verify-otp" }
        val command = emailValidator.validate(request, rawDeviceId)
        return authService.verifyEmailOtp(
            command,
            contextResolver.resolve(httpRequest, command.deviceId),
        )
    }

    @PostMapping("/refresh")
    @Operation(summary = "Refresh access token")
    fun refreshToken(@Valid @RequestBody request: RefreshTokenRequest): RefreshTokenResponse {
        logger.info { "POST /auth/refresh" }
        return authService.refreshToken(request.refreshToken)
    }

    @PostMapping("/logout")
    @Operation(summary = "Logout - invalidate refresh tokens", security = [SecurityRequirement(name = "bearerAuth")])
    fun logout(): ResponseEntity<Map<String, String>> {
        logger.info { "POST /auth/logout" }
        authService.logout(authUtils.getCurrentUserId())
        return ResponseEntity.ok(mapOf("message" to "Logged out successfully"))
    }

    private companion object {
        const val DEVICE_HEADER = "X-Device-Id"
    }
}
