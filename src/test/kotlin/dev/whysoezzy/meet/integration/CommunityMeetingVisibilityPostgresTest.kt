package dev.whysoezzy.meet.integration

import com.jayway.jsonpath.JsonPath
import dev.whysoezzy.meet.domain.entity.Community
import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.MeetingStatus
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class CommunityMeetingVisibilityPostgresTest @Autowired constructor(
    private val mockMvc: MockMvc,
) : IntegrationTestSupport() {
    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `community meetings expose accepted Timepad fields and omit expired rows without changing manual or demo fields`() {
        val now = System.currentTimeMillis()
        val community = communities.save(
            Community(
                name = "Timepad test community",
                description = "Community visibility fixture",
                imageUrl = "https://example.test/community.png",
            ),
        )
        val accepted = saveMeeting(
            community = community,
            title = "Accepted Timepad meeting",
            time = now + DAY_MS,
            source = EventSource.TIMEPAD,
            externalUrl = "https://timepad.ru/event/12345/",
            isOnline = false,
            eligibleUntil = now + DAY_MS,
        )
        saveMeeting(
            community = community,
            title = "Expired Timepad meeting",
            time = now + 2 * DAY_MS,
            source = EventSource.TIMEPAD,
            externalUrl = "https://timepad.ru/event/12346/",
            isOnline = false,
            eligibleUntil = now - 1,
        )
        val manual = saveMeeting(
            community = community,
            title = "Manual meeting",
            time = now + 3 * DAY_MS,
            source = EventSource.MANUAL,
            externalUrl = "https://manual.example.test/register",
            isOnline = true,
        )
        val demo = saveMeeting(
            community = community,
            title = "Demo-owned meeting",
            time = now + 4 * DAY_MS,
            source = EventSource.TIMEPAD,
            externalUrl = "https://demo.example.test/register",
            isOnline = true,
            demoCatalogKey = "fixture/community-demo",
        )

        val response = mockMvc.perform(get("/communities/${community.id}/meetings"))
            .andExpect(status().isOk)
            .andReturn()
            .response
            .contentAsString
        val rows = JsonPath.read<List<Map<String, Any?>>>(response, "$")
        val byTitle = rows.associateBy { it["title"] }

        assertEquals(
            listOf(accepted.title, manual.title, demo.title),
            rows.map { it["title"] },
        )
        assertEquals("TIMEPAD", byTitle.getValue(accepted.title)["source"])
        assertEquals("https://timepad.ru/event/12345/", byTitle.getValue(accepted.title)["externalUrl"])
        assertEquals(false, byTitle.getValue(accepted.title)["isOnline"])

        assertEquals("MANUAL", byTitle.getValue(manual.title)["source"])
        assertEquals("https://manual.example.test/register", byTitle.getValue(manual.title)["externalUrl"])
        assertEquals(true, byTitle.getValue(manual.title)["isOnline"])

        assertEquals("TIMEPAD", byTitle.getValue(demo.title)["source"])
        assertEquals("https://demo.example.test/register", byTitle.getValue(demo.title)["externalUrl"])
        assertEquals(true, byTitle.getValue(demo.title)["isOnline"])
        assertFalse(byTitle.containsKey("Expired Timepad meeting"))
        assertNotNull(demo.demoCatalogKey)
    }

    private fun saveMeeting(
        community: Community,
        title: String,
        time: Long,
        source: EventSource,
        externalUrl: String,
        isOnline: Boolean,
        eligibleUntil: Long? = null,
        demoCatalogKey: String? = null,
    ): Meeting = meetings.save(
        Meeting(
            title = title,
            description = "Community visibility fixture",
            imageUrl = "",
            time = time,
            date = "01.01.2027",
            address = "ул. Пример, 1",
            latitude = 55.75,
            longitude = 37.61,
            status = MeetingStatus.ACTIVE,
            communityHost = community,
            source = source,
            sourceExternalId = if (source == EventSource.TIMEPAD) title else null,
            externalUrl = externalUrl,
            isOnline = isOnline,
            timepadEligibleUntilMs = eligibleUntil,
            demoCatalogKey = demoCatalogKey,
        ),
    )

    private companion object {
        const val DAY_MS = 24 * 60 * 60 * 1000L
    }
}
