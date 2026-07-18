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
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.datasource.DriverManagerDataSource
import org.springframework.test.context.DynamicPropertyRegistry
import org.springframework.test.context.DynamicPropertySource
import org.junit.jupiter.api.extension.ConditionEvaluationResult
import org.junit.jupiter.api.extension.ExecutionCondition
import org.junit.jupiter.api.extension.ExtensionContext
import org.junit.jupiter.api.extension.ExtendWith
import org.junit.jupiter.api.AfterAll
import org.testcontainers.DockerClientFactory
import org.testcontainers.containers.PostgreSQLContainer
import java.util.UUID

@SpringBootTest
@AutoConfigureMockMvc
@ExtendWith(ExternalOrDockerPostgresCondition::class)
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
                "otp_codes, otp_rate_limit_attempts, ad_blocks, meetings, communities, users, tags RESTART IDENTITY CASCADE",
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
        private val database = TestPostgresDatabase()

        @JvmStatic
        @DynamicPropertySource
        fun databaseProperties(registry: DynamicPropertyRegistry) {
            registry.add("spring.datasource.url") { database.jdbcUrl }
            registry.add("spring.datasource.username") { database.username }
            registry.add("spring.datasource.password") { database.password }
        }

        @JvmStatic
        @AfterAll
        fun stopDatabase() = database.close()
    }
}

class ExternalOrDockerPostgresCondition : ExecutionCondition {
    override fun evaluateExecutionCondition(context: ExtensionContext): ConditionEvaluationResult {
        if (!System.getenv("TEST_POSTGRES_JDBC_URL").isNullOrBlank()) {
            return ConditionEvaluationResult.enabled("Using TEST_POSTGRES_JDBC_URL")
        }
        return if (DockerClientFactory.instance().isDockerAvailable) {
            ConditionEvaluationResult.enabled("Docker is available for PostgreSQL Testcontainers")
        } else {
            ConditionEvaluationResult.disabled(
                "Set TEST_POSTGRES_JDBC_URL, TEST_POSTGRES_USERNAME, and TEST_POSTGRES_PASSWORD, or start Docker",
            )
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

private class TestPostgresDatabase : AutoCloseable {
    private val externalUrl = System.getenv("TEST_POSTGRES_JDBC_URL")
    private val schema = "meet_integration_${UUID.randomUUID().toString().replace("-", "")}"
    private val containerDelegate = lazy { PostgreSQLContainer<Nothing>("postgres:16-alpine").apply { start() } }
    private val container by containerDelegate
    private val externalCredentials by lazy {
        val username = requireNotNull(System.getenv("TEST_POSTGRES_USERNAME")) {
            "TEST_POSTGRES_USERNAME is required with TEST_POSTGRES_JDBC_URL"
        }
        val password = requireNotNull(System.getenv("TEST_POSTGRES_PASSWORD")) {
            "TEST_POSTGRES_PASSWORD is required with TEST_POSTGRES_JDBC_URL"
        }
        DriverManagerDataSource(externalUrl, username, password).also {
            JdbcTemplate(it).execute("CREATE SCHEMA $schema")
        }
        username to password
    }

    val jdbcUrl: String
        get() = externalUrl?.let {
            val separator = if (it.contains("?")) "&" else "?"
            "$it${separator}currentSchema=$schema"
        } ?: container.jdbcUrl

    val username: String
        get() = externalUrl?.let { externalCredentials.first } ?: container.username

    val password: String
        get() = externalUrl?.let { externalCredentials.second } ?: container.password

    override fun close() {
        if (externalUrl != null) {
            val (username, password) = externalCredentials
            JdbcTemplate(DriverManagerDataSource(externalUrl, username, password))
                .execute("DROP SCHEMA IF EXISTS $schema CASCADE")
        } else if (containerDelegate.isInitialized()) {
            container.stop()
        }
    }
}
