package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.error.NotFoundException
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.service.StorageService
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import mu.KotlinLogging
import org.springframework.http.MediaType
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.*
import org.springframework.web.multipart.MultipartFile

private val logger = KotlinLogging.logger {}

data class UploadResponse(
    val url: String
)

@RestController
@RequestMapping("/media")
@Tag(name = "Media", description = "File upload endpoints")
class MediaController(
    private val storageService: StorageService,
    private val userRepository: UserRepository,
    private val authUtils: AuthUtils
) {

    /**
     * Загрузка аватарки текущего пользователя.
     *
     * Экран Profile/Edit → "Изменить фото"
     * После успешной загрузки клиент должен вызвать PUT /profile с полученным URL.
     *
     * Пример запроса (multipart/form-data):
     *   POST /media/avatar
     *   Content-Type: multipart/form-data
     *   Authorization: Bearer <token>
     *   Body: file=<image>
     */
    @PostMapping(
        "/avatar",
        consumes = [MediaType.MULTIPART_FORM_DATA_VALUE]
    )
    @Operation(
        summary = "Upload user avatar",
        security = [SecurityRequirement(name = "bearerAuth")]
    )
    fun uploadAvatar(
        @RequestParam("file") file: MultipartFile
    ): ResponseEntity<UploadResponse> {
        val userId = authUtils.getCurrentUserId()
        logger.info { "POST /media/avatar - user: $userId, file: ${file.originalFilename}, size: ${file.size}" }

        // Удаляем старую аватарку если она была загружена локально
        val user = userRepository.findById(userId).orElseThrow {
            NotFoundException("User not found")
        }
        user.avatarUrl?.let { oldUrl ->
            if (oldUrl.isNotBlank() && oldUrl.contains("/media/avatars/")) {
                storageService.deleteByUrl(oldUrl)
            }
        }

        val result = storageService.uploadAvatar(file, userId)

        // Сразу обновляем avatarUrl в БД
        user.avatarUrl = result.publicUrl
        userRepository.save(user)

        logger.info { "Avatar uploaded for user $userId: ${result.publicUrl}" }
        return ResponseEntity.ok(UploadResponse(url = result.publicUrl))
    }

    /**
     * Загрузка изображения для встречи (для администраторов / организаторов).
     *
     * POST /media/meeting
     */
    @PostMapping(
        "/meeting",
        consumes = [MediaType.MULTIPART_FORM_DATA_VALUE]
    )
    @Operation(
        summary = "Upload meeting cover image",
        security = [SecurityRequirement(name = "bearerAuth")]
    )
    fun uploadMeetingImage(
        @RequestParam("file") file: MultipartFile
    ): ResponseEntity<UploadResponse> {
        val userId = authUtils.getCurrentUserId()
        logger.info { "POST /media/meeting - user: $userId, size: ${file.size}" }

        val result = storageService.uploadMeetingImage(file)
        return ResponseEntity.ok(UploadResponse(url = result.publicUrl))
    }

    /**
     * Загрузка изображения для сообщества.
     *
     * POST /media/community
     */
    @PostMapping(
        "/community",
        consumes = [MediaType.MULTIPART_FORM_DATA_VALUE]
    )
    @Operation(
        summary = "Upload community cover image",
        security = [SecurityRequirement(name = "bearerAuth")]
    )
    fun uploadCommunityImage(
        @RequestParam("file") file: MultipartFile
    ): ResponseEntity<UploadResponse> {
        val userId = authUtils.getCurrentUserId()
        logger.info { "POST /media/community - user: $userId, size: ${file.size}" }

        val result = storageService.uploadCommunityImage(file)
        return ResponseEntity.ok(UploadResponse(url = result.publicUrl))
    }
}
