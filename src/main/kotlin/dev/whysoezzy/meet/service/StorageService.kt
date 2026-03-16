package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.config.StorageProperties
import mu.KotlinLogging
import org.springframework.stereotype.Service
import org.springframework.web.multipart.MultipartFile
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.StandardCopyOption
import java.util.UUID
import javax.imageio.ImageIO
import jakarta.annotation.PostConstruct

private val logger = KotlinLogging.logger {}

/**
 * Результат загрузки файла
 * @param publicUrl  URL для клиента (сохраняется в avatarUrl/imageUrl)
 * @param relativePath  путь внутри upload-dir, например "avatars/uuid.jpg"
 */
data class UploadResult(
    val publicUrl: String,
    val relativePath: String
)

@Service
class StorageService(
    private val props: StorageProperties
) {
    // Корневая директория хранилища (абсолютный путь)
    private lateinit var rootLocation: Path

    @PostConstruct
    fun init() {
        rootLocation = Paths.get(props.uploadDir).toAbsolutePath().normalize()
        // Создаём поддиректории при старте
        listOf("avatars", "meetings", "communities").forEach { sub ->
            Files.createDirectories(rootLocation.resolve(sub))
        }
        logger.info { "Storage initialized at: $rootLocation" }
    }

    /**
     * Загрузить аватарку пользователя.
     * Файл сохраняется в uploads/avatars/{uuid}.{ext}
     * Возвращает публичный URL.
     */
    fun uploadAvatar(file: MultipartFile, userId: Long): UploadResult {
        validateFile(file)
        val filename = buildFilename(file, prefix = "user_${userId}")
        return saveFile(file, subdir = "avatars", filename = filename)
    }

    /**
     * Загрузить изображение для встречи.
     * Файл сохраняется в uploads/meetings/{uuid}.{ext}
     */
    fun uploadMeetingImage(file: MultipartFile): UploadResult {
        validateFile(file)
        val filename = buildFilename(file)
        return saveFile(file, subdir = "meetings", filename = filename)
    }

    /**
     * Загрузить изображение сообщества.
     * Файл сохраняется в uploads/communities/{uuid}.{ext}
     */
    fun uploadCommunityImage(file: MultipartFile): UploadResult {
        validateFile(file)
        val filename = buildFilename(file)
        return saveFile(file, subdir = "communities", filename = filename)
    }

    /**
     * Удалить файл по его публичному URL или относительному пути.
     * Используется при смене аватарки — старый файл удаляем.
     */
    fun deleteByUrl(publicUrl: String) {
        val relativePath = publicUrl.removePrefix(props.baseUrl).trimStart('/')
        val filePath = rootLocation.resolve(relativePath).normalize()

        // Защита от path traversal
        if (!filePath.startsWith(rootLocation)) {
            logger.warn { "Attempt to delete file outside storage: $filePath" }
            return
        }

        try {
            Files.deleteIfExists(filePath)
            logger.info { "Deleted file: $filePath" }
        } catch (e: Exception) {
            logger.warn { "Failed to delete file $filePath: ${e.message}" }
        }
    }

    // ==================== Private ====================

    private fun validateFile(file: MultipartFile) {
        if (file.isEmpty) {
            throw IllegalArgumentException("File is empty")
        }

        if (file.size > props.maxFileSize) {
            val maxMb = props.maxFileSize / 1_048_576
            throw IllegalArgumentException("File size exceeds maximum allowed size of ${maxMb}MB")
        }

        val contentType = file.contentType?.lowercase()
            ?: throw IllegalArgumentException("Cannot determine file content type")

        if (contentType !in props.allowedTypesSet()) {
            throw IllegalArgumentException(
                "File type '$contentType' is not allowed. Allowed: ${props.allowedTypes}"
            )
        }

        // Проверяем, что файл действительно является изображением (защита от подмены)
        val image: BufferedImage? = try {
            ImageIO.read(file.inputStream)
        } catch (e: Exception) {
            null
        }
        if (image == null) {
            throw IllegalArgumentException("File is not a valid image")
        }
    }

    private fun saveFile(file: MultipartFile, subdir: String, filename: String): UploadResult {
        val targetDir = rootLocation.resolve(subdir)
        val targetPath = targetDir.resolve(filename).normalize()

        // Защита от path traversal
        if (!targetPath.startsWith(rootLocation)) {
            throw SecurityException("Invalid file path detected")
        }

        file.inputStream.use { input ->
            Files.copy(input, targetPath, StandardCopyOption.REPLACE_EXISTING)
        }

        val relativePath = "$subdir/$filename"
        val publicUrl = "${props.baseUrl.trimEnd('/')}/$relativePath"

        logger.info { "Saved file: $targetPath → $publicUrl" }
        return UploadResult(publicUrl = publicUrl, relativePath = relativePath)
    }

    private fun buildFilename(file: MultipartFile, prefix: String? = null): String {
        val ext = getExtension(file)
        val uuid = UUID.randomUUID().toString().replace("-", "")
        return if (prefix != null) "${prefix}_${uuid}.${ext}" else "${uuid}.${ext}"
    }

    private fun getExtension(file: MultipartFile): String {
        // Определяем расширение из MIME-типа, не из оригинального имени файла
        return when (file.contentType?.lowercase()) {
            "image/jpeg" -> "jpg"
            "image/png" -> "png"
            "image/webp" -> "webp"
            else -> "jpg"
        }
    }
}
