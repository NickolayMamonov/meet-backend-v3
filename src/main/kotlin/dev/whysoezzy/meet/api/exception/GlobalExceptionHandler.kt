package dev.whysoezzy.meet.api.exception

import jakarta.servlet.http.HttpServletRequest
import mu.KotlinLogging
import org.springframework.http.HttpStatus
import org.springframework.http.ResponseEntity
import org.springframework.security.access.AccessDeniedException
import org.springframework.web.bind.annotation.ExceptionHandler
import org.springframework.web.bind.annotation.RestControllerAdvice
import java.time.Instant

private val logger = KotlinLogging.logger {}

data class ErrorResponse(
    val status: Int,
    val message: String,
    val timestamp: String,
    val path: String,
)

@RestControllerAdvice
class GlobalExceptionHandler {

    private fun body(status: HttpStatus, message: String, request: HttpServletRequest) =
        ResponseEntity.status(status).body(
            ErrorResponse(
                status = status.value(),
                message = message,
                timestamp = Instant.now().toString(),
                path = request.requestURI,
            )
        )

    @ExceptionHandler(NoSuchElementException::class)
    fun handleNotFound(ex: NoSuchElementException, request: HttpServletRequest): ResponseEntity<ErrorResponse> {
        logger.warn { "Not found: ${ex.message}" }
        return body(HttpStatus.NOT_FOUND, ex.message ?: "Resource not found", request)
    }

    @ExceptionHandler(IllegalArgumentException::class)
    fun handleBadRequest(ex: IllegalArgumentException, request: HttpServletRequest): ResponseEntity<ErrorResponse> {
        logger.warn { "Bad request: ${ex.message}" }
        return body(HttpStatus.BAD_REQUEST, ex.message ?: "Invalid request", request)
    }

    @ExceptionHandler(IllegalStateException::class)
    fun handleConflict(ex: IllegalStateException, request: HttpServletRequest): ResponseEntity<ErrorResponse> {
        logger.warn { "Conflict: ${ex.message}" }
        return body(HttpStatus.CONFLICT, ex.message ?: "State conflict", request)
    }

    @ExceptionHandler(AccessDeniedException::class)
    fun handleAccessDenied(ex: AccessDeniedException, request: HttpServletRequest): ResponseEntity<ErrorResponse> {
        return body(HttpStatus.FORBIDDEN, "Access denied", request)
    }

    @ExceptionHandler(Exception::class)
    fun handleGeneral(ex: Exception, request: HttpServletRequest): ResponseEntity<ErrorResponse> {
        logger.error(ex) { "Unexpected error: ${ex.message}" }
        return body(HttpStatus.INTERNAL_SERVER_ERROR, "An unexpected error occurred", request)
    }
}