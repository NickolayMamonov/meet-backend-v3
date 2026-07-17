package dev.whysoezzy.meet.security

import dev.whysoezzy.meet.config.AdminProperties
import jakarta.servlet.FilterChain
import jakarta.servlet.http.HttpServletRequest
import jakarta.servlet.http.HttpServletResponse
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken
import org.springframework.security.core.authority.SimpleGrantedAuthority
import org.springframework.stereotype.Component
import org.springframework.web.filter.OncePerRequestFilter
import java.security.MessageDigest

@Component
class AdminKeyAuthFilter(
    private val adminProperties: AdminProperties,
    private val apiAccessDeniedHandler: ApiAccessDeniedHandler,
) : OncePerRequestFilter() {

    override fun shouldNotFilter(request: HttpServletRequest): Boolean {
        val path = request.requestURI.removePrefix(request.contextPath)
        return path != "/admin" && !path.startsWith("/admin/")
    }

    override fun doFilterInternal(
        request: HttpServletRequest,
        response: HttpServletResponse,
        filterChain: FilterChain,
    ) {
        val configuredKey = adminProperties.apiKey
        val suppliedKey = request.getHeader(ADMIN_KEY_HEADER)

        if (
            configuredKey.isBlank() ||
            suppliedKey.isNullOrBlank() ||
            !MessageDigest.isEqual(
                configuredKey.toByteArray(Charsets.UTF_8),
                suppliedKey.toByteArray(Charsets.UTF_8),
            )
        ) {
            apiAccessDeniedHandler.handle(request, response, ADMIN_ACCESS_DENIED)
            return
        }

        val authentication = UsernamePasswordAuthenticationToken(
            ADMIN_PRINCIPAL,
            null,
            listOf(SimpleGrantedAuthority("ROLE_ADMIN")),
        )
        authentication.details = request.remoteAddr
        org.springframework.security.core.context.SecurityContextHolder.getContext().authentication = authentication

        filterChain.doFilter(request, response)
    }

    private companion object {
        const val ADMIN_KEY_HEADER = "X-Admin-Key"
        const val ADMIN_PRINCIPAL = "admin"
        val ADMIN_ACCESS_DENIED = org.springframework.security.access.AccessDeniedException("Access is denied")
    }
}
