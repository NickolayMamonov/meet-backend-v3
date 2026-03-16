package dev.whysoezzy.meet.security

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
            ?: throw IllegalStateException("No authentication found in security context")

        return when (val principal = authentication.principal) {
            is Long -> principal
            is String -> principal.toLong()
            else -> throw IllegalStateException("Unexpected principal type: ${principal::class.simpleName}")
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
