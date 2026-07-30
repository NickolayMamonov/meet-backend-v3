package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.AuthResponse
import dev.whysoezzy.meet.api.dto.RefreshTokenResponse
import dev.whysoezzy.meet.api.dto.VerifyOtpRequest
import dev.whysoezzy.meet.api.error.EmailOtpActivationUnavailableException
import dev.whysoezzy.meet.api.error.EmailOtpDeliveryUnavailableException
import dev.whysoezzy.meet.api.error.EmailOtpInvalidException
import dev.whysoezzy.meet.api.error.EmailOtpRateLimitedException
import dev.whysoezzy.meet.api.error.RateLimitException
import dev.whysoezzy.meet.api.error.ServiceUnavailableException
import dev.whysoezzy.meet.api.error.UnauthorizedException
import dev.whysoezzy.meet.domain.repository.RefreshTokenRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import dev.whysoezzy.meet.service.auth.identifier.EmailOtpVerifyCommand
import dev.whysoezzy.meet.service.auth.otp.OtpRequestCoordinator
import dev.whysoezzy.meet.service.auth.otp.OtpRequestOutcome
import dev.whysoezzy.meet.service.auth.otp.OtpRequestRateLimitExceeded
import dev.whysoezzy.meet.service.auth.otp.OtpVerificationCommand
import dev.whysoezzy.meet.service.auth.otp.OtpVerificationExecutor
import dev.whysoezzy.meet.service.auth.otp.SensitiveOtpCode
import dev.whysoezzy.meet.service.auth.otp.VerificationOutcome
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

@Service
class AuthService(
    private val userRepository: UserRepository,
    private val refreshTokenRepository: RefreshTokenRepository,
    private val requestCoordinator: OtpRequestCoordinator,
    private val verificationExecutor: OtpVerificationExecutor,
    private val tokenIssuer: AuthTokenIssuer,
) {
    fun sendOtp(phone: String, context: OtpRequestContext?) {
        val identifier = AuthIdentifier.phone(phone)
        val outcome = try {
            requestCoordinator.request(identifier, context ?: OtpRequestContext.EMPTY)
        } catch (_: OtpRequestRateLimitExceeded) {
            throw RateLimitException("Too many OTP requests. Please try again later.")
        }
        when (outcome) {
            OtpRequestOutcome.Accepted -> Unit
            OtpRequestOutcome.DeliveryUnavailable ->
                throw ServiceUnavailableException("SMS delivery is not configured")
            OtpRequestOutcome.ActivationUnavailable,
            OtpRequestOutcome.PersistenceUnavailable,
            -> throw IllegalStateException("OTP persistence is unavailable")
        }
    }

    fun sendEmailOtp(identifier: AuthIdentifier, context: OtpRequestContext) {
        val outcome = try {
            requestCoordinator.request(identifier, context)
        } catch (_: OtpRequestRateLimitExceeded) {
            throw EmailOtpRateLimitedException()
        }
        when (outcome) {
            OtpRequestOutcome.Accepted -> Unit
            OtpRequestOutcome.DeliveryUnavailable -> throw EmailOtpDeliveryUnavailableException()
            OtpRequestOutcome.ActivationUnavailable -> throw EmailOtpActivationUnavailableException()
            OtpRequestOutcome.PersistenceUnavailable ->
                throw IllegalStateException("OTP persistence is unavailable")
        }
    }

    fun verifyOtp(
        request: VerifyOtpRequest,
        context: OtpRequestContext = OtpRequestContext.EMPTY,
    ): AuthResponse {
        val outcome = verificationExecutor.verify(
            OtpVerificationCommand(
                identifier = AuthIdentifier.phone(request.phone),
                code = SensitiveOtpCode.validated(request.code),
                context = context,
                name = request.name,
                surname = request.surname,
            ),
        )
        return when (outcome) {
            is VerificationOutcome.Authenticated -> outcome.response
            VerificationOutcome.Invalid ->
                throw UnauthorizedException("Invalid or expired OTP code")
        }
    }

    fun verifyEmailOtp(
        command: EmailOtpVerifyCommand,
        context: OtpRequestContext,
    ): AuthResponse {
        val outcome = verificationExecutor.verify(
            OtpVerificationCommand(
                identifier = command.identifier,
                code = command.code,
                context = context,
                name = command.name,
                surname = command.surname,
            ),
        )
        return when (outcome) {
            is VerificationOutcome.Authenticated -> outcome.response
            VerificationOutcome.Invalid -> throw EmailOtpInvalidException()
        }
    }

    @Transactional
    fun refreshToken(refreshToken: String): RefreshTokenResponse {
        val tokenHash = tokenIssuer.hashRefreshToken(refreshToken)
        val candidate = refreshTokenRepository.findByTokenHash(tokenHash)
            ?: throw UnauthorizedException("Invalid refresh token")
        val user = userRepository.findWithLockById(requireNotNull(candidate.user.id))
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
        return tokenIssuer.rotate(user, tokenEntity)
    }

    @Transactional
    fun logout(userId: Long) {
        val user = userRepository.findWithLockById(userId)
            ?: throw UnauthorizedException("User not found")
        user.authVersion += 1
        userRepository.save(user)
        refreshTokenRepository.deleteAllByUserId(userId)
    }
}
