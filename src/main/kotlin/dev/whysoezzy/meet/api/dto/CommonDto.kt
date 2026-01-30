package dev.whysoezzy.meet.api.dto

import java.io.Serializable

/**
 * Standard API response wrapper
 */
data class ApiResponse<T>(
    val success: Boolean,
    val data: T? = null,
    val message: String? = null,
    val error: ErrorDto? = null
) : Serializable {
    companion object {
        fun <T> success(data: T, message: String? = null) = ApiResponse(
            success = true,
            data = data,
            message = message
        )
        
        fun <T> error(code: String, message: String) = ApiResponse<T>(
            success = false,
            error = ErrorDto(code, message)
        )
    }
}

data class ErrorDto(
    val code: String,
    val message: String
) : Serializable

/**
 * Tag DTO for API responses
 */
data class TagDto(
    val id: Long,
    val text: String
) : Serializable
