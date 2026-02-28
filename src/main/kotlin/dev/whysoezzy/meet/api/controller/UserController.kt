package dev.whysoezzy.meet.api.controller


import dev.whysoezzy.meet.api.dto.CommunityInfoDto
import dev.whysoezzy.meet.api.dto.MeetingInfoDto
import dev.whysoezzy.meet.api.dto.UpdateUserDto
import dev.whysoezzy.meet.api.dto.UserProfileDto
import dev.whysoezzy.meet.service.UserService
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.tags.Tag
import mu.KotlinLogging
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.*

private val logger = KotlinLogging.logger {}

@RestController
@Tag(name = "Users", description = "User profile management - Android compatible")
class UserController(
    private val userService: UserService
) {

    @GetMapping("/profile")
    @Operation(summary = "Get current user profile")
    fun getCurrentUserProfile(): UserProfileDto {
        logger.info { "GET /profile" }
        return userService.getCurrentUserProfile()
    }

    @GetMapping("/users/{id}")
    @Operation(summary = "Get user profile by ID")
    fun getUserProfile(@PathVariable id: Long): UserProfileDto {
        logger.info { "GET /users/$id" }
        return userService.getUserProfile(id)
    }

    @PutMapping("/profile")
    @Operation(summary = "Update current user profile")
    fun updateProfile(@RequestBody updateDto: UpdateUserDto): UserProfileDto {
        logger.info { "PUT /profile" }
        return userService.updateProfile(updateDto)
    }

    @GetMapping("/users/{id}/meetings")
    @Operation(summary = "Get user meetings")
    fun getUserMeetings(@PathVariable id: Long): List<MeetingInfoDto> {
        logger.info { "GET /users/$id/meetings" }
        return userService.getUserMeetings(id)
    }

    @GetMapping("/users/{id}/communities")
    @Operation(summary = "Get user communities")
    fun getUserCommunities(@PathVariable id: Long): List<CommunityInfoDto> {
        logger.info { "GET /users/$id/communities" }
        return userService.getUserCommunities(id)
    }
}


