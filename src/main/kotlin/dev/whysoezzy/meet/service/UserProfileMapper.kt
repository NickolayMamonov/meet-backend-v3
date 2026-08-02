package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.SocialMediaDto
import dev.whysoezzy.meet.api.dto.TagDto
import dev.whysoezzy.meet.api.dto.UserProfileDto
import dev.whysoezzy.meet.domain.entity.User
import org.springframework.stereotype.Component

@Component
class UserProfileMapper {
    fun toAuthProfileDto(user: User): UserProfileDto =
        UserProfileDto(
            id = requireNotNull(user.id),
            name = user.name,
            surname = user.surname,
            email = user.email,
            phone = user.phone,
            city = user.city,
            description = user.bio,
            avatarUrl = user.avatarUrl,
            socialMedias = user.socialMedia.map(::toSocialMediaDto),
        )

    fun toFullProfileDto(user: User): UserProfileDto =
        UserProfileDto(
            id = requireNotNull(user.id),
            name = user.name,
            surname = user.surname,
            email = user.email,
            phone = user.phone,
            city = user.city,
            description = user.bio,
            avatarUrl = user.avatarUrl,
            interests = user.interests.map { TagDto(requireNotNull(it.id), it.text) },
            socialMedias = user.socialMedia.map(::toSocialMediaDto),
            showCommunities = user.showCommunities,
            showMeetings = user.showMeetings,
            notificationsEnabled = user.notificationsEnabled,
        )

    private fun toSocialMediaDto(media: dev.whysoezzy.meet.domain.entity.UserSocialMedia) =
        SocialMediaDto(media.platform.name.lowercase(), media.username)
}
