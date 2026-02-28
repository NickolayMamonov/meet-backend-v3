package dev.whysoezzy.meet.api.dto

import java.io.Serializable

/**
 * Community DTO - совместимо с Android моделью
 */
data class CommunityDto(
    val id: Long,
    val name: String,
    val description: String,
    val imageUrl: String,
    val subscribersCount: Int,
    val isSubscribed: Boolean,
    val tags: List<TagDto>
) : Serializable

data class CommunityInfoDto(
    val id: Long,
    val name: String,
    val description: String,
    val imageUrl: String,
    val subscribersCount: Int
) : Serializable
