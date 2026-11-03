package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.ingestion.MeetingUpsertService
import dev.whysoezzy.meet.ingestion.RawEvent
import dev.whysoezzy.meet.ingestion.UpsertResult
import dev.whysoezzy.meet.ingestion.Coordinates
import dev.whysoezzy.meet.ingestion.PreparedTimepadPoint
import dev.whysoezzy.meet.ingestion.SavedTimepadVenue
import dev.whysoezzy.meet.ingestion.GeocodingService
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.test.context.bean.override.mockito.MockitoBean
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MeetingUpsertServicePostgresTest(
    @Autowired private val upsertService: MeetingUpsertService,
) : IntegrationTestSupport() {
    @MockitoBean private lateinit var geocodingService: GeocodingService

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

    @Test
    fun `Timepad uses prepared point then reuses unchanged venue and invalidates changed venue`() {
        val event = offline("enriched")
        val derived = Coordinates(12.0, 34.0)
        val prepared = PreparedTimepadPoint(event.sourceExternalId, event.address, null, derived)
        upsertService.upsertTimepad(event, 100, prepared)
        assertPoint(event.sourceExternalId, derived)
        val id = meetings.findBySourceAndSourceExternalId(EventSource.TIMEPAD, event.sourceExternalId)!!.id

        upsertService.upsertTimepad(event.copy(address = "  TEST   street 1 "), 200)
        assertPoint(event.sourceExternalId, derived)
        assertEquals(id, meetings.findBySourceAndSourceExternalId(EventSource.TIMEPAD, event.sourceExternalId)!!.id)

        upsertService.upsertTimepad(event.copy(address = "Other street 2"), 300, prepared)
        assertPoint(event.sourceExternalId, Coordinates(0.0, 0.0))
        upsertService.upsertTimepad(event.copy(latitude = 14.0, longitude = 36.0), 400, prepared)
        assertPoint(event.sourceExternalId, Coordinates(14.0, 36.0))
        upsertService.upsertTimepad(event.copy(isOnline = true), 500)
        assertPoint(event.sourceExternalId, Coordinates(0.0, 0.0))
    }

    @Test
    fun `format flips clear prior point and never request geocoding for online venue`() {
        val physical = offline("format-flip").copy(latitude = 55.75, longitude = 37.61)
        upsertService.upsertTimepad(physical, 100)
        val first = meetings.findBySourceAndSourceExternalId(EventSource.TIMEPAD, physical.sourceExternalId)!!
        val id = first.id
        assertPoint(physical.sourceExternalId, Coordinates(55.75, 37.61))

        val online = physical.copy(
            address = "Онлайн", latitude = 0.0, longitude = 0.0, isOnline = true,
        )
        upsertService.upsertTimepad(online, 200)
        val onlineRow = meetings.findBySourceAndSourceExternalId(EventSource.TIMEPAD, physical.sourceExternalId)!!
        assertEquals(id, onlineRow.id)
        assertTrue(onlineRow.isOnline)
        assertEquals("Онлайн", onlineRow.address)
        assertPoint(physical.sourceExternalId, Coordinates(0.0, 0.0))
        assertNull(upsertService.prepareTimepadPoint(online, SavedTimepadVenue.from(onlineRow)))
        verify(geocodingService, never()).geocodeTimepad("Онлайн")

        val offlineAgain = physical.copy(latitude = 0.0, longitude = 0.0)
        upsertService.upsertTimepad(offlineAgain, 300)
        val offlineRow = meetings.findBySourceAndSourceExternalId(
            EventSource.TIMEPAD, physical.sourceExternalId,
        )!!
        assertEquals(id, offlineRow.id)
        assertFalse(offlineRow.isOnline)
        assertEquals("Test street 1", offlineRow.address)
        assertPoint(physical.sourceExternalId, Coordinates(0.0, 0.0))
    }

    @Test
    fun `locked row insertion replacement and concurrent timestamp change discard prepared evidence`() {
        val event = offline("concurrent")
        val point = Coordinates(12.0, 34.0)
        val absent = PreparedTimepadPoint(event.sourceExternalId, event.address, null, point)
        upsertService.upsertTimepad(event, 100)
        upsertService.upsertTimepad(event, 200, absent)
        assertPoint(event.sourceExternalId, Coordinates(0.0, 0.0))

        var row = meetings.findBySourceAndSourceExternalId(EventSource.TIMEPAD, event.sourceExternalId)!!
        val old = SavedTimepadVenue.from(row)
        val prepared = absent.copy(expectedSaved = old)
        row.ingestedAt = row.ingestedAt!!.plusSeconds(1)
        meetings.saveAndFlush(row)
        upsertService.upsertTimepad(event, 300, prepared)
        assertPoint(event.sourceExternalId, Coordinates(0.0, 0.0))

        meetings.deleteById(row.id!!)
        upsertService.upsertTimepad(event, 400)
        row = meetings.findBySourceAndSourceExternalId(EventSource.TIMEPAD, event.sourceExternalId)!!
        upsertService.upsertTimepad(event, 500, prepared)
        assertPoint(event.sourceExternalId, Coordinates(0.0, 0.0))
        kotlin.test.assertNotEquals(old.id, row.id)
    }

    private fun offline(id: String) = raw("Synthetic offline", null).copy(
        sourceExternalId = id, address = "Test street 1", isOnline = false, timepadGroups = listOf("IT"),
    )

    private fun assertPoint(id: String, expected: Coordinates) {
        val row = meetings.findBySourceAndSourceExternalId(EventSource.TIMEPAD, id)!!
        assertEquals(expected, Coordinates(row.latitude, row.longitude))
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
