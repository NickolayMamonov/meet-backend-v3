package dev.whysoezzy.meet.security

import dev.whysoezzy.meet.api.error.UnauthorizedException
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.stereotype.Component

@Component
class AuthUtils {

    /**
     * Возвращает ID текущего аутентифицированного пользователя.
     * Бросает исключение если пользователь не аутентифицирован.
     */
    fun getCurrentUserId(): Long {
        val authentication = SecurityContextHolder.getContext().authentication
            ?: throw UnauthorizedException()

        return when (val principal = authentication.principal) {
            is Long -> principal
            is String -> principal.toLong()
            else -> throw UnauthorizedException()
        }
    }

    /**
     * Возвращает ID текущего пользователя или null если не аутентифицирован.
     * Используется для публичных эндпоинтов где авторизация опциональна.
     */
    fun getCurrentUserIdOrNull(): Long? {
        return try {
            getCurrentUserId()
        } catch (e: Exception) {
            null
        }
    }
}
