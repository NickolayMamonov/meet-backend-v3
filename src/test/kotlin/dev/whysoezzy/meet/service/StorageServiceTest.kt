package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.error.ValidationException
import dev.whysoezzy.meet.config.StorageProperties
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.io.TempDir
import org.springframework.mock.web.MockMultipartFile
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.nio.file.Path
import javax.imageio.ImageIO
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class StorageServiceTest {
    @TempDir
    lateinit var storageDirectory: Path

    @Test
    fun `stores JPEG and PNG using the decoded format rather than declared MIME type`() {
        val storage = storage()

        val jpeg = storage.uploadAvatar(
            MockMultipartFile("file", "avatar.webp", "image/webp", encodedImage("jpg")),
            1,
        )
        val png = storage.uploadAvatar(
            MockMultipartFile("file", "avatar.jpg", "image/jpeg", encodedImage("png")),
            1,
        )

        assertTrue(jpeg.relativePath.endsWith(".jpg"))
        assertTrue(png.relativePath.endsWith(".png"))
        assertTrue(Files.exists(storageDirectory.resolve(jpeg.relativePath)))
        assertTrue(Files.exists(storageDirectory.resolve(png.relativePath)))
    }

    @Test
    fun `stores a real WebP image and retains its decoded extension`() {
        val result = storage().uploadAvatar(
            MockMultipartFile("file", "pixel.webp", "image/jpeg", encodedImage("webp")),
            1,
        )

        assertTrue(result.relativePath.endsWith(".webp"))
        assertTrue(Files.exists(storageDirectory.resolve(result.relativePath)))
    }

    @Test
    fun `rejects invalid and oversized uploads before persisting an object`() {
        val storage = storage(maxFileSize = 16)

        assertThrows<ValidationException> {
            storage.uploadAvatar(MockMultipartFile("file", "bad.jpg", "image/jpeg", "not an image".toByteArray()), 1)
        }
        assertThrows<ValidationException> {
            storage.uploadAvatar(MockMultipartFile("file", "large.jpg", "image/jpeg", encodedImage("jpg")), 1)
        }
        assertTrue(Files.list(storageDirectory.resolve("avatars")).use { !it.findAny().isPresent })
    }

    @Test
    fun `rejects decodable unsupported images before persisting an object`() {
        val storage = storage()

        assertThrows<ValidationException> {
            storage.uploadAvatar(MockMultipartFile("file", "avatar.gif", "image/gif", encodedImage("gif")), 1)
        }

        assertTrue(Files.list(storageDirectory.resolve("avatars")).use { !it.findAny().isPresent })
    }

    @Test
    fun `leaves the existing storage entry intact when writing a new avatar fails`() {
        val storage = storage()
        val avatars = storageDirectory.resolve("avatars")
        Files.delete(avatars)
        Files.writeString(avatars, "not a directory")

        assertThrows<Exception> {
            storage.uploadAvatar(MockMultipartFile("file", "avatar.jpg", "image/jpeg", encodedImage("jpg")), 1)
        }

        assertEquals("not a directory", Files.readString(avatars))
    }

    private fun storage(maxFileSize: Long = 5_242_880L): StorageService {
        val props = StorageProperties().apply {
            uploadDir = storageDirectory.toString()
            baseUrl = "http://localhost:8080/media"
            this.maxFileSize = maxFileSize
        }
        return StorageService(props).also { it.init() }
    }

    private fun encodedImage(format: String): ByteArray {
        val image = BufferedImage(1, 1, BufferedImage.TYPE_INT_RGB)
        return ByteArrayOutputStream().use { output ->
            check(ImageIO.write(image, format, output))
            output.toByteArray()
        }
    }

}
