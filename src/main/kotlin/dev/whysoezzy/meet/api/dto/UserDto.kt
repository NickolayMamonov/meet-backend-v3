package dev.whysoezzy.meet.api.dto

import java.io.Serializable

/**
 * User DTO - совместимо с Android моделью
 */
data class UserDto(
    val id: Long,
    val name: String,
    val surname: String,
    val email: String?,
    val city: String,
    val avatar: String?,
    val phone: String,
    val bio: String,
    val interests: List<MeetingTagDto>,
    val socialMedia: Map<String, String>,
    val subscribedCommunities: List<CommunityInfoDto>,
    val participatingMeetings: List<MeetingInfoDto>
) : Serializable
