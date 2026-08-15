package dev.whysoezzy.meet.integration

import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.test.context.TestPropertySource
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.content
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status

@TestPropertySource(properties = ["app.demo-catalog.bootstrap-enabled=true"])
class DemoCatalogAdminEnabledMvcTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var mockMvc: MockMvc

    @BeforeEach
    fun clear() = resetDatabase()

    @Test
    fun `enabled admin returns safe typed summary`() {
        mockMvc.perform(
            post("/admin/demo-catalog/bootstrap")
                .header("X-Admin-Key", "test-only-admin-key")
                .contentType("application/json")
                .content("""{"scheduleAnchorDate":"2099-01-01","catalogValidThrough":"2098-12-01T00:00:00Z"}"""),
        )
            .andExpect(status().isOk)
            .andExpect(
                content().json(
                    """
                    {
                      "catalogName":"closed-beta-demo",
                      "manifestVersion":"2026-08-15.v1",
                      "scheduleAnchorDate":"2099-01-01",
                      "catalogValidThrough":"2098-12-01T00:00:00Z",
                      "roots":{
                        "tags":{"created":6,"updated":0,"unchanged":0},
                        "users":{"created":6,"updated":0,"unchanged":0},
                        "communities":{"created":3,"updated":0,"unchanged":0},
                        "meetings":{"created":6,"updated":0,"unchanged":0},
                        "adBlocks":{"created":3,"updated":0,"unchanged":0}
                      },
                      "relationships":{
                        "userInterests":{"added":12,"removed":0,"unchanged":0},
                        "communityTags":{"added":7,"removed":0,"unchanged":0},
                        "communitySubscribers":{"added":9,"removed":0,"unchanged":0},
                        "meetingTags":{"added":12,"removed":0,"unchanged":0},
                        "meetingParticipants":{"added":18,"removed":0,"unchanged":0},
                        "meetingPersonHosts":{"added":6,"removed":0,"unchanged":0},
                        "meetingCommunityHosts":{"added":6,"removed":0,"unchanged":0},
                        "adBlockCommunities":{"added":3,"removed":0,"unchanged":0},
                        "adBlockUsers":{"added":4,"removed":0,"unchanged":0}
                      }
                    }
                    """.trimIndent(),
                    true,
                ),
            )
    }
}
