package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.error.ValidationException
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.service.AvatarReplacementService
import dev.whysoezzy.meet.service.StorageService
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import jakarta.validation.constraints.NotNull
import mu.KotlinLogging
import org.springframework.http.MediaType
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.multipart.MultipartFile

private val logger = KotlinLogging.logger {}

data class UploadResponse(val url: String)

@RestController
@RequestMapping("/media")
@Tag(name = "Media", description = "File upload endpoints")
class MediaController(
    private val storageService: StorageService,
    private val avatarReplacementService: AvatarReplacementService,
    private val authUtils: AuthUtils,
) {
    @PostMapping("/avatar", consumes = [MediaType.MULTIPART_FORM_DATA_VALUE])
    @Operation(summary = "Upload user avatar", security = [SecurityRequirement(name = "bearerAuth")])
    fun uploadAvatar(
        @RequestParam("file") @NotNull(message = "File is required") file: MultipartFile,
    ): ResponseEntity<UploadResponse> {
        validateFilePresent(file)
        val userId = authUtils.getCurrentUserId()
        logger.info { "POST /media/avatar - user: $userId, size: ${file.size}" }
        val result = avatarReplacementService.replace(userId, file)
        logger.info { "Avatar uploaded for user $userId" }
        return ResponseEntity.ok(UploadResponse(result.publicUrl))
    }

    @PostMapping("/meeting", consumes = [MediaType.MULTIPART_FORM_DATA_VALUE])
    @Operation(summary = "Upload meeting cover image", security = [SecurityRequirement(name = "bearerAuth")])
    fun uploadMeetingImage(
        @RequestParam("file") @NotNull(message = "File is required") file: MultipartFile,
    ): ResponseEntity<UploadResponse> {
        validateFilePresent(file)
        val userId = authUtils.getCurrentUserId()
        logger.info { "POST /media/meeting - user: $userId, size: ${file.size}" }
        return ResponseEntity.ok(UploadResponse(storageService.uploadMeetingImage(file).publicUrl))
    }

    @PostMapping("/community", consumes = [MediaType.MULTIPART_FORM_DATA_VALUE])
    @Operation(summary = "Upload community cover image", security = [SecurityRequirement(name = "bearerAuth")])
    fun uploadCommunityImage(
        @RequestParam("file") @NotNull(message = "File is required") file: MultipartFile,
    ): ResponseEntity<UploadResponse> {
        validateFilePresent(file)
        val userId = authUtils.getCurrentUserId()
        logger.info { "POST /media/community - user: $userId, size: ${file.size}" }
        return ResponseEntity.ok(UploadResponse(storageService.uploadCommunityImage(file).publicUrl))
    }

    private fun validateFilePresent(file: MultipartFile) {
        if (file.isEmpty) throw ValidationException("File is empty")
    }
}
