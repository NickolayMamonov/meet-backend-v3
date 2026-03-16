package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.CommunityDto
import dev.whysoezzy.meet.api.dto.MeetingDto
import dev.whysoezzy.meet.api.dto.UserInfoDto
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.service.CommunityService
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import mu.KotlinLogging
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.*

private val logger = KotlinLogging.logger {}

@RestController
@Tag(name = "Communities", description = "Community management")
class CommunityController(
    private val communityService: CommunityService,
    private val authUtils: AuthUtils
) {

    @GetMapping("/communities/recommended")
    @Operation(summary = "Get recommended communities")
    fun getRecommendedCommunities(): List<CommunityDto> {
        val userId = authUtils.getCurrentUserIdOrNull()
        logger.info { "GET /communities/recommended" }
        return communityService.getRecommendedCommunities(userId)
    }

    @GetMapping("/communities/{id}")
    @Operation(summary = "Get community by ID")
    fun getCommunityById(@PathVariable id: Long): CommunityDto {
        val userId = authUtils.getCurrentUserIdOrNull()
        logger.info { "GET /communities/$id" }
        return communityService.getCommunityById(id, userId)
    }

    @PostMapping("/communities/{id}/subscribe")
    @Operation(summary = "Subscribe to community", security = [SecurityRequirement(name = "bearerAuth")])
    fun subscribeToCommunity(@PathVariable id: Long): ResponseEntity<Map<String, String>> {
        val userId = authUtils.getCurrentUserId()
        logger.info { "POST /communities/$id/subscribe - user: $userId" }
        communityService.subscribeToCommunity(id, userId)
        return ResponseEntity.ok(mapOf("message" to "Subscribed successfully"))
    }

    @DeleteMapping("/communities/{id}/subscribe")
    @Operation(summary = "Unsubscribe from community", security = [SecurityRequirement(name = "bearerAuth")])
    fun unsubscribeFromCommunity(@PathVariable id: Long): ResponseEntity<Map<String, String>> {
        val userId = authUtils.getCurrentUserId()
        logger.info { "DELETE /communities/$id/subscribe - user: $userId" }
        communityService.unsubscribeFromCommunity(id, userId)
        return ResponseEntity.ok(mapOf("message" to "Unsubscribed successfully"))
    }

    @GetMapping("/communities/search")
    @Operation(summary = "Search communities")
    fun searchCommunities(@RequestParam query: String): List<CommunityDto> {
        val userId = authUtils.getCurrentUserIdOrNull()
        logger.info { "GET /communities/search - query: $query" }
        return communityService.searchCommunities(query, userId)
    }

    @GetMapping("/communities/{id}/meetings")
    @Operation(summary = "Get community meetings (active and past)")
    fun getCommunityMeetings(@PathVariable id: Long): List<MeetingDto> {
        val userId = authUtils.getCurrentUserIdOrNull()
        logger.info { "GET /communities/$id/meetings" }
        return communityService.getCommunityMeetings(id, userId)
    }

    @GetMapping("/communities/{id}/subscribers")
    @Operation(summary = "Get community subscribers")
    fun getCommunitySubscribers(@PathVariable id: Long): List<UserInfoDto> {
        logger.info { "GET /communities/$id/subscribers" }
        return communityService.getCommunitySubscribers(id)
    }
}
