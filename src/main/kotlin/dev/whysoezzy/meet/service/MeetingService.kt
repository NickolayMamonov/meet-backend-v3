package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.error.ConflictException
import dev.whysoezzy.meet.api.error.NotFoundException
import dev.whysoezzy.meet.api.dto.*
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.MeetingCapacityExceededException
import dev.whysoezzy.meet.domain.entity.MeetingStatus
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import mu.KotlinLogging
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

private val logger = KotlinLogging.logger {}

@Service
class MeetingService(
    private val meetingRepository: MeetingRepository,
    private val userRepository: UserRepository,
) {

    @Transactional(readOnly = true)
    fun getMainMeetings(currentUserId: Long?): List<MeetingDto> {
        logger.info { "Fetching main meetings" }

        val currentTime = System.currentTimeMillis()
        val upcoming = meetingRepository.findUpcomingMeetings(MeetingStatus.ACTIVE, currentTime)
        val popular = meetingRepository.findPopularMeetings(MeetingStatus.ACTIVE)

        return (upcoming.take(1) + popular.take(10) + upcoming.drop(1).take(10))
            .distinctBy { it.id }
            .map { it.toDto(currentUserId) }
    }

    @Transactional(readOnly = true)
    fun getPopularMeetings(currentUserId: Long?): List<MeetingDto> {
        logger.info { "Fetching popular meetings" }

        return meetingRepository.findPopularMeetings(MeetingStatus.ACTIVE)
            .take(20)
            .map { it.toDto(currentUserId) }
    }

    @Transactional(readOnly = true)
    fun getAllMeetings(page: Int, limit: Int, tagId: Long?, currentUserId: Long?): List<MeetingDto> {
        logger.info { "Fetching all meetings - page: $page, limit: $limit, tagId: $tagId" }

        val meetings = if (tagId != null) {
            meetingRepository.findByTagId(tagId, MeetingStatus.ACTIVE)
        } else {
            meetingRepository.findAllByStatus(MeetingStatus.ACTIVE)
        }

        return meetings
            .drop(page * limit)
            .take(limit)
            .map { it.toDto(currentUserId) }
    }

    @Transactional(readOnly = true)
    fun searchMeetings(query: String, currentUserId: Long?): List<MeetingDto> {
        logger.info { "Searching meetings" }
        return meetingRepository.searchMeetings(query, MeetingStatus.ACTIVE)
            .map { it.toDto(currentUserId) }
    }

    @Transactional(readOnly = true)
    fun getMeetingById(id: Long, currentUserId: Long?): MeetingDto {
        logger.info { "Fetching meeting: $id" }
        val meeting = meetingRepository.findById(id)
            .orElseThrow { NotFoundException("Meeting not found") }
        return meeting.toDto(currentUserId)
    }

    @Transactional
    fun joinMeeting(meetingId: Long, userId: Long) {
        logger.info { "User $userId joining meeting: $meetingId" }

        val meeting = meetingRepository.findById(meetingId)
            .orElseThrow { NotFoundException("Meeting not found") }
        val user = userRepository.findById(userId)
            .orElseThrow { NotFoundException("User not found") }

        if (!meeting.isActive()) throw ConflictException("Meeting is not active")
        if (meetingRepository.isUserParticipant(meetingId, userId))
            throw ConflictException("User already joined this meeting")

        try {
            meeting.addParticipant(user)
        } catch (_: MeetingCapacityExceededException) {
            throw ConflictException("Meeting is at full capacity")
        }
        meetingRepository.save(meeting)
    }

    @Transactional
    fun leaveMeeting(meetingId: Long, userId: Long) {
        logger.info { "User $userId leaving meeting: $meetingId" }

        val meeting = meetingRepository.findById(meetingId)
            .orElseThrow { NotFoundException("Meeting not found") }
        val user = userRepository.findById(userId)
            .orElseThrow { NotFoundException("User not found") }

        if (!meetingRepository.isUserParticipant(meetingId, userId))
            throw ConflictException("User is not a participant")

        meeting.removeParticipant(user)
        meetingRepository.save(meeting)
    }

    @Transactional(readOnly = true)
    fun getUserMeetings(userId: Long): List<MeetingDto> {
        logger.info { "Fetching meetings for user: $userId" }
        return meetingRepository.findByParticipantId(userId)
            .map { it.toDto(userId) }
    }

    @Transactional(readOnly = true)
    fun getMeetingParticipants(meetingId: Long): List<UserInfoDto> {
        logger.info { "Fetching participants for meeting: $meetingId" }
        val meeting = meetingRepository.findById(meetingId)
            .orElseThrow { NotFoundException("Meeting not found") }

        return meeting.participants.map { user ->
            UserInfoDto(
                id = user.id!!,
                name = user.name,
                surname = user.surname,
                avatarUrl = user.avatarUrl ?: "",
                bio = user.bio,
                // Берём первый тег интересов как специализацию (экран People)
                role = user.interests.firstOrNull()?.text ?: user.bio.take(30)
            )
        }
    }

    // ==================== Маппинг ====================

    private fun Meeting.toDto(currentUserId: Long?): MeetingDto {
        return MeetingDto(
            id = id!!,
            imageUrl = imageUrl,
            title = title,
            description = description,
            time = time,
            date = date,
            address = MeetingAddressDto(address, latitude, longitude),
            capacity = capacity,
            tags = tags.map { MeetingTagDto(it.id!!, it.text) },
            personHost = personHost?.let {
                PersonHostDto(
                    id = it.id!!,
                    name = it.name,
                    surname = it.surname,
                    description = it.bio,
                    imageUrl = it.avatarUrl ?: ""
                )
            },
            communityHost = communityHost?.let { community ->
                CommunityHostDto(
                    id = community.id!!,
                    title = community.name,
                    description = community.description,
                    imageUrl = community.imageUrl,
                    meetingsInfo = community.getActiveMeetings().take(5).map { m ->
                        MeetingInfoDto(m.id!!, m.title, m.imageUrl, m.date)
                    }
                )
            },
            participants = participants.map {
                PersonDto(it.id!!, it.name, it.surname, it.avatarUrl ?: "")
            },
            meetingStatus = status.name,
            isUserInParticipants = currentUserId?.let { uid ->
                participants.any { it.id == uid }
            } ?: false,
            source = source.name,
            externalUrl = externalUrl,
            isOnline = isOnline,
        )
    }
}
