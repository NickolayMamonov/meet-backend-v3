package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.*
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.MeetingStatus
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import mu.KotlinLogging
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

private val logger = KotlinLogging.logger {}

@Service
class MeetingService(
    private val meetingRepository: MeetingRepository,
    private val userRepository: UserRepository
) {
    
    // Mock user ID для разработки без авторизации
    private val MOCK_USER_ID = 1L
    
    @Transactional(readOnly = true)
    fun getMainMeetings(): List<MeetingDto> {
        logger.info { "Fetching main meetings" }
        
        val currentTime = System.currentTimeMillis()
        
        // Получаем ближайшую встречу, популярные и предстоящие
        val upcoming = meetingRepository.findUpcomingMeetings(MeetingStatus.ACTIVE, currentTime)
        val popular = meetingRepository.findPopularMeetings(MeetingStatus.ACTIVE)
        
        // Объединяем списки и убираем дубликаты
        return (upcoming.take(1) + popular.take(10) + upcoming.drop(1).take(10))
            .distinctBy { it.id }
            .map { it.toDto(MOCK_USER_ID) }
    }
    
    @Transactional(readOnly = true)
    fun getPopularMeetings(): List<MeetingDto> {
        logger.info { "Fetching popular meetings" }
        
        return meetingRepository.findPopularMeetings(MeetingStatus.ACTIVE)
            .take(20)
            .map { it.toDto(MOCK_USER_ID) }
    }
    
    @Transactional(readOnly = true)
    fun getAllMeetings(page: Int, limit: Int): List<MeetingDto> {
        logger.info { "Fetching all meetings - page: $page, limit: $limit" }
        
        return meetingRepository.findAllByStatus(MeetingStatus.ACTIVE)
            .drop(page * limit)
            .take(limit)
            .map { it.toDto(MOCK_USER_ID) }
    }
    
    @Transactional(readOnly = true)
    fun searchMeetings(query: String): List<MeetingDto> {
        logger.info { "Searching meetings: $query" }
        
        return meetingRepository.searchMeetings(query, MeetingStatus.ACTIVE)
            .map { it.toDto(MOCK_USER_ID) }
    }
    
    @Transactional(readOnly = true)
    fun getMeetingById(id: Long): MeetingDto {
        logger.info { "Fetching meeting by id: $id" }
        
        val meeting = meetingRepository.findById(id).orElseThrow {
            IllegalArgumentException("Meeting not found with id: $id")
        }
        
        return meeting.toDto(MOCK_USER_ID)
    }
    
    @Transactional
    fun joinMeeting(meetingId: Long) {
        val userId = MOCK_USER_ID
        logger.info { "User $userId joining meeting: $meetingId" }
        
        val meeting = meetingRepository.findById(meetingId).orElseThrow {
            IllegalArgumentException("Meeting not found")
        }
        
        val user = userRepository.findById(userId).orElseThrow {
            IllegalArgumentException("User not found")
        }
        
        if (!meeting.isActive()) {
            throw IllegalStateException("Meeting is not active")
        }
        
        if (meetingRepository.isUserParticipant(meetingId, userId)) {
            throw IllegalStateException("User already joined this meeting")
        }
        
        meeting.addParticipant(user)
        meetingRepository.save(meeting)
    }
    
    @Transactional
    fun leaveMeeting(meetingId: Long) {
        val userId = MOCK_USER_ID
        logger.info { "User $userId leaving meeting: $meetingId" }
        
        val meeting = meetingRepository.findById(meetingId).orElseThrow {
            IllegalArgumentException("Meeting not found")
        }
        
        val user = userRepository.findById(userId).orElseThrow {
            IllegalArgumentException("User not found")
        }
        
        if (!meetingRepository.isUserParticipant(meetingId, userId)) {
            throw IllegalStateException("User is not a participant")
        }
        
        meeting.removeParticipant(user)
        meetingRepository.save(meeting)
    }
    
    @Transactional(readOnly = true)
    fun getUserMeetings(): List<MeetingDto> {
        val userId = MOCK_USER_ID
        logger.info { "Fetching meetings for user: $userId" }
        
        return meetingRepository.findByParticipantId(userId)
            .map { it.toDto(userId) }
    }
    
    // Extension function для маппинга
    private fun Meeting.toDto(currentUserId: Long): MeetingDto {
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
                PersonDto(it.id!!, it.name, it.surname, it.avatarUrl)
            },
            meetingStatus = status.name,
            isUserInParticipants = participants.any { it.id == currentUserId }
        )
    }
}
