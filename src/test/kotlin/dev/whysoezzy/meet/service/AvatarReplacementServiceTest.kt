package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.UserRepository
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Test
import org.mockito.Mockito.doThrow
import org.mockito.Mockito.doReturn
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import org.springframework.dao.DataIntegrityViolationException
import org.springframework.mock.web.MockMultipartFile
import org.springframework.transaction.support.TransactionSynchronizationManager
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class AvatarReplacementServiceTest {
    private val storage = mock(StorageService::class.java)
    private val users = mock(UserRepository::class.java)
    private val service = AvatarReplacementService(storage, users)
    private val upload = UploadResult("http://localhost:8080/media/avatars/new.jpg", "avatars/new.jpg")
    private val oldUrl = "http://localhost:8080/media/avatars/old.jpg"

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

    private fun user(avatarUrl: String) = User(
        name = "Test",
        surname = "User",
        phone = "+70000000000",
        avatarUrl = avatarUrl,
    )

    private fun uploadFile() = MockMultipartFile("file", "avatar.jpg", "image/jpeg", byteArrayOf(1))
}
