package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.CommunityRepository
import dev.whysoezzy.meet.domain.repository.RefreshTokenRepository
import dev.whysoezzy.meet.domain.repository.TagRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

class UserServiceTest {
    private val userRepository = mock(UserRepository::class.java)
    private val tagRepository = mock(TagRepository::class.java)
    private val refreshTokenRepository = mock(RefreshTokenRepository::class.java)
    private val userService = UserService(
        userRepository,
        tagRepository,
        refreshTokenRepository,
        UserProfileMapper(),
    )

    @Test
    fun `deleting account increments auth version and revokes every refresh token`() {
        val user = User("Test", "User", "+79990000000").also {
            it.id = 1L
            it.authVersion = 4
        }
        `when`(userRepository.findWithLockById(1L)).thenReturn(user)

        userService.deleteAccount(1L)

        assertEquals(5, user.authVersion)
        assertNotNull(user.deletedAt)
        verify(userRepository).save(user)
        verify(refreshTokenRepository).deleteAllByUserId(1L)
    }
}
