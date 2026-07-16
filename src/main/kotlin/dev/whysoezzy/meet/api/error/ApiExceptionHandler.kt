package dev.whysoezzy.meet.api.error

import jakarta.servlet.http.HttpServletRequest
import org.springframework.http.HttpStatus
import org.springframework.http.ResponseEntity
import org.springframework.http.converter.HttpMessageNotReadableException
import org.springframework.validation.FieldError
import org.springframework.web.bind.MethodArgumentNotValidException
import org.springframework.web.bind.ServletRequestBindingException
import org.springframework.web.bind.annotation.ExceptionHandler
import org.springframework.web.bind.annotation.RestControllerAdvice
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException

@RestControllerAdvice
class ApiExceptionHandler(
    private val errorWriter: ApiErrorResponseWriter,
) {
    @ExceptionHandler(ApiException::class)
    fun apiException(exception: ApiException, request: HttpServletRequest): ResponseEntity<ApiError> =
        response(exception.status, exception.message ?: "Request failed", request, exception.code)

    @ExceptionHandler(
        MethodArgumentNotValidException::class,
        MethodArgumentTypeMismatchException::class,
        HttpMessageNotReadableException::class,
        ServletRequestBindingException::class,
    )
    fun badRequest(exception: Exception, request: HttpServletRequest): ResponseEntity<ApiError> {
        val message = (exception as? MethodArgumentNotValidException)
            ?.bindingResult
            ?.allErrors
            ?.firstOrNull()
            ?.let { error -> (error as? FieldError)?.defaultMessage ?: error.defaultMessage }
            ?: "Invalid request"
        return response(HttpStatus.BAD_REQUEST, message, request, "BAD_REQUEST")
    }

    @ExceptionHandler(Exception::class)
    fun unexpected(exception: Exception, request: HttpServletRequest): ResponseEntity<ApiError> =
        response(HttpStatus.INTERNAL_SERVER_ERROR, "An unexpected error occurred", request, "INTERNAL_ERROR")

    private fun response(
        status: HttpStatus,
        message: String,
        request: HttpServletRequest,
        code: String,
    ) = ResponseEntity.status(status).body(errorWriter.body(status, message, request.requestURI, code))
}
