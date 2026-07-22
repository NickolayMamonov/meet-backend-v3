package dev.whysoezzy.meet.api.dto

import jakarta.validation.Valid
import jakarta.validation.constraints.Email
import jakarta.validation.constraints.NotBlank
import jakarta.validation.constraints.Positive
import jakarta.validation.constraints.Size
import java.io.Serializable

/** DTO для полного профиля пользователя */
data class UserProfileDto(
    val id: Long,
    val name: String,
    val surname: String,
    val email: String?,
    val phone: String?,
    val city: String?,
    val description: String?,
    val avatarUrl: String?,
    val interests: List<TagDto> = emptyList(),
    val socialMedias: List<SocialMediaDto> = emptyList(),
    // Настройки
    val showCommunities: Boolean = true,
    val showMeetings: Boolean = true,
    val notificationsEnabled: Boolean = true
) : Serializable

/** DTO для обновления профиля */
data class UpdateUserDto(
    @field:Size(max = 100, message = "Name must not exceed 100 characters")
    val name: String? = null,
    @field:Size(max = 100, message = "Surname must not exceed 100 characters")
    val surname: String? = null,
    @field:Email(message = "Email must be valid")
    @field:Size(max = 254, message = "Email must not exceed 254 characters")
    val email: String? = null,
    @field:Size(max = 100, message = "City must not exceed 100 characters")
    val city: String? = null,
    @field:Size(max = 2_000, message = "Description must not exceed 2000 characters")
    val description: String? = null,
    @field:Size(max = 2_048, message = "Avatar URL must not exceed 2048 characters")
    val avatarUrl: String? = null,
    // Интересы — список id тегов
    @field:Size(max = 50, message = "No more than 50 interests are allowed")
    val interestIds: List<@Positive(message = "Interest IDs must be positive") Long>? = null,
    // Соцсети
    @field:Size(max = 20, message = "No more than 20 social media links are allowed")
    val socialMedias: List<@Valid SocialMediaDto>? = null,
    // Настройки
    val showCommunities: Boolean? = null,
    val showMeetings: Boolean? = null,
    val notificationsEnabled: Boolean? = null
) : Serializable

/** DTO для социальных сетей */
data class SocialMediaDto(
    @field:NotBlank(message = "Social media type is required")
    @field:Size(max = 30, message = "Social media type must not exceed 30 characters")
    val type: String,    // "telegram" или "habr"
    @field:NotBlank(message = "Social media URL is required")
    @field:Size(max = 2_048, message = "Social media URL must not exceed 2048 characters")
    val url: String      // username/handle
) : Serializable

/** DTO для краткой информации о пользователе */
data class UserDto(
    val id: Long,
    val name: String,
    val surname: String,
    val avatarUrl: String?
) : Serializable

/**
 * DTO для информации о пользователе в списках участников/подписчиков
 * Экран People — показывает аватарку, имя и специализацию (первый тег интересов)
 */
data class UserInfoDto(
    val id: Long,
    val name: String,
    val surname: String,
    val avatarUrl: String,
    val bio: String,
    val role: String
) : Serializable

/** DTO для запроса обновления FCM токена */
data class UpdateFcmTokenDto(
    @field:NotBlank(message = "FCM token is required")
    @field:Size(max = 4096, message = "FCM token is too long")
    val fcmToken: String
) : Serializable
