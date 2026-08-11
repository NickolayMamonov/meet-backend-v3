package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.ingestion.MeetingUpsertService
import dev.whysoezzy.meet.ingestion.RawEvent
import dev.whysoezzy.meet.ingestion.UpsertResult
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import kotlin.test.assertEquals

class MeetingUpsertServicePostgresTest(
    @Autowired private val upsertService: MeetingUpsertService,
) : IntegrationTestSupport() {
    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `upserts TIMEPAD by source and sourceExternalId without duplicates`() {
        val original = raw(title = "Backend event", endsAt = 1_790_000_003_600)
        val updated = raw(title = "Updated backend event", endsAt = null)

        assertEquals(UpsertResult.CREATED, upsertService.upsert(EventSource.TIMEPAD, original))
        assertEquals(1_790_000_003_600L, meetings.findAll().single().endsAt)
        assertEquals(UpsertResult.UPDATED, upsertService.upsert(EventSource.TIMEPAD, updated))

        val rows = meetings.findAll()
        assertEquals(1, rows.size)
        assertEquals(EventSource.TIMEPAD, rows.single().source)
        assertEquals("timepad-42", rows.single().sourceExternalId)
        assertEquals("Updated backend event", rows.single().title)
        assertEquals(null, rows.single().endsAt)
    }

    private fun raw(title: String, endsAt: Long?) =
        RawEvent(
            sourceExternalId = "timepad-42",
            title = title,
            description = "Spring PostgreSQL backend",
            imageUrl = "",
            startsAtEpochMs = 1_790_000_000_000,
            endsAtEpochMs = endsAt,
            address = "Онлайн",
            latitude = 0.0,
            longitude = 0.0,
            externalUrl = "https://timepad.test/event/42",
            isOnline = true,
            topicKeywords = setOf("ИТ и интернет"),
        )
}
