package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.*
import dev.whysoezzy.meet.domain.entity.User
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
    fun getUserById(id: Long): UserDto {
        logger.info { "Fetching user by id: $id" }
        
        val user = userRepository.findById(id).orElseThrow {
            IllegalArgumentException("User not found")
        }
        
        return user.toDto()
    }
    
    private fun User.toDto(): UserDto {
        return UserDto(
            id = id!!,
            name = name,
            surname = surname,
            email = email,
            city = city,
            avatar = avatarUrl,
            phone = phone,
            bio = bio,
            interests = interests.map { MeetingTagDto(it.id!!, it.text) },
            socialMedia = socialMedia.associate { it.platform.name.lowercase() to it.username },
            subscribedCommunities = subscribedCommunities.map {
                CommunityInfoDto(it.id!!, it.name, it.imageUrl)
            },
            participatingMeetings = participatingMeetings.map {
                MeetingInfoDto(it.id!!, it.title, it.imageUrl, it.date)
            }
        )
    }
}
