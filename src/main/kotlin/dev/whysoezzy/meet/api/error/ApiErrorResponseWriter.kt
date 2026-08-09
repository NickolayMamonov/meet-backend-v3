package dev.whysoezzy.meet.api.error

import tools.jackson.databind.ObjectMapper
import jakarta.servlet.http.HttpServletRequest
import jakarta.servlet.http.HttpServletResponse
import org.springframework.http.HttpStatus
import org.springframework.http.MediaType
import org.springframework.stereotype.Component
import java.time.Instant

@Component
class ApiErrorResponseWriter(
    private val objectMapper: ObjectMapper,
) {
    fun body(status: HttpStatus, message: String, path: String, code: String) = ApiError(
        status = status.value(),
        message = message,
        timestamp = Instant.now(),
        path = path,
        code = code,
    )

    fun write(
        request: HttpServletRequest,
        response: HttpServletResponse,
        status: HttpStatus,
        message: String,
        code: String,
    ) {
        response.status = status.value()
        response.contentType = MediaType.APPLICATION_JSON_VALUE
        objectMapper.writeValue(response.outputStream, body(status, message, request.requestURI, code))
    }
}
