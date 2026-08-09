package dev.whysoezzy.meet.integration

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.MeetingStatus
import dev.whysoezzy.meet.domain.entity.Tag
import dev.whysoezzy.meet.domain.entity.User
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.data.domain.PageRequest
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MeetingDiscoveryRepositoryPostgresTest : IntegrationTestSupport() {
    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `effective end keeps before equal and after boundaries plus null fallback`() {
        val now = 1_700_000_000_000L
        val before = meetings.save(meeting("before", time = now + 10_000, endsAt = now - 1))
        val equal = meetings.save(meeting("equal", time = now + 20_000, endsAt = now))
        val after = meetings.save(meeting("after", time = now + 30_000, endsAt = now + 1))
        val fallbackBefore = meetings.save(meeting("fallback-before", time = now - 1))
        val fallbackEqual = meetings.save(meeting("fallback-equal", time = now))
        val cancelled = meetings.save(
            meeting("cancelled", time = now + 40_000, endsAt = now + 1).also {
                it.status = MeetingStatus.CANCELLED
            },
        )
        meetings.flush()

        val result = meetings.findDiscoveryMeetings(
            MeetingStatus.ACTIVE,
            now,
            PageRequest.of(0, 20),
        )

        assertEquals(
            listOf(fallbackEqual.id, equal.id, after.id),
            result.map { it.id },
        )
        assertTrue(cancelled.id !in result.map { it.id })
        assertTrue(before.id !in result.map { it.id })
        assertTrue(fallbackBefore.id !in result.map { it.id })
    }

    @Test
    fun `tag and search discovery filter before database pagination`() {
        val now = 1_700_000_000_000L
        val kotlin = tags.save(Tag("Kotlin"))
        val eligibleOne = meetings.save(
            meeting("Kotlin one", now + 1).also { it.tags.add(kotlin) },
        )
        val completed = meetings.save(
            meeting("Kotlin completed", now - 1, endsAt = now - 1).also { it.tags.add(kotlin) },
        )
        val eligibleTwo = meetings.save(
            meeting("Kotlin two", now + 2).also { it.tags.add(kotlin) },
        )
        meetings.flush()

        assertEquals(
            listOf(eligibleOne.id, eligibleTwo.id),
            meetings.findDiscoveryMeetingsByTag(
                kotlin.id!!,
                MeetingStatus.ACTIVE,
                now,
                PageRequest.of(0, 2),
            ).map { it.id },
        )
        assertEquals(
            listOf(eligibleOne.id, eligibleTwo.id),
            meetings.searchDiscoveryMeetings("kotlin", MeetingStatus.ACTIVE, now).map { it.id },
        )
        assertTrue(completed.id !in meetings.searchDiscoveryMeetings("kotlin", MeetingStatus.ACTIVE, now).map { it.id })
    }

    @Test
    fun `popular filters completed rows before ranking and applies deterministic ties`() {
        val now = 1_700_000_000_000L
        val participant = users.save(User("Participant", "One", "+15550000001"))
        val completed = meetings.save(
            meeting("completed", now + 1, endsAt = now - 1).also {
                it.participants.add(participant)
            },
        )
        val tieLate = meetings.save(meeting("tie-late", now + 20))
        val tieEarly = meetings.save(meeting("tie-early", now + 10))
        meetings.flush()

        val result = meetings.findPopularDiscoveryMeetings(
            MeetingStatus.ACTIVE,
            now,
            PageRequest.of(0, 2),
        )

        assertEquals(listOf(tieEarly.id, tieLate.id), result.map { it.id })
        assertTrue(completed.id !in result.map { it.id })
    }

    @Test
    fun `chronological and popular exclusions are applied before limits`() {
        val now = 1_700_000_000_000L
        val excludedParticipant = users.save(User("Excluded", "Participant", "+15550000003"))
        val excluded = meetings.save(
            meeting("excluded", now + 1).also {
                it.participants.add(excludedParticipant)
            },
        )
        val chronologicalOne = meetings.save(meeting("chronological-one", now + 2))
        val chronologicalTwo = meetings.save(meeting("chronological-two", now + 3))
        val popularOne = meetings.save(meeting("popular-one", now + 4))
        val popularTwo = meetings.save(meeting("popular-two", now + 5))
        meetings.flush()

        val chronological = meetings.findDiscoveryMeetingsExcluding(
            MeetingStatus.ACTIVE,
            now,
            setOf(excluded.id!!),
            PageRequest.of(0, 2),
        )
        val popular = meetings.findPopularDiscoveryMeetingsExcluding(
            MeetingStatus.ACTIVE,
            now,
            setOf(excluded.id!!),
            PageRequest.of(0, 2),
        )

        assertEquals(listOf(chronologicalOne.id, chronologicalTwo.id), chronological.map { it.id })
        assertEquals(listOf(chronologicalOne.id, chronologicalTwo.id), popular.map { it.id })
        assertEquals(popular.size, popular.map { it.id }.distinct().size)
        assertTrue(excluded.id !in chronological.map { it.id })
        assertTrue(excluded.id !in popular.map { it.id })
        assertTrue(popularOne.id !in popular.map { it.id })
        assertTrue(popularTwo.id !in popular.map { it.id })
    }

    @Test
    fun `detail and participant history remain available for completed meetings`() {
        val participant = users.save(User("History", "User", "+15550000002"))
        val completed = meetings.save(
            meeting("historical", 1_600_000_000_000).also {
                it.participants.add(participant)
            },
        )
        meetings.flush()

        assertEquals(completed.id, meetings.findById(completed.id!!).orElseThrow().id)
        assertEquals(listOf(completed.id), meetings.findByParticipantId(participant.id!!).map { it.id })
    }

    @Test
    fun `representative discovery predicate is filtered ordered and bounded in postgres`() {
        val now = 1_700_000_000_000L
        val completedRows = 600
        val eligibleRows = 80
        val cancelledRows = 20
        val limit = 20

        jdbcTemplate.update(
            """
            INSERT INTO meetings (
                title, description, image_url, time, date, address, latitude, longitude, status, ends_at
            )
            SELECT
                'completed-' || series,
                'Repository volume fixture',
                '',
                ? - series * 1000,
                '01.01.2026',
                'Online',
                0.0,
                0.0,
                'ACTIVE',
                CASE WHEN series % 2 = 0 THEN ? - series ELSE NULL END
            FROM generate_series(1, ?) AS series
            """.trimIndent(),
            now,
            now,
            completedRows,
        )
        jdbcTemplate.update(
            """
            INSERT INTO meetings (
                title, description, image_url, time, date, address, latitude, longitude, status, ends_at
            )
            SELECT
                'eligible-' || series,
                'Repository volume fixture',
                '',
                ? + series * 1000,
                '01.01.2026',
                'Online',
                0.0,
                0.0,
                'ACTIVE',
                CASE WHEN series % 2 = 0 THEN ? + series * 2000 ELSE NULL END
            FROM generate_series(1, ?) AS series
            """.trimIndent(),
            now,
            now,
            eligibleRows,
        )
        jdbcTemplate.update(
            """
            INSERT INTO meetings (
                title, description, image_url, time, date, address, latitude, longitude, status, ends_at
            )
            SELECT
                'cancelled-' || series,
                'Repository volume fixture',
                '',
                ? + series * 1000,
                '01.01.2026',
                'Online',
                0.0,
                0.0,
                'CANCELLED',
                ? + series * 2000
            FROM generate_series(1, ?) AS series
            """.trimIndent(),
            now,
            now,
            cancelledRows,
        )
        jdbcTemplate.execute("ANALYZE meetings")

        assertEquals(
            eligibleRows.toLong(),
            jdbcTemplate.queryForObject(
                """
                SELECT COUNT(*)
                FROM meetings
                WHERE status = 'ACTIVE'
                  AND COALESCE(ends_at, time) >= $now
                """.trimIndent(),
                Long::class.java,
            ),
        )
        assertEquals(
            completedRows.toLong(),
            jdbcTemplate.queryForObject(
                """
                SELECT COUNT(*)
                FROM meetings
                WHERE status = 'ACTIVE'
                  AND COALESCE(ends_at, time) < $now
                """.trimIndent(),
                Long::class.java,
            ),
        )

        val selectedTitles = jdbcTemplate.queryForList(
            """
            SELECT title
            FROM meetings
            WHERE status = 'ACTIVE'
              AND COALESCE(ends_at, time) >= $now
            ORDER BY time ASC, id ASC
            LIMIT $limit
            """.trimIndent(),
            String::class.java,
        )
        assertEquals((1..limit).map { "eligible-$it" }, selectedTitles)

        val planJson = requireNotNull(
            jdbcTemplate.queryForObject(
                """
                EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
                SELECT id
                FROM meetings
                WHERE status = 'ACTIVE'
                  AND COALESCE(ends_at, time) >= $now
                ORDER BY time ASC, id ASC
                LIMIT $limit
                """.trimIndent(),
                String::class.java,
            ),
        )
        val plan = ObjectMapper().readTree(planJson)
        val evidence = plan.toPrettyString()
        val limitNode = findNodes(plan) { it.path("Node Type").asText() == "Limit" }.single()
        val relationNodes = findNodes(plan) { it.path("Relation Name").asText() == "meetings" }
        val conditions = relationNodes.flatMap { node ->
            listOf("Filter", "Index Cond", "Recheck Cond")
                .map { node.path(it).asText() }
                .filter { it.isNotBlank() }
        }.joinToString(" ")
        val sortKeys = findNodes(plan) { it.has("Sort Key") }
            .flatMap { node -> node.path("Sort Key").map(JsonNode::asText) }
        val sharedBlocks = findNodes(plan) {
            it.has("Shared Hit Blocks") || it.has("Shared Read Blocks")
        }.sumOf {
            it.path("Shared Hit Blocks").asLong() + it.path("Shared Read Blocks").asLong()
        }

        assertEquals(limit.toLong(), limitNode.path("Actual Rows").asLong(), evidence)
        assertEquals(1L, limitNode.path("Actual Loops").asLong(), evidence)
        assertTrue(limitNode.path("Plan Rows").asLong() in 1..limit.toLong(), evidence)
        assertTrue(
            limitNode.path("Total Cost").asDouble() >= limitNode.path("Startup Cost").asDouble(),
            evidence,
        )
        assertTrue(relationNodes.isNotEmpty(), evidence)
        assertTrue(conditions.contains("COALESCE"), evidence)
        assertTrue(conditions.contains("status") && conditions.contains("ACTIVE"), evidence)
        assertTrue(sortKeys.any { it.contains("time") } && sortKeys.any { it.contains("id") }, evidence)
        assertTrue(sharedBlocks > 0, evidence)
    }

    private fun meeting(
        title: String,
        time: Long,
        endsAt: Long? = null,
    ) = Meeting(
        title = title,
        description = "Repository fixture",
        imageUrl = "",
        time = time,
        date = "01.01.2026",
        address = "Online",
        latitude = 0.0,
        longitude = 0.0,
        endsAt = endsAt,
    )

    private fun findNodes(node: JsonNode, predicate: (JsonNode) -> Boolean): List<JsonNode> {
        val matches = mutableListOf<JsonNode>()
        if (predicate(node)) {
            matches.add(node)
        }
        when {
            node.isObject -> node.elements().forEachRemaining { matches.addAll(findNodes(it, predicate)) }
            node.isArray -> node.elements().forEachRemaining { matches.addAll(findNodes(it, predicate)) }
        }
        return matches
    }
}
