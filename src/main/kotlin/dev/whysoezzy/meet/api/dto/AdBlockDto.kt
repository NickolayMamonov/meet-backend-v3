package dev.whysoezzy.meet.api.dto

import dev.whysoezzy.meet.domain.entity.AdBlock
import dev.whysoezzy.meet.domain.entity.AdBlockType
import java.io.Serializable

data class AdBlockResponseDto(
    val type: String,
    val id: Long,
    val isActive: Boolean,
    val title: String,
    val description: String,

    val communities: List<CommunityInfoDto>? = null,

    val actionText: String? = null,
    val actionUrl: String? = null,

    val users: List<UserInfoDto>? = null
) : Serializable



// Mapper extension
fun AdBlock.toDto(): AdBlockResponseDto {
    return when (type) {
        AdBlockType.COMMUNITIES -> AdBlockResponseDto(
            type = "COMMUNITIES",
            id = this.id ?: throw IllegalStateException("AdBlock id is null"),
            isActive = isActive,
            title = title ?: "",
            description = description ?: "",
            communities = communities.map { comm ->
                CommunityInfoDto(
                    id = comm.id ?: throw IllegalStateException("Community id is null"),
                    name = comm.name,
                    description = comm.description,
                    imageUrl = comm.imageUrl,
                    subscribersCount = comm.subscribers.size
                )
            }
        )

        AdBlockType.TEXT -> AdBlockResponseDto(
            type = "TEXT",
            id = this.id ?: throw IllegalStateException("AdBlock id is null"),
            isActive = isActive,
            title = title ?: "",
            description = description ?: "",
            actionText = actionText,
            actionUrl = actionUrl
        )

        AdBlockType.PEOPLE -> AdBlockResponseDto(
            type = "PEOPLE",
            id = this.id ?: throw IllegalStateException("AdBlock id is null"),
            isActive = isActive,
            title = title ?: "",
            description = description ?: "",
            users = users.map { user ->
                UserInfoDto(
                    id = user.id ?: throw IllegalStateException("User id is null"),
                    name = user.name,
                    surname = user.surname,
                    avatarUrl = user.avatarUrl ?: "",
                    bio = user.bio,
                    role = user.role ?: "Не указано"
                )
            }
        )
    }
}

fun List<AdBlock>.toDtoList(): List<AdBlockResponseDto> = map { it.toDto() }


