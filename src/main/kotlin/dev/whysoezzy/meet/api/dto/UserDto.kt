package dev.whysoezzy.meet.api.dto

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
    val name: String? = null,
    val surname: String? = null,
    val email: String? = null,
    val city: String? = null,
    val description: String? = null,
    val avatarUrl: String? = null,
    // Интересы — список id тегов
    val interestIds: List<Long>? = null,
    // Соцсети
    val socialMedias: List<SocialMediaDto>? = null,
    // Настройки
    val showCommunities: Boolean? = null,
    val showMeetings: Boolean? = null,
    val notificationsEnabled: Boolean? = null
) : Serializable

/** DTO для социальных сетей */
data class SocialMediaDto(
    val type: String,    // "telegram" или "habr"
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
    val fcmToken: String
) : Serializable
