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
class NotFoundException(message: String) : ApiException(HttpStatus.NOT_FOUND, "NOT_FOUND", message)
class ConflictException(message: String) : ApiException(HttpStatus.CONFLICT, "CONFLICT", message)
class ForbiddenException(message: String = "Access is denied") : ApiException(HttpStatus.FORBIDDEN, "FORBIDDEN", message)
