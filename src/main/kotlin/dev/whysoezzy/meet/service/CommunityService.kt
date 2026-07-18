package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.error.ConflictException
import dev.whysoezzy.meet.api.error.NotFoundException
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
    fun getRecommendedCommunities(currentUserId: Long?): List<CommunityDto> {
        logger.info { "Fetching recommended communities" }
        return communityRepository.findAll()
            .take(20)
            .map { it.toDto(currentUserId) }
    }

    @Transactional(readOnly = true)
    fun getCommunityById(id: Long, currentUserId: Long?): CommunityDto {
        logger.info { "Fetching community: $id" }
        val community = communityRepository.findById(id)
            .orElseThrow { NotFoundException("Community not found") }
        return community.toDto(currentUserId)
    }

    @Transactional
    fun subscribeToCommunity(communityId: Long, userId: Long) {
        logger.info { "User $userId subscribing to community: $communityId" }

        val community = communityRepository.findById(communityId)
            .orElseThrow { NotFoundException("Community not found") }
        val user = userRepository.findById(userId)
            .orElseThrow { NotFoundException("User not found") }

        if (communityRepository.isUserSubscribed(communityId, userId))
            throw ConflictException("Already subscribed")

        community.subscribers.add(user)
        communityRepository.save(community)
    }

    @Transactional
    fun unsubscribeFromCommunity(communityId: Long, userId: Long) {
        logger.info { "User $userId unsubscribing from community: $communityId" }

        val community = communityRepository.findById(communityId)
            .orElseThrow { NotFoundException("Community not found") }
        val user = userRepository.findById(userId)
            .orElseThrow { NotFoundException("User not found") }

        if (!communityRepository.isUserSubscribed(communityId, userId))
            throw ConflictException("Not subscribed")

        community.subscribers.remove(user)
        communityRepository.save(community)
    }

    @Transactional(readOnly = true)
    fun searchCommunities(query: String, currentUserId: Long?): List<CommunityDto> {
        logger.info { "Searching communities" }
        return communityRepository.searchCommunities(query)
            .map { it.toDto(currentUserId) }
    }

    @Transactional(readOnly = true)
    fun getCommunityMeetings(communityId: Long, currentUserId: Long?): List<MeetingDto> {
        logger.info { "Fetching meetings for community: $communityId" }

        val community = communityRepository.findById(communityId)
            .orElseThrow { NotFoundException("Community not found") }

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
                    PersonDto(it.id!!, it.name, it.surname, it.avatarUrl ?: "")
                },
                meetingStatus = meeting.status.name,
                isUserInParticipants = currentUserId?.let { uid ->
                    meeting.participants.any { it.id == uid }
                } ?: false
            )
        }
    }

    @Transactional(readOnly = true)
    fun getCommunitySubscribers(communityId: Long): List<UserInfoDto> {
        logger.info { "Fetching subscribers for community: $communityId" }

        val community = communityRepository.findById(communityId)
            .orElseThrow { NotFoundException("Community not found") }

        return community.subscribers.map { user ->
            UserInfoDto(
                id = user.id!!,
                name = user.name,
                surname = user.surname,
                avatarUrl = user.avatarUrl ?: "",
                bio = user.bio,
                role = user.interests.firstOrNull()?.text ?: ""
            )
        }
    }

    private fun Community.toDto(currentUserId: Long?): CommunityDto {
        val isSubscribed = currentUserId?.let {
            communityRepository.isUserSubscribed(id!!, it)
        } ?: false

        return CommunityDto(
            id = id!!,
            name = name,
            description = description,
            imageUrl = imageUrl,
            subscribersCount = subscribersCount,
            isSubscribed = isSubscribed,
            tags = tags.map { TagDto(it.id!!, it.text) }
        )
    }
}
