package dev.whysoezzy.meet.api.error

import org.springframework.http.HttpStatus
import java.time.Instant

data class ApiError(
    val status: Int,
    val message: String,
    val timestamp: Instant,
    val path: String,
    val code: String,
)

open class ApiException(
    val status: HttpStatus,
    val code: String,
    message: String,
) : RuntimeException(message)

class BadRequestException(message: String) : ApiException(HttpStatus.BAD_REQUEST, "BAD_REQUEST", message)
class ValidationException(message: String) : ApiException(HttpStatus.BAD_REQUEST, "BAD_REQUEST", message)
class NotFoundException(message: String) : ApiException(HttpStatus.NOT_FOUND, "NOT_FOUND", message)
class ConflictException(message: String) : ApiException(HttpStatus.CONFLICT, "CONFLICT", message)
class UnauthorizedException(message: String = "Authentication is required") :
    ApiException(HttpStatus.UNAUTHORIZED, "UNAUTHORIZED", message)
class ForbiddenException(message: String = "Access is denied") : ApiException(HttpStatus.FORBIDDEN, "FORBIDDEN", message)
class RateLimitException(message: String = "Too many requests. Please try again later.") :
    ApiException(HttpStatus.TOO_MANY_REQUESTS, "RATE_LIMITED", message)
class ServiceUnavailableException(message: String) :
    ApiException(HttpStatus.SERVICE_UNAVAILABLE, "SMS_UNAVAILABLE", message)
class EmailOtpRateLimitedException :
    ApiException(
        HttpStatus.TOO_MANY_REQUESTS,
        "OTP_RATE_LIMITED",
        "Too many OTP requests. Please try again later.",
    )
class EmailOtpDeliveryUnavailableException :
    ApiException(
        HttpStatus.SERVICE_UNAVAILABLE,
        "OTP_DELIVERY_UNAVAILABLE",
        "OTP delivery is temporarily unavailable.",
    )
class EmailOtpActivationUnavailableException :
    ApiException(
        HttpStatus.SERVICE_UNAVAILABLE,
        "OTP_ACTIVATION_UNAVAILABLE",
        "OTP is temporarily unavailable. Please request a new code.",
    )
class EmailOtpInvalidException :
    ApiException(
        HttpStatus.UNAUTHORIZED,
        "OTP_INVALID_OR_EXPIRED",
        "Invalid or expired OTP code.",
    )
