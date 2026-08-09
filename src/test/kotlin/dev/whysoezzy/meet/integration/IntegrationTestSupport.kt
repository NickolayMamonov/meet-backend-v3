package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.domain.entity.AdBlock
import dev.whysoezzy.meet.domain.entity.AdBlockType
import dev.whysoezzy.meet.domain.entity.Community
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.Tag
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.AdBlockRepository
import dev.whysoezzy.meet.domain.repository.CommunityRepository
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import dev.whysoezzy.meet.domain.repository.TagRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.support.PostgresTestDatabase
import org.junit.jupiter.api.Tag as JUnitTag
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.test.context.DynamicPropertyRegistry
import org.springframework.test.context.DynamicPropertySource

@SpringBootTest
@AutoConfigureMockMvc
@JUnitTag("postgres")
abstract class IntegrationTestSupport {
    @Autowired
    protected lateinit var jdbcTemplate: JdbcTemplate
    @Autowired
    protected lateinit var users: UserRepository
    @Autowired
    protected lateinit var tags: TagRepository
    @Autowired
    protected lateinit var communities: CommunityRepository
    @Autowired
    protected lateinit var meetings: MeetingRepository
    @Autowired
    protected lateinit var adBlocks: AdBlockRepository

    protected fun resetDatabase() {
        jdbcTemplate.execute(
            "TRUNCATE TABLE ad_block_communities, ad_block_users, meeting_participants, meeting_tags, " +
                "community_subscribers, community_tags, user_interests, user_social_media, refresh_tokens, " +
                "otp_codes, otp_rate_limit_attempts, auth_identities, ad_blocks, meetings, communities, users, " +
                "tags RESTART IDENTITY CASCADE",
        )
    }

    protected fun fixture(): ApiFixture {
        val kotlin = tags.save(Tag("Kotlin"))
        val android = tags.save(Tag("Android"))
        val alice = users.save(
            User("Alice", "Tester", "+15550000001", email = "alice@example.test", city = "Moscow").also {
                it.bio = "Backend engineer"
                it.avatarUrl = "https://example.test/alice.png"
                it.interests.add(kotlin)
            },
        )
        val bob = users.save(
            User("Bob", "Member", "+15550000002").also {
                it.bio = "Android developer"
                it.interests.add(android)
            },
        )
        val community = communities.save(
            Community(
                name = "Kotlin Moscow",
                description = "Kotlin community",
                imageUrl = "https://example.test/community.png",
                tags = mutableSetOf(kotlin),
            ).also { it.subscribers.add(bob) },
        )
        val meeting = meetings.save(
            Meeting(
                title = "Kotlin testing meetup",
                description = "MockMvc and PostgreSQL",
                imageUrl = "https://example.test/meeting.png",
                time = System.currentTimeMillis() + 86_400_000,
                date = "20.07.2026",
                address = "Moscow, Test street 1",
                latitude = 55.75,
                longitude = 37.61,
                capacity = 10,
                communityHost = community,
                tags = mutableSetOf(kotlin),
                participants = mutableSetOf(bob),
            ),
        )
        val textAd = adBlocks.save(
            AdBlock().also {
                it.type = AdBlockType.TEXT
                it.title = "Complete your profile"
                it.description = "Add your interests"
                it.actionText = "Edit profile"
                it.actionUrl = "/profile"
            },
        )
        val communityAd = adBlocks.save(
            AdBlock().also {
                it.type = AdBlockType.COMMUNITIES
                it.title = "Communities"
                it.description = "Find people"
                it.communities.add(community)
            },
        )
        return ApiFixture(alice, bob, kotlin, community, meeting, textAd, communityAd)
    }

    companion object {
        private val database = PostgresTestDatabase("meet_integration").also { database ->
            Runtime.getRuntime().addShutdownHook(Thread(database::close))
        }

        @JvmStatic
        @DynamicPropertySource
        fun databaseProperties(registry: DynamicPropertyRegistry) {
            registry.add("spring.datasource.url") { database.jdbcUrl }
            registry.add("spring.datasource.username") { database.username }
            registry.add("spring.datasource.password") { database.password }
        }

    }
}

data class ApiFixture(
    val alice: User,
    val bob: User,
    val kotlin: Tag,
    val community: Community,
    val meeting: Meeting,
    val textAd: AdBlock,
    val communityAd: AdBlock,
)
