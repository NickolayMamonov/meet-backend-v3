package dev.whysoezzy.meet.api.dto

import java.io.Serializable

/**
 * DTO для профиля пользователя
 */
data class UserProfileDto(
    val id: Long,
    val name: String,
    val surname: String,
    val email: String?,
    val phone: String?,
    val city: String?,
    val description: String?,
    val avatarUrl: String?,
    val socialMedias: List<SocialMediaDto> = emptyList()
) : Serializable

/**
 * DTO для обновления профиля
 */
data class UpdateUserDto(
    val name: String?,
    val surname: String?,
    val email: String?,
    val city: String?,
    val description: String?,
    val avatarUrl: String?
) : Serializable

/**
 * DTO для социальных сетей
 */
data class SocialMediaDto(
    val type: String,
    val url: String
) : Serializable

/**
 * DTO для простой информации о пользователе (для списков)
 */
data class UserDto(
    val id: Long,
    val name: String,
    val surname: String,
    val avatarUrl: String?
) : Serializable

/**
 * DTO для информации о пользователе с дополнительными полями
 * Используется для списков участников и подписчиков
 */
data class UserInfoDto(
    val id: Long,
    val name: String,
    val surname: String,
    val avatarUrl: String,
    val bio: String,
    val role: String
) : Serializable