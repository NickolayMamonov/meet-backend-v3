package dev.whysoezzy.meet.api.dto

import java.io.Serializable

/**
 * Meeting DTO - совместимо с Android моделью
 */
data class MeetingDto(
    val id: Long,
    val imageUrl: String,
    val title: String,
    val description: String,
    val time: Long,
    val date: String,
    val address: MeetingAddressDto,
    val capacity: Int,
    val tags: List<MeetingTagDto>,
    val personHost: PersonHostDto?,
    val communityHost: CommunityHostDto?,
    val participants: List<PersonDto>,
    val meetingStatus: String,
    val isUserInParticipants: Boolean
) : Serializable

data class MeetingAddressDto(
    val address: String,
    val latitude: Double,
    val longitude: Double
) : Serializable

data class MeetingTagDto(
    val id: Long,
    val text: String
) : Serializable

data class PersonHostDto(
    val id: Long,
    val name: String,
    val surname: String,
    val description: String,
    val imageUrl: String
) : Serializable

data class CommunityHostDto(
    val id: Long,
    val title: String,
    val description: String,
    val imageUrl: String,
    val meetingsInfo: List<MeetingInfoDto>
) : Serializable

data class MeetingInfoDto(
    val id: Long,
    val title: String,
    val imageUrl: String,
    val date: String
) : Serializable

data class PersonDto(
    val id: Long,
    val name: String,
    val surname: String,
    val imageUrl: String?
) : Serializable
