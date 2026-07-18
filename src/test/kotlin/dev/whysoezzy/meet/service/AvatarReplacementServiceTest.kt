package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.config.StorageProperties
import dev.whysoezzy.meet.api.error.ValidationException
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.UserRepository
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import org.mockito.Mockito.doAnswer
import org.mockito.Mockito.doThrow
import org.mockito.Mockito.doReturn
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.spy
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import org.springframework.dao.DataIntegrityViolationException
import org.springframework.mock.web.MockMultipartFile
import org.springframework.transaction.support.TransactionSynchronizationManager
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.nio.file.Path
import javax.imageio.ImageIO
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class AvatarReplacementServiceTest {
    private val storage = mock(StorageService::class.java)
    private val users = mock(UserRepository::class.java)
    private val service = AvatarReplacementService(storage, users)
    private val upload = UploadResult("http://localhost:8080/media/avatars/new.jpg", "avatars/new.jpg")
    private val oldUrl = "http://localhost:8080/media/avatars/old.jpg"

    @TempDir
    lateinit var storageDirectory: Path

    @AfterEach
    fun clearSynchronization() {
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.clearSynchronization()
        }
    }

    @Test
    fun `cleans the new object and preserves the old object when profile persistence fails`() {
        val user = user(oldUrl)
        val file = uploadFile()
        `when`(storage.uploadAvatar(file, 1)).thenReturn(upload)
        `when`(users.findWithLockById(1)).thenReturn(user)
        doThrow(DataIntegrityViolationException("persistence failure")).`when`(users).saveAndFlush(user)

        assertFailsWith<DataIntegrityViolationException> { service.replace(1, file) }

        assertEquals(oldUrl, user.avatarUrl)
        verify(storage).deleteByUrl(upload.publicUrl)
        verify(storage, never()).deleteByUrl(oldUrl)
    }

    @Test
    fun `deletes the old local object only after commit`() {
        TransactionSynchronizationManager.initSynchronization()
        val user = user(oldUrl)
        val file = uploadFile()
        `when`(storage.uploadAvatar(file, 1)).thenReturn(upload)
        `when`(users.findWithLockById(1)).thenReturn(user)
        doReturn(user).`when`(users).saveAndFlush(user)
        `when`(storage.isManagedUrl(oldUrl)).thenReturn(true)

        service.replace(1, file)

        assertEquals(upload.publicUrl, user.avatarUrl)
        verify(storage, never()).deleteByUrl(oldUrl)
        TransactionSynchronizationManager.getSynchronizations().single().afterCommit()
        verify(storage).deleteByUrl(oldUrl)
    }

    @Test
    fun `preserves the persisted old avatar URL and resource when profile persistence fails`() {
        val storage = storage()
        val oldUpload = storage.uploadAvatar(imageFile(), 1)
        val user = user(oldUpload.publicUrl)
        val users = mock(UserRepository::class.java)
        val service = AvatarReplacementService(storage, users)
        `when`(users.findWithLockById(1)).thenReturn(user)
        doThrow(DataIntegrityViolationException("persistence failure")).`when`(users).saveAndFlush(user)

        assertFailsWith<DataIntegrityViolationException> { service.replace(1, imageFile()) }

        assertEquals(oldUpload.publicUrl, user.avatarUrl)
        assertTrue(Files.exists(storageDirectory.resolve(oldUpload.relativePath)))
        assertEquals(1, Files.list(storageDirectory.resolve("avatars")).use { it.count() })
    }

    @Test
    fun `preserves the prior avatar URL and resource when a decodable unsupported upload is rejected`() {
        val storage = storage()
        val oldUpload = storage.uploadAvatar(imageFile(), 1)
        val user = user(oldUpload.publicUrl)
        val users = mock(UserRepository::class.java)
        val service = AvatarReplacementService(storage, users)

        assertFailsWith<ValidationException> { service.replace(1, gifFile()) }

        assertEquals(oldUpload.publicUrl, user.avatarUrl)
        assertTrue(Files.exists(storageDirectory.resolve(oldUpload.relativePath)))
        verify(users, never()).findWithLockById(1)
    }

    @Test
    fun `preserves the prior avatar URL and resource when an oversized upload is rejected`() {
        val storage = storage()
        val oldUpload = storage.uploadAvatar(imageFile(), 1)
        val user = user(oldUpload.publicUrl)
        val users = mock(UserRepository::class.java)
        val service = AvatarReplacementService(storage, users)
        val oversizedFile = MockMultipartFile(
            "file",
            "avatar.jpg",
            "image/jpeg",
            encodedImage().copyOf(5_242_881),
        )

        assertFailsWith<ValidationException> { service.replace(1, oversizedFile) }

        assertEquals(oldUpload.publicUrl, user.avatarUrl)
        assertImageRetrievable(oldUpload)
        verify(users, never()).findWithLockById(1)
    }

    @Test
    fun `preserves the prior avatar URL and resource when storage writing fails`() {
        val realStorage = storage()
        val oldUpload = realStorage.uploadAvatar(imageFile(), 1)
        val storage = spy(realStorage)
        val user = user(oldUpload.publicUrl)
        val users = mock(UserRepository::class.java)
        val service = AvatarReplacementService(storage, users)
        val file = imageFile()
        doThrow(IllegalStateException("storage write failure")).`when`(storage).uploadAvatar(file, 1)

        assertFailsWith<IllegalStateException> { service.replace(1, file) }

        assertEquals(oldUpload.publicUrl, user.avatarUrl)
        assertImageRetrievable(oldUpload)
        verify(users, never()).findWithLockById(1)
    }

    @Test
    fun `deletes the physical old object after commit while the replacement remains retrievable`() {
        TransactionSynchronizationManager.initSynchronization()
        val storage = storage()
        val oldUpload = storage.uploadAvatar(imageFile(), 1)
        val user = user(oldUpload.publicUrl)
        val users = mock(UserRepository::class.java)
        val service = AvatarReplacementService(storage, users)
        var persistedAvatarUrl: String? = null
        `when`(users.findWithLockById(1)).thenReturn(user)
        doAnswer { invocation ->
            persistedAvatarUrl = invocation.getArgument<User>(0).avatarUrl
            invocation.getArgument<User>(0)
        }.`when`(users).saveAndFlush(user)

        val replacement = service.replace(1, imageFile())
        TransactionSynchronizationManager.getSynchronizations().single().afterCommit()

        assertEquals(replacement.publicUrl, persistedAvatarUrl)
        assertTrue(Files.notExists(storageDirectory.resolve(oldUpload.relativePath)))
        assertImageRetrievable(replacement)
    }

    @Test
    fun `keeps the committed replacement when old object deletion fails after commit`() {
        TransactionSynchronizationManager.initSynchronization()
        val storage = storage()
        val oldPath = storageDirectory.resolve("avatars/old.jpg")
        Files.createDirectories(oldPath)
        Files.writeString(oldPath.resolve("keep"), "old object cannot be deleted")
        val user = user("http://localhost:8080/media/avatars/old.jpg")
        val users = mock(UserRepository::class.java)
        val service = AvatarReplacementService(storage, users)
        var persistedAvatarUrl: String? = null
        `when`(users.findWithLockById(1)).thenReturn(user)
        doAnswer { invocation ->
            persistedAvatarUrl = invocation.getArgument<User>(0).avatarUrl
            invocation.getArgument<User>(0)
        }.`when`(users).saveAndFlush(user)

        val replacement = service.replace(1, imageFile())
        TransactionSynchronizationManager.getSynchronizations().single().afterCommit()

        assertEquals(replacement.publicUrl, persistedAvatarUrl)
        assertTrue(Files.exists(storageDirectory.resolve(replacement.relativePath)))
        assertTrue(Files.exists(oldPath.resolve("keep")))
    }

    private fun storage(): StorageService {
        val props = StorageProperties().apply {
            uploadDir = storageDirectory.toString()
            baseUrl = "http://localhost:8080/media"
        }
        return StorageService(props).also { it.init() }
    }

    private fun user(avatarUrl: String) = User(
        name = "Test",
        surname = "User",
        phone = "+70000000000",
        avatarUrl = avatarUrl,
    )

    private fun uploadFile() = MockMultipartFile("file", "avatar.jpg", "image/jpeg", byteArrayOf(1))

    private fun imageFile() = MockMultipartFile("file", "avatar.jpg", "image/jpeg", encodedImage())

    private fun gifFile() = MockMultipartFile("file", "avatar.gif", "image/gif", encodedImage("gif"))

    private fun assertImageRetrievable(upload: UploadResult) {
        Files.newInputStream(storageDirectory.resolve(upload.relativePath)).use {
            assertTrue(ImageIO.read(it) != null)
        }
    }

    private fun encodedImage(format: String = "jpg"): ByteArray {
        val image = BufferedImage(1, 1, BufferedImage.TYPE_INT_RGB)
        return ByteArrayOutputStream().use { output ->
            check(ImageIO.write(image, format, output))
            output.toByteArray()
        }
    }
}
