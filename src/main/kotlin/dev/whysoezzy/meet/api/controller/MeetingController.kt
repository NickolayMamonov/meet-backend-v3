package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.MeetingDto
import dev.whysoezzy.meet.api.dto.UserInfoDto
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.service.MeetingService
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import jakarta.validation.constraints.Max
import jakarta.validation.constraints.NotBlank
import jakarta.validation.constraints.Positive
import jakarta.validation.constraints.PositiveOrZero
import mu.KotlinLogging
import org.springframework.validation.annotation.Validated
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.*

private val logger = KotlinLogging.logger {}

@RestController
@Validated
@Tag(name = "Meetings", description = "Meeting management")
class MeetingController(
    private val meetingService: MeetingService,
    private val authUtils: AuthUtils
) {

    @GetMapping("/meetings/main")
    @Operation(summary = "Get main meetings for home screen")
    fun getMainMeetings(): List<MeetingDto> {
        val userId = authUtils.getCurrentUserIdOrNull()
        logger.info { "GET /meetings/main - user: $userId" }
        return meetingService.getMainMeetings(userId)
    }

    @GetMapping("/meetings/popular")
    @Operation(summary = "Get popular meetings")
    fun getPopularMeetings(): List<MeetingDto> {
        val userId = authUtils.getCurrentUserIdOrNull()
        logger.info { "GET /meetings/popular" }
        return meetingService.getPopularMeetings(userId)
    }

    @GetMapping("/meetings")
    @Operation(summary = "Get all meetings, optionally filtered by tag")
    fun getAllMeetings(
        @RequestParam(defaultValue = "0") @PositiveOrZero(message = "Page must be zero or greater") page: Int,
        @RequestParam(defaultValue = "20") @Positive(message = "Limit must be greater than zero") @Max(100, message = "Limit must not exceed 100") limit: Int,
        @RequestParam(required = false) @Positive(message = "Tag ID must be greater than zero") tagId: Long?   // фильтр по тегу для chips на Main Page
    ): List<MeetingDto> {
        val userId = authUtils.getCurrentUserIdOrNull()
        logger.info { "GET /meetings - page: $page, limit: $limit, tagId: $tagId" }
        return meetingService.getAllMeetings(page, limit, tagId, userId)
    }

    @GetMapping("/meetings/search")
    @Operation(summary = "Search meetings by title/description/address")
    fun searchMeetings(@RequestParam @NotBlank(message = "Query is required") @Max(200, message = "Query must not exceed 200 characters") query: String): List<MeetingDto> {
        val userId = authUtils.getCurrentUserIdOrNull()
        logger.info { "GET /meetings/search - query: $query" }
        return meetingService.searchMeetings(query, userId)
    }

    @GetMapping("/meetings/{id}")
    @Operation(summary = "Get meeting by ID")
    fun getMeetingById(@PathVariable id: Long): MeetingDto {
        val userId = authUtils.getCurrentUserIdOrNull()
        logger.info { "GET /meetings/$id" }
        return meetingService.getMeetingById(id, userId)
    }

    /** Список участников встречи — экран People */
    @GetMapping("/meetings/{id}/participants")
    @Operation(summary = "Get meeting participants (People screen)")
    fun getMeetingParticipants(@PathVariable id: Long): List<UserInfoDto> {
        logger.info { "GET /meetings/$id/participants" }
        return meetingService.getMeetingParticipants(id)
    }

    @PostMapping("/meetings/{id}/join")
    @Operation(summary = "Join meeting", security = [SecurityRequirement(name = "bearerAuth")])
    fun joinMeeting(@PathVariable id: Long): ResponseEntity<Map<String, String>> {
        val userId = authUtils.getCurrentUserId()
        logger.info { "POST /meetings/$id/join - user: $userId" }
        meetingService.joinMeeting(id, userId)
        return ResponseEntity.ok(mapOf("message" to "Successfully joined"))
    }

    @DeleteMapping("/meetings/{id}/leave")
    @Operation(summary = "Leave meeting", security = [SecurityRequirement(name = "bearerAuth")])
    fun leaveMeeting(@PathVariable id: Long): ResponseEntity<Map<String, String>> {
        val userId = authUtils.getCurrentUserId()
        logger.info { "DELETE /meetings/$id/leave - user: $userId" }
        meetingService.leaveMeeting(id, userId)
        return ResponseEntity.ok(mapOf("message" to "Successfully left"))
    }

    @GetMapping("/user/meetings")
    @Operation(summary = "Get current user's meetings", security = [SecurityRequirement(name = "bearerAuth")])
    fun getUserMeetings(): List<MeetingDto> {
        val userId = authUtils.getCurrentUserId()
        logger.info { "GET /user/meetings - user: $userId" }
        return meetingService.getUserMeetings(userId)
    }
}
