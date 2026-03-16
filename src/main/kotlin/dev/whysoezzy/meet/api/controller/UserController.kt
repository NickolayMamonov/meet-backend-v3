package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.*
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.service.UserService
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import mu.KotlinLogging
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.*

private val logger = KotlinLogging.logger {}

@RestController
@Tag(name = "Users", description = "User profile management")
class UserController(
    private val userService: UserService,
    private val authUtils: AuthUtils
) {

    /** Получить свой профиль */
    @GetMapping("/profile")
    @Operation(summary = "Get current user profile", security = [SecurityRequirement(name = "bearerAuth")])
    fun getCurrentUserProfile(): UserProfileDto {
        val userId = authUtils.getCurrentUserId()
        logger.info { "GET /profile - user: $userId" }
        return userService.getCurrentUserProfile(userId)
    }

    /** Получить профиль другого пользователя */
    @GetMapping("/users/{id}")
    @Operation(summary = "Get user profile by ID", security = [SecurityRequirement(name = "bearerAuth")])
    fun getUserProfile(@PathVariable id: Long): UserProfileDto {
        logger.info { "GET /users/$id" }
        return userService.getUserProfile(id)
    }

    /** Обновить свой профиль */
    @PutMapping("/profile")
    @Operation(summary = "Update current user profile", security = [SecurityRequirement(name = "bearerAuth")])
    fun updateProfile(@RequestBody updateDto: UpdateUserDto): UserProfileDto {
        val userId = authUtils.getCurrentUserId()
        logger.info { "PUT /profile - user: $userId" }
        return userService.updateProfile(userId, updateDto)
    }

    /** Обновить FCM токен для push-уведомлений */
    @PutMapping("/profile/fcm-token")
    @Operation(summary = "Update FCM push token", security = [SecurityRequirement(name = "bearerAuth")])
    fun updateFcmToken(@RequestBody request: UpdateFcmTokenDto): ResponseEntity<Map<String, String>> {
        val userId = authUtils.getCurrentUserId()
        logger.info { "PUT /profile/fcm-token - user: $userId" }
        userService.updateFcmToken(userId, request.fcmToken)
        return ResponseEntity.ok(mapOf("message" to "FCM token updated"))
    }

    /** Мягкое удаление аккаунта */
    @DeleteMapping("/profile")
    @Operation(summary = "Delete account (soft delete, 30 days to recover)", security = [SecurityRequirement(name = "bearerAuth")])
    fun deleteAccount(): ResponseEntity<Map<String, String>> {
        val userId = authUtils.getCurrentUserId()
        logger.info { "DELETE /profile - user: $userId" }
        userService.deleteAccount(userId)
        return ResponseEntity.ok(mapOf("message" to "Account scheduled for deletion. You have 30 days to recover."))
    }

    /** Встречи пользователя */
    @GetMapping("/users/{id}/meetings")
    @Operation(summary = "Get user meetings", security = [SecurityRequirement(name = "bearerAuth")])
    fun getUserMeetings(@PathVariable id: Long): List<MeetingInfoDto> {
        logger.info { "GET /users/$id/meetings" }
        return userService.getUserMeetings(id)
    }

    /** Сообщества пользователя */
    @GetMapping("/users/{id}/communities")
    @Operation(summary = "Get user communities", security = [SecurityRequirement(name = "bearerAuth")])
    fun getUserCommunities(@PathVariable id: Long): List<CommunityInfoDto> {
        logger.info { "GET /users/$id/communities" }
        return userService.getUserCommunities(id)
    }
}
