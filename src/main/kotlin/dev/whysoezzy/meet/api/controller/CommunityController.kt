package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.CommunityDto
import dev.whysoezzy.meet.api.dto.MeetingDto
import dev.whysoezzy.meet.api.dto.UserInfoDto
import dev.whysoezzy.meet.service.CommunityService
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.tags.Tag
import mu.KotlinLogging
import org.springframework.web.bind.annotation.*

private val logger = KotlinLogging.logger {}

@RestController
@Tag(name = "Communities", description = "Community management - Android compatible")
class CommunityController(
    private val communityService: CommunityService
) {

    @GetMapping("/communities/recommended")
    @Operation(summary = "Get recommended communities")
    fun getRecommendedCommunities(): List<CommunityDto> {
        logger.info { "GET /communities/recommended" }
        return communityService.getRecommendedCommunities()
    }

    @GetMapping("/communities/{id}")
    @Operation(summary = "Get community by ID")
    fun getCommunityById(@PathVariable id: Long): CommunityDto {
        logger.info { "GET /communities/$id" }
        return communityService.getCommunityById(id)
    }

    @PostMapping("/communities/{id}/subscribe")
    @Operation(summary = "Subscribe to community")
    fun subscribeToCommunity(@PathVariable id: Long) {
        logger.info { "POST /communities/$id/subscribe" }
        communityService.subscribeToCommunity(id)
    }

    @DeleteMapping("/communities/{id}/subscribe")
    @Operation(summary = "Unsubscribe from community")
    fun unsubscribeFromCommunity(@PathVariable id: Long) {
        logger.info { "DELETE /communities/$id/subscribe" }
        communityService.unsubscribeFromCommunity(id)
    }

    @GetMapping("/communities/search")
    @Operation(summary = "Search communities")
    fun searchCommunities(@RequestParam query: String): List<CommunityDto> {
        logger.info { "GET /communities/search - query: $query" }
        return communityService.searchCommunities(query)
    }

    @GetMapping("/communities/{id}/meetings")
    @Operation(summary = "Get community meetings")
    fun getCommunityMeetings(@PathVariable id: Long): List<MeetingDto> {
        logger.info { "GET /communities/$id/meetings" }
        return communityService.getCommunityMeetings(id)
    }

    @GetMapping("/communities/{id}/subscribers")
    @Operation(summary = "Get community subscribers")
    fun getCommunitySubscribers(@PathVariable id: Long): List<UserInfoDto> {
        logger.info { "GET /communities/$id/subscribers" }
        return communityService.getCommunitySubscribers(id)
    }
}


