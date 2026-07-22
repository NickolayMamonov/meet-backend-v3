package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.error.ValidationException
import dev.whysoezzy.meet.config.StorageProperties
import jakarta.annotation.PostConstruct
import mu.KotlinLogging
import org.springframework.stereotype.Service
import org.springframework.web.multipart.MultipartFile
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.StandardCopyOption
import java.util.UUID
import javax.imageio.ImageIO

private val logger = KotlinLogging.logger {}

data class UploadResult(
    val publicUrl: String,
    val relativePath: String,
)

@Service
class StorageService(
    private val props: StorageProperties,
) {
    private lateinit var rootLocation: Path

    @PostConstruct
    fun init() {
        rootLocation = Paths.get(props.uploadDir).toAbsolutePath().normalize()
        listOf("avatars", "meetings", "communities").forEach { Files.createDirectories(rootLocation.resolve(it)) }
        logger.info { "Storage initialized" }
    }

    fun uploadAvatar(file: MultipartFile, userId: Long): UploadResult =
        saveFile(file, "avatars", buildFilename(validateFile(file), "user_$userId"))

    fun uploadMeetingImage(file: MultipartFile): UploadResult =
        saveFile(file, "meetings", buildFilename(validateFile(file)))

    fun uploadCommunityImage(file: MultipartFile): UploadResult =
        saveFile(file, "communities", buildFilename(validateFile(file)))

    fun deleteUploaded(upload: UploadResult) {
        deleteRelativePath(upload.relativePath)
    }

    fun deleteOwnedAvatarByUrl(publicUrl: String, userId: Long) {
        val relativePath = localRelativePath(publicUrl) ?: return
        val filename = relativePath.removePrefix("avatars/")
        if (!filename.startsWith("user_${userId}_") || '/' in filename) return
        deleteRelativePath(relativePath)
    }

    private fun deleteRelativePath(relativePath: String) {
        val filePath = rootLocation.resolve(relativePath).normalize()
        if (!filePath.startsWith(rootLocation)) {
            logger.warn { "Storage delete rejected: invalid location" }
            return
        }

        try {
            Files.deleteIfExists(filePath)
            logger.info { "Storage file deleted" }
        } catch (_: Exception) {
            logger.warn { "Storage file deletion failed" }
        }
    }

    private fun validateFile(file: MultipartFile): DetectedImage {
        if (file.isEmpty) throw ValidationException("File is empty")
        if (file.size > props.maxFileSize) {
            throw ValidationException("File size exceeds maximum allowed size of ${props.maxFileSize / 1_048_576}MB")
        }

        val image = detectImage(file)
        if (image.mimeType !in props.allowedTypesSet()) {
            throw ValidationException("Detected image format '${image.mimeType}' is not allowed")
        }
        return image
    }

    private fun detectImage(file: MultipartFile): DetectedImage {
        try {
            file.inputStream.use { input ->
                ImageIO.createImageInputStream(input).use { stream ->
                    val reader = ImageIO.getImageReaders(stream).asSequence().firstOrNull()
                        ?: throw ValidationException("File is not a valid image")
                    try {
                        reader.input = stream
                        reader.read(0) ?: throw ValidationException("File is not a valid image")
                        return when (reader.formatName.lowercase()) {
                            "jpeg", "jpg" -> DetectedImage("image/jpeg", "jpg")
                            "png" -> DetectedImage("image/png", "png")
                            "webp" -> DetectedImage("image/webp", "webp")
                            else -> throw ValidationException("Detected image format is not allowed")
                        }
                    } finally {
                        reader.dispose()
                    }
                }
            }
        } catch (e: ValidationException) {
            throw e
        } catch (e: Exception) {
            throw ValidationException("File is not a valid image")
        }
    }

    private fun saveFile(file: MultipartFile, subdir: String, filename: String): UploadResult {
        val targetPath = rootLocation.resolve(subdir).resolve(filename).normalize()
        if (!targetPath.startsWith(rootLocation)) throw SecurityException("Invalid file path detected")
        val temporaryPath = Files.createTempFile(targetPath.parent, ".upload-", ".tmp")
        try {
            file.inputStream.use { Files.copy(it, temporaryPath, StandardCopyOption.REPLACE_EXISTING) }
            Files.move(temporaryPath, targetPath, StandardCopyOption.ATOMIC_MOVE)
        } catch (e: Exception) {
            Files.deleteIfExists(temporaryPath)
            throw e
        }

        val relativePath = "$subdir/$filename"
        val publicUrl = "${props.baseUrl.trimEnd('/')}/$relativePath"

        logger.info { "Storage file saved: type=$subdir, size=${file.size}" }
        return UploadResult(publicUrl = publicUrl, relativePath = relativePath)
    }

    private fun buildFilename(image: DetectedImage, prefix: String? = null): String {
        val uuid = UUID.randomUUID().toString().replace("-", "")
        return listOfNotNull(prefix, uuid).joinToString("_") + ".${image.extension}"
    }

    private fun localRelativePath(publicUrl: String): String? {
        val baseUrl = props.baseUrl.trimEnd('/')
        if (!publicUrl.startsWith("$baseUrl/")) return null
        val relativePath = publicUrl.removePrefix(baseUrl).trimStart('/')
        return relativePath.takeIf { it.startsWith("avatars/") }
    }

    private data class DetectedImage(val mimeType: String, val extension: String)
}
