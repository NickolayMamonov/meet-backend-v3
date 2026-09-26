package dev.whysoezzy.meet.catalog

import org.junit.jupiter.api.Test
import org.mockito.Mockito.any
import org.mockito.Mockito.anyString
import org.mockito.Mockito.eq
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.mockito.Mockito.verify
import org.springframework.jdbc.core.JdbcTemplate
import kotlin.test.assertTrue

class RealCatalogAdvisoryLockTest {
    @Test
    fun `sets the five second local SQL lock timeout before acquiring`() {
        val jdbcTemplate = mock(JdbcTemplate::class.java)
        `when`(
            jdbcTemplate.queryForObject(
                anyString(),
                eq(Boolean::class.java),
                any(),
                any(),
            ),
        ).thenReturn(true)

        assertTrue(RealCatalogAdvisoryLock(jdbcTemplate).tryAcquire())
        verify(jdbcTemplate).execute("SET LOCAL lock_timeout = '5s'")
    }
}
