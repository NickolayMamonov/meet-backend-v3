package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.*
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.CommunityRepository
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import mu.KotlinLogging
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

private val logger = KotlinLogging.logger {}


@Service
class UserService(
    private val userRepository: UserRepository
) {

    @Transactional(readOnly = true)
    fun getCurrentUserProfile(): UserProfileDto {
        val userId = MOCK_USER_ID
        logger.info { "Fetching current user profile: $userId" }
        return getUserProfile(userId)
    }

    @Transactional(readOnly = true)
    fun getUserProfile(userId: Long): UserProfileDto {
        logger.info { "Fetching user profile: $userId" }

        val user = userRepository.findById(userId)
            .orElseThrow { NoSuchElementException("User not found with id: $userId") }

        return UserProfileDto(
            id = user.id!!,
            name = user.name,
            surname = user.surname,
            email = user.email,
            phone = user.phone,
            city = user.city,
            description = user.bio,
            avatarUrl = user.avatarUrl,
            socialMedias = user.socialMedia.map { social ->
                SocialMediaDto(
                    type = social.platform.name.lowercase(),
                    url = social.username
                )
            }
        )
    }

    @Transactional
    fun updateProfile(updateDto: UpdateUserDto): UserProfileDto {
        val userId = MOCK_USER_ID
        logger.info { "Updating user profile: $userId" }

        val user = userRepository.findById(userId)
            .orElseThrow { NoSuchElementException("User not found with id: $userId") }

        // Обновляем только переданные поля
        updateDto.name?.let { user.name = it }
        updateDto.surname?.let { user.surname = it }
        updateDto.email?.let { user.email = it }
        updateDto.city?.let { user.city = it }
        updateDto.description?.let { user.bio = it }
        updateDto.avatarUrl?.let { user.avatarUrl = it }

        val updatedUser = userRepository.save(user)

        logger.info { "User profile updated successfully: $userId" }

        return UserProfileDto(
            id = updatedUser.id!!,
            name = updatedUser.name,
            surname = updatedUser.surname,
            email = updatedUser.email,
            phone = updatedUser.phone,
            city = updatedUser.city,
            description = updatedUser.bio,
            avatarUrl = updatedUser.avatarUrl,
            socialMedias = updatedUser.socialMedia.map { social ->
                SocialMediaDto(
                    type = social.platform.name.lowercase(),
                    url = social.username
                )
            }
        )
    }

    @Transactional(readOnly = true)
    fun getUserMeetings(userId: Long): List<MeetingInfoDto> {
        logger.info { "Fetching meetings for user: $userId" }

        val user = userRepository.findById(userId)
            .orElseThrow { NoSuchElementException("User not found with id: $userId") }

        val meetings = user.participatingMeetings

        return meetings.map { meeting ->
            MeetingInfoDto(
                id = meeting.id!!,
                title = meeting.title,
                imageUrl = meeting.imageUrl,
                date = meeting.date
            )
        }
    }

    @Transactional(readOnly = true)
    fun getUserCommunities(userId: Long): List<CommunityInfoDto> {
        logger.info { "Fetching communities for user: $userId" }

        val user = userRepository.findById(userId)
            .orElseThrow { NoSuchElementException("User not found with id: $userId") }

        val communities = user.subscribedCommunities

        return communities.map { community ->
            CommunityInfoDto(
                id = community.id!!,
                name = community.name,
                description = community.description,
                imageUrl = community.imageUrl,
                subscribersCount = community.subscribers.size
            )
        }
    }

    companion object {
        private const val MOCK_USER_ID = 1L
    }
}