package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.*
import dev.whysoezzy.meet.api.error.BadRequestException
import dev.whysoezzy.meet.api.error.NotFoundException
import dev.whysoezzy.meet.domain.entity.SocialMediaType
import dev.whysoezzy.meet.domain.entity.UserSocialMedia
import dev.whysoezzy.meet.domain.repository.CommunityRepository
import dev.whysoezzy.meet.domain.repository.TagRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import mu.KotlinLogging
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime

private val logger = KotlinLogging.logger {}

@Service
class UserService(
    private val userRepository: UserRepository,
    private val tagRepository: TagRepository
) {

    @Transactional(readOnly = true)
    fun getCurrentUserProfile(userId: Long): UserProfileDto {
        logger.info { "Fetching current user profile: $userId" }
        return getUserProfile(userId)
    }

    @Transactional(readOnly = true)
    fun getUserProfile(userId: Long): UserProfileDto {
        logger.info { "Fetching user profile: $userId" }

        val user = userRepository.findById(userId)
            .orElseThrow { NotFoundException("User not found") }

        if (user.isDeleted) throw NotFoundException("User not found")

        return user.toProfileDto()
    }

    @Transactional
    fun updateProfile(userId: Long, updateDto: UpdateUserDto): UserProfileDto {
        logger.info { "Updating user profile: $userId" }

        val user = userRepository.findById(userId)
            .orElseThrow { NotFoundException("User not found") }

        // Базовые поля
        updateDto.name?.let { user.name = it }
        updateDto.surname?.let { user.surname = it }
        updateDto.email?.let { user.email = it }
        updateDto.city?.let { user.city = it }
        updateDto.description?.let { user.bio = it }
        updateDto.avatarUrl?.let { user.avatarUrl = it }

        // Настройки
        updateDto.showCommunities?.let { user.showCommunities = it }
        updateDto.showMeetings?.let { user.showMeetings = it }
        updateDto.notificationsEnabled?.let { user.notificationsEnabled = it }

        // Интересы — перезаписываем весь список
        updateDto.interestIds?.let { ids ->
            val tags = tagRepository.findAllById(ids).toMutableSet()
            user.interests.clear()
            user.interests.addAll(tags)
        }

        // Соцсети — перезаписываем полностью
        updateDto.socialMedias?.let { dtos ->
            user.socialMedia.clear()
            dtos.forEach { dto ->
                val platform = runCatching {
                    SocialMediaType.valueOf(dto.type.uppercase())
                }.getOrElse {
                    throw BadRequestException("Unknown social media type")
                }
                user.socialMedia.add(
                    UserSocialMedia(user = user, platform = platform, username = dto.url)
                )
            }
        }

        val saved = userRepository.save(user)
        logger.info { "User profile updated: $userId" }

        return saved.toProfileDto()
    }

    @Transactional
    fun updateFcmToken(userId: Long, fcmToken: String) {
        logger.info { "Updating FCM token for user: $userId" }
        val user = userRepository.findById(userId)
            .orElseThrow { NotFoundException("User not found") }
        user.fcmToken = fcmToken
        userRepository.save(user)
    }

    @Transactional
    fun deleteAccount(userId: Long) {
        logger.info { "Soft deleting account: $userId" }
        val user = userRepository.findById(userId)
            .orElseThrow { NotFoundException("User not found") }
        user.deletedAt = LocalDateTime.now()
        userRepository.save(user)
    }

    @Transactional(readOnly = true)
    fun getUserMeetings(userId: Long): List<MeetingInfoDto> {
        logger.info { "Fetching meetings for user: $userId" }

        val user = userRepository.findById(userId)
            .orElseThrow { NotFoundException("User not found") }

        return user.participatingMeetings.map { meeting ->
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
            .orElseThrow { NotFoundException("User not found") }

        return user.subscribedCommunities.map { community ->
            CommunityInfoDto(
                id = community.id!!,
                name = community.name,
                description = community.description,
                imageUrl = community.imageUrl,
                subscribersCount = community.subscribers.size
            )
        }
    }
}

// Extension function для маппинга User -> UserProfileDto
fun dev.whysoezzy.meet.domain.entity.User.toProfileDto() = UserProfileDto(
    id = id!!,
    name = name,
    surname = surname,
    email = email,
    phone = phone,
    city = city,
    description = bio,
    avatarUrl = avatarUrl,
    interests = interests.map { TagDto(it.id!!, it.text) },
    socialMedias = socialMedia.map { SocialMediaDto(it.platform.name.lowercase(), it.username) },
    showCommunities = showCommunities,
    showMeetings = showMeetings,
    notificationsEnabled = notificationsEnabled
)
