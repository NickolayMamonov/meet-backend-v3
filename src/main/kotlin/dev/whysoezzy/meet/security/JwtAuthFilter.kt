package dev.whysoezzy.meet.security

import dev.whysoezzy.meet.domain.repository.UserRepository
import jakarta.servlet.FilterChain
import jakarta.servlet.http.HttpServletRequest
import jakarta.servlet.http.HttpServletResponse
import mu.KotlinLogging
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken
import org.springframework.security.core.authority.SimpleGrantedAuthority
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.security.web.authentication.WebAuthenticationDetailsSource
import org.springframework.stereotype.Component
import org.springframework.web.filter.OncePerRequestFilter

private val logger = KotlinLogging.logger {}

@Component
class JwtAuthFilter(
    private val jwtService: JwtService,
    private val userRepository: UserRepository,
) : OncePerRequestFilter() {

    override fun doFilterInternal(
        request: HttpServletRequest,
        response: HttpServletResponse,
        filterChain: FilterChain
    ) {
        val authHeader = request.getHeader("Authorization")

        if (authHeader == null || !authHeader.startsWith("Bearer ")) {
            filterChain.doFilter(request, response)
            return
        }

        val token = authHeader.substring(7)

        try {
            if (jwtService.validateToken(token)) {
                val userId = jwtService.getUserIdFromToken(token)
                val tokenAuthVersion = jwtService.getAuthVersionFromToken(token)
                val user = userRepository.findById(userId).orElse(null)
                if (tokenAuthVersion == null || user == null || user.isDeleted || user.authVersion != tokenAuthVersion) {
                    filterChain.doFilter(request, response)
                    return
                }

                val authentication = UsernamePasswordAuthenticationToken(
                    userId,
                    null,
                    listOf(SimpleGrantedAuthority("ROLE_USER"))
                )
                authentication.details = WebAuthenticationDetailsSource().buildDetails(request)
                SecurityContextHolder.getContext().authentication = authentication

                logger.debug { "Authenticated user: $userId" }
            }
        } catch (e: Exception) {
            logger.warn { "Failed to authenticate JWT: ${e.message}" }
        }

        filterChain.doFilter(request, response)
    }
}
