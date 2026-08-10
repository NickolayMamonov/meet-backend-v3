package dev.whysoezzy.meet.ingestion

import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import org.mockito.Mockito.verifyNoMoreInteractions
import org.mockito.Mockito.`when`

class IngestionSchedulerTest {
    private val ingestionService = mock(IngestionService::class.java)
    private val scheduler = IngestionScheduler(ingestionService)

    @Test
    fun `scheduled ingestion does not purge completed meetings`() {
        `when`(ingestionService.runAll()).thenReturn(emptyList())

        scheduler.scheduled()

        verify(ingestionService).runAll()
        verifyNoMoreInteractions(ingestionService)
    }
}
