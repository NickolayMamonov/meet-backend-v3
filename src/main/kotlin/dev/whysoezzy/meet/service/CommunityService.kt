package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.*
import dev.whysoezzy.meet.domain.entity.Community
import dev.whysoezzy.meet.domain.repository.CommunityRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import mu.KotlinLogging
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

private val logger = KotlinLogging.logger {}

@Service
class CommunityService(
    private val communityRepository: CommunityRepository,
    private val userRepository: UserRepository
) {

    @Transactional(readOnly = true)
    fun getRecommendedCommunities(): List<CommunityDto> {
        logger.info { "Fetching recommended communities" }

        return communityRepository.findAll()
            .take(20)
            .map { it.toDto(MOCK_USER_ID) }
    }

    @Transactional(readOnly = true)
    fun getCommunityById(id: Long): CommunityDto {
        logger.info { "Fetching community by id: $id" }

        val community = communityRepository.findById(id).orElseThrow {
            IllegalArgumentException("Community not found")
        }

        return community.toDto(MOCK_USER_ID)
    }

    @Transactional
    fun subscribeToCommunity(communityId: Long) {
        val userId = MOCK_USER_ID
        logger.info { "User $userId subscribing to community: $communityId" }

        val community = communityRepository.findById(communityId).orElseThrow {
            IllegalArgumentException("Community not found")
        }

        val user = userRepository.findById(userId).orElseThrow {
            IllegalArgumentException("User not found")
        }

        if (communityRepository.isUserSubscribed(communityId, userId)) {
            throw IllegalStateException("Already subscribed")
        }

        community.subscribers.add(user)
        communityRepository.save(community)
    }

    @Transactional
    fun unsubscribeFromCommunity(communityId: Long) {
        val userId = MOCK_USER_ID
        logger.info { "User $userId unsubscribing from community: $communityId" }

        val community = communityRepository.findById(communityId).orElseThrow {
            IllegalArgumentException("Community not found")
        }

        val user = userRepository.findById(userId).orElseThrow {
            IllegalArgumentException("User not found")
        }

        if (!communityRepository.isUserSubscribed(communityId, userId)) {
            throw IllegalStateException("Not subscribed")
        }

        community.subscribers.remove(user)
        communityRepository.save(community)
    }

    @Transactional(readOnly = true)
    fun searchCommunities(query: String): List<CommunityDto> {
        logger.info { "Searching communities: $query" }

        return communityRepository.searchCommunities(query)
            .map { it.toDto(MOCK_USER_ID) }
    }

    @Transactional(readOnly = true)
    fun getCommunityMeetings(communityId: Long): List<MeetingDto> {
        logger.info { "Fetching meetings for community: $communityId" }

        val community = communityRepository.findById(communityId).orElseThrow {
            IllegalArgumentException("Community not found")
        }

        return community.getActiveMeetings().map { meeting ->
            MeetingDto(
                id = meeting.id!!,
                imageUrl = meeting.imageUrl,
                title = meeting.title,
                description = meeting.description,
                time = meeting.time,
                date = meeting.date,
                address = MeetingAddressDto(meeting.address, meeting.latitude, meeting.longitude),
                capacity = meeting.capacity,
                tags = meeting.tags.map { MeetingTagDto(it.id!!, it.text) },
                personHost = meeting.personHost?.let {
                    PersonHostDto(
                        id = it.id!!,
                        name = it.name,
                        surname = it.surname,
                        description = it.bio,
                        imageUrl = it.avatarUrl ?: ""
                    )
                },
                communityHost = CommunityHostDto(
                    id = community.id!!,
                    title = community.name,
                    description = community.description,
                    imageUrl = community.imageUrl,
                    meetingsInfo = emptyList()
                ),
                participants = meeting.participants.map {
                    PersonDto(
                        id = it.id!!,
                        name = it.name,
                        surname = it.surname,
                        imageUrl = it.avatarUrl ?: ""
                    )
                },
                meetingStatus = meeting.status.name,
                isUserInParticipants = meeting.participants.any { it.id == MOCK_USER_ID }
            )
        }
    }

    @Transactional(readOnly = true)
    fun getCommunitySubscribers(communityId: Long): List<UserInfoDto> {
        logger.info { "Fetching subscribers for community: $communityId" }

        val community = communityRepository.findById(communityId).orElseThrow {
            IllegalArgumentException("Community not found")
        }

        return community.subscribers.map { user ->
            UserInfoDto(
                id = user.id!!,
                name = user.name,
                surname = user.surname,
                avatarUrl = user.avatarUrl ?: "",
                bio = user.bio,
                role = user.bio // используем bio как role для совместимости
            )
        }
    }

    private fun Community.toDto(currentUserId: Long): CommunityDto {
        return CommunityDto(
            id = id!!,
            name = name,
            description = description,
            imageUrl = imageUrl,
            subscribersCount = subscribersCount,
            isSubscribed = communityRepository.isUserSubscribed(id!!, currentUserId),
            tags = tags.map { TagDto(it.id!!, it.text) }
        )
    }
    companion object {
        private const val MOCK_USER_ID = 1L
    }
}

