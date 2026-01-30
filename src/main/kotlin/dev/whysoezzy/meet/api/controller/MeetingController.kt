package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.MeetingDto
import dev.whysoezzy.meet.service.MeetingService
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.tags.Tag
import mu.KotlinLogging
import org.springframework.web.bind.annotation.*

private val logger = KotlinLogging.logger {}

@RestController
@Tag(name = "Meetings", description = "Meeting management - Android compatible")
class MeetingController(
    private val meetingService: MeetingService
) {
    
    @GetMapping("/meetings/main")
    @Operation(summary = "Get main meetings for home screen")
    fun getMainMeetings(): List<MeetingDto> {
        logger.info { "GET /meetings/main" }
        return meetingService.getMainMeetings()
    }
    
    @GetMapping("/meetings/popular")
    @Operation(summary = "Get popular meetings")
    fun getPopularMeetings(): List<MeetingDto> {
        logger.info { "GET /meetings/popular" }
        return meetingService.getPopularMeetings()
    }
    
    @GetMapping("/meetings")
    @Operation(summary = "Get all meetings")
    fun getAllMeetings(
        @RequestParam(defaultValue = "0") page: Int,
        @RequestParam(defaultValue = "20") limit: Int
    ): List<MeetingDto> {
        logger.info { "GET /meetings - page: $page, limit: $limit" }
        return meetingService.getAllMeetings(page, limit)
    }
    
    @GetMapping("/meetings/search")
    @Operation(summary = "Search meetings")
    fun searchMeetings(@RequestParam query: String): List<MeetingDto> {
        logger.info { "GET /meetings/search - query: $query" }
        return meetingService.searchMeetings(query)
    }
    
    @GetMapping("/meetings/{id}")
    @Operation(summary = "Get meeting by ID")
    fun getMeetingById(@PathVariable id: Long): MeetingDto {
        logger.info { "GET /meetings/$id" }
        return meetingService.getMeetingById(id)
    }
    
    @PostMapping("/meetings/{id}/join")
    @Operation(summary = "Join meeting")
    fun joinMeeting(@PathVariable id: Long) {
        logger.info { "POST /meetings/$id/join" }
        meetingService.joinMeeting(id)
    }
    
    @DeleteMapping("/meetings/{id}/leave")
    @Operation(summary = "Leave meeting")
    fun leaveMeeting(@PathVariable id: Long) {
        logger.info { "DELETE /meetings/$id/leave" }
        meetingService.leaveMeeting(id)
    }
    
    @GetMapping("/user/meetings")
    @Operation(summary = "Get user's meetings")
    fun getUserMeetings(): List<MeetingDto> {
        logger.info { "GET /user/meetings" }
        return meetingService.getUserMeetings()
    }
}
