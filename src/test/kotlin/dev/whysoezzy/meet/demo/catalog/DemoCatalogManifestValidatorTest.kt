package dev.whysoezzy.meet.demo.catalog

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import kotlin.test.assertEquals

class DemoCatalogManifestValidatorTest {
    private val validator = DemoCatalogManifestValidator()

    @Test
    fun `reviewed manifest is exact and fully referenced`() {
        val manifest = BetaDemoCatalog.manifest
        validator.validate(manifest, setOf("api.whysoezzy.online"))
        assertEquals("closed-beta-demo", manifest.catalogName)
        assertEquals("2026-08-15.v1", manifest.manifestVersion)
        assertEquals(6, manifest.tags.size)
        assertEquals(6, manifest.users.size)
        assertEquals(3, manifest.communities.size)
        assertEquals(6, manifest.meetings.size)
        assertEquals(3, manifest.adBlocks.size)
        assertEquals(11, manifest.mediaUrls.size)
        assertEquals(2, manifest.publicLandingUrls.size)
    }

    @Test
    fun `unapproved media host is rejected`() {
        assertThrows<IllegalArgumentException> {
            validator.validate(BetaDemoCatalog.manifest, setOf("cdn.example.invalid"))
        }
        assertThrows<IllegalArgumentException> {
            validator.validate(BetaDemoCatalog.manifest, setOf("api.whysoezzy.online", "cdn.example.invalid"))
        }
    }

    @Test
    fun `catalog identity is frozen`() {
        assertThrows<IllegalArgumentException> {
            validator.validate(
                BetaDemoCatalog.manifest.copy(catalogName = "another-catalog"),
                setOf("api.whysoezzy.online"),
            )
        }
        assertThrows<IllegalArgumentException> {
            validator.validate(
                BetaDemoCatalog.manifest.copy(manifestVersion = "2026-08-15.v2"),
                setOf("api.whysoezzy.online"),
            )
        }
    }

    @Test
    fun `references must target their declared entity category`() {
        val manifest = BetaDemoCatalog.manifest
        val wrongCategory = manifest.copy(
            users = manifest.users.mapIndexed { index, user ->
                if (index == 0) {
                    user.copy(interests = setOf(manifest.communities.first().key, manifest.tags.first().key))
                } else {
                    user
                }
            },
        )
        assertThrows<IllegalArgumentException> {
            validator.validate(wrongCategory, setOf("api.whysoezzy.online"))
        }
    }

    @Test
    fun `frozen root and relationship counts are required`() {
        val manifest = BetaDemoCatalog.manifest
        assertThrows<IllegalArgumentException> {
            validator.validate(manifest.copy(meetings = manifest.meetings.dropLast(1)), setOf("api.whysoezzy.online"))
        }
        val missingRelationship = manifest.copy(
            meetings = manifest.meetings.mapIndexed { index, meeting ->
                if (index == 0) meeting.copy(participants = meeting.participants.drop(1).toSet()) else meeting
            },
        )
        assertThrows<IllegalArgumentException> {
            validator.validate(missingRelationship, setOf("api.whysoezzy.online"))
        }
    }

    @Test
    fun `media paths must be the exact approved singleton artifact`() {
        val badMedia = BetaDemoCatalog.manifest.copy(
            communities = BetaDemoCatalog.manifest.communities.map {
                it.copy(imageUrl = "${BetaDemoCatalog.MEDIA_BASE}not-approved.png")
            },
        )
        assertThrows<IllegalArgumentException> {
            validator.validate(badMedia, setOf("api.whysoezzy.online"))
        }
    }

    @Test
    fun `landing paths must be the exact approved public pages`() {
        val badLanding = BetaDemoCatalog.manifest.copy(
            meetings = BetaDemoCatalog.manifest.meetings.map {
                if (it.externalUrl != null) {
                    it.copy(externalUrl = "https://api.whysoezzy.online/demo-events/not-approved")
                } else {
                    it
                }
            },
        )
        assertThrows<IllegalArgumentException> {
            validator.validate(badLanding, setOf("api.whysoezzy.online"))
        }
    }

    @Test
    fun `key and reference rules are enforced`() {
        val bad = BetaDemoCatalog.manifest.copy(
            users = BetaDemoCatalog.manifest.users.drop(1),
        )
        assertThrows<IllegalArgumentException> {
            validator.validate(bad, setOf("api.whysoezzy.online"))
        }
    }
}
