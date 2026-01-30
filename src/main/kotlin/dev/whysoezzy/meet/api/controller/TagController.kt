package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.ApiResponse
import dev.whysoezzy.meet.api.dto.TagDto
import dev.whysoezzy.meet.service.TagService
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.tags.Tag
import mu.KotlinLogging
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RestController

private val logger = KotlinLogging.logger {}

@RestController
@Tag(name = "Tags", description = "Tag management")
class TagController(
    private val tagService: TagService
) {
    
    @GetMapping("/api/v1/tags")
    @Operation(summary = "Get all tags")
    fun getAllTags(): ApiResponse<List<TagDto>> {
        logger.info { "GET /api/v1/tags" }
        return ApiResponse.success(tagService.getAllTags())
    }
}
