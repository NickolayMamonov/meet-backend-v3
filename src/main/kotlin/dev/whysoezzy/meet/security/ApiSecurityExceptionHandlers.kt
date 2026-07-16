package dev.whysoezzy.meet.security

import dev.whysoezzy.meet.api.error.ApiErrorResponseWriter
import jakarta.servlet.http.HttpServletRequest
import jakarta.servlet.http.HttpServletResponse
import org.springframework.http.HttpStatus
import org.springframework.security.core.AuthenticationException
import org.springframework.security.web.AuthenticationEntryPoint
import org.springframework.security.web.access.AccessDeniedHandler
import org.springframework.stereotype.Component

@Component
class ApiAuthenticationEntryPoint(
    private val apiErrorResponseWriter: ApiErrorResponseWriter,
) : AuthenticationEntryPoint {
    override fun commence(
        request: HttpServletRequest,
        response: HttpServletResponse,
        authException: AuthenticationException,
    ) {
        apiErrorResponseWriter.write(
            request,
            response,
            HttpStatus.UNAUTHORIZED,
            "Authentication is required",
            "UNAUTHORIZED",
        )
    }
}

@Component
class ApiAccessDeniedHandler(
    private val apiErrorResponseWriter: ApiErrorResponseWriter,
) : AccessDeniedHandler {
    override fun handle(
        request: HttpServletRequest,
        response: HttpServletResponse,
        accessDeniedException: org.springframework.security.access.AccessDeniedException,
    ) {
        apiErrorResponseWriter.write(
            request,
            response,
            HttpStatus.FORBIDDEN,
            "Access is denied",
            "FORBIDDEN",
        )
    }
}
