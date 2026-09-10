package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.domain.entity.AdBlock
import dev.whysoezzy.meet.domain.entity.AdBlockType
import dev.whysoezzy.meet.domain.entity.Community
import dev.whysoezzy.meet.domain.entity.User
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.test.context.TestPropertySource
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import tools.jackson.databind.JsonNode
import tools.jackson.module.kotlin.jacksonObjectMapper
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@TestPropertySource(properties = ["spring.jpa.open-in-view=false"])
class AdBlockSerializationPostgresTest @Autowired constructor(
    private val mockMvc: MockMvc,
) : IntegrationTestSupport() {
    private val objectMapper = jacksonObjectMapper()

    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `list serializes all active ad types after the service transaction closes`() {
        val data = adFixture()

        val response = mockMvc.perform(get("/api/ads"))
            .andExpect(status().isOk)
            .andReturn()
            .response
        val ads = objectMapper.readTree(response.contentAsString)

        assertTrue(ads.isArray)
        assertEquals(3, ads.size())
        val text = ads.byId(data.textAd.id!!)
        assertCommon(text, data.textAd.id!!, true, "", "")
        assertEquals("TEXT", text.path("type").textValue())
        assertEquals("", text.path("actionText").textValue())
        assertTrue(text.path("actionUrl").isNull)
        assertTrue(text.path("communities").isNull)
        assertTrue(text.path("users").isNull)

        assertCommunityAd(ads.byId(data.communityAd.id!!), data)
        assertPeopleAd(ads.byId(data.peopleAd.id!!), data)
        assertFalse(ads.toList().any { it.path("id").longValue() == data.inactiveAd.id!! })
    }

    @Test
    fun `single serializes each ad type and preserves the empty not-found response`() {
        val data = adFixture()

        val text = getAd(data.textAd.id!!)
        assertCommon(text, data.textAd.id!!, true, "", "")
        assertEquals("TEXT", text.path("type").textValue())
        assertEquals("", text.path("actionText").textValue())
        assertTrue(text.path("actionUrl").isNull)
        assertTrue(text.path("communities").isNull)
        assertTrue(text.path("users").isNull)

        assertCommunityAd(getAd(data.communityAd.id!!), data)
        assertPeopleAd(getAd(data.peopleAd.id!!), data)

        mockMvc.perform(get("/api/ads/${data.inactiveAd.id}"))
            .andExpect(status().isOk)
        val missing = mockMvc.perform(get("/api/ads/${Long.MAX_VALUE}"))
            .andExpect(status().isOk)
            .andReturn()
            .response
        assertEquals("", missing.contentAsString)
    }

    private fun getAd(id: Long): JsonNode =
        objectMapper.readTree(
            mockMvc.perform(get("/api/ads/$id"))
                .andExpect(status().isOk)
                .andReturn()
                .response
                .contentAsString,
        )

    private fun assertCommon(
        ad: JsonNode,
        id: Long,
        isActive: Boolean,
        title: String,
        description: String,
    ) {
        assertEquals(id, ad.path("id").longValue())
        assertEquals(isActive, ad.path("isActive").booleanValue())
        assertEquals(title, ad.path("title").textValue())
        assertEquals(description, ad.path("description").textValue())
    }

    private fun assertCommunityAd(ad: JsonNode, data: AdFixture) {
        assertCommon(ad, data.communityAd.id!!, true, "Community picks", "Three communities")
        assertEquals("COMMUNITIES", ad.path("type").textValue())
        assertTrue(ad.path("actionText").isNull)
        assertTrue(ad.path("actionUrl").isNull)
        assertTrue(ad.path("users").isNull)

        val communities = ad.path("communities")
        assertTrue(communities.isArray)
        assertEquals(3, communities.size())
        data.communities.forEach { expected ->
            val actual = communities.byId(expected.id!!)
            assertEquals(expected.name, actual.path("name").textValue())
            assertEquals(expected.description, actual.path("description").textValue())
            assertEquals(expected.imageUrl, actual.path("imageUrl").textValue())
            assertEquals(expected.subscribers.size, actual.path("subscribersCount").intValue())
        }
    }

    private fun assertPeopleAd(ad: JsonNode, data: AdFixture) {
        assertCommon(ad, data.peopleAd.id!!, true, "People picks", "Four people")
        assertEquals("PEOPLE", ad.path("type").textValue())
        assertTrue(ad.path("communities").isNull)
        assertTrue(ad.path("actionText").isNull)
        assertTrue(ad.path("actionUrl").isNull)

        val users = ad.path("users")
        assertTrue(users.isArray)
        assertEquals(4, users.size())
        data.people.forEach { expected ->
            val actual = users.byId(expected.id!!)
            assertEquals(expected.name, actual.path("name").textValue())
            assertEquals(expected.surname, actual.path("surname").textValue())
            assertEquals(expected.avatarUrl ?: "", actual.path("avatarUrl").textValue())
            assertEquals(expected.bio, actual.path("bio").textValue())
            assertEquals(expected.role ?: "Не указано", actual.path("role").textValue())
        }
    }

    private fun JsonNode.byId(id: Long): JsonNode =
        toList().singleOrNull { it.path("id").longValue() == id }
            ?: error("No JSON item with id $id in $this")

    private fun adFixture(): AdFixture {
        val people = listOf(
            users.save(
                User("Alice", "Tester", "+15550000001").also {
                    it.avatarUrl = "https://example.test/alice.png"
                    it.bio = "Backend engineer"
                    it.role = "Engineer"
                },
            ),
            users.save(
                User("Bob", "Member", "+15550000002").also {
                    it.bio = "Android developer"
                },
            ),
            users.save(
                User("Carol", "Designer", "+15550000003").also {
                    it.avatarUrl = "https://example.test/carol.png"
                    it.bio = "Product designer"
                    it.role = "Designer"
                },
            ),
            users.save(
                User("Dave", "Writer", "+15550000004").also {
                    it.avatarUrl = "https://example.test/dave.png"
                    it.bio = "Technical writer"
                },
            ),
        )

        val communitiesToSave = listOf(
            Community(
                name = "Kotlin Moscow",
                description = "Kotlin community",
                imageUrl = "https://example.test/kotlin.png",
            ).also {
                it.subscribers.addAll(people.take(2))
            },
            Community(
                name = "Android Builders",
                description = "Android community",
                imageUrl = "https://example.test/android.png",
            ).also {
                it.subscribers.add(people[2])
            },
            Community(
                name = "Backend Guild",
                description = "Backend community",
                imageUrl = "https://example.test/backend.png",
            ).also {
                it.subscribers.addAll(people.take(3))
            },
        )
        val communities = this.communities.saveAllAndFlush(communitiesToSave)

        val textAd = AdBlock().apply {
            type = AdBlockType.TEXT
            title = null
            description = null
            actionText = ""
            actionUrl = null
        }
        val communityAd = AdBlock().apply {
            type = AdBlockType.COMMUNITIES
            title = "Community picks"
            description = "Three communities"
            this.communities.addAll(communities)
        }
        val peopleAd = AdBlock().apply {
            type = AdBlockType.PEOPLE
            title = "People picks"
            description = "Four people"
            this.users.addAll(people)
        }
        val inactiveAd = AdBlock().apply {
            type = AdBlockType.TEXT
            isActive = false
            title = "Inactive"
            description = "Should not be listed"
        }
        val ads = adBlocks.saveAllAndFlush(listOf(textAd, communityAd, peopleAd, inactiveAd))
        return AdFixture(
            textAd = ads[0],
            communityAd = ads[1],
            peopleAd = ads[2],
            inactiveAd = ads[3],
            communities = communities,
            people = people,
        )
    }
}

private data class AdFixture(
    val textAd: AdBlock,
    val communityAd: AdBlock,
    val peopleAd: AdBlock,
    val inactiveAd: AdBlock,
    val communities: List<Community>,
    val people: List<User>,
)
