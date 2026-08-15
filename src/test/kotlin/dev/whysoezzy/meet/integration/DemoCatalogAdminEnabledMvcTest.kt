package dev.whysoezzy.meet.integration

import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.test.context.TestPropertySource
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
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
            .andExpect(jsonPath("$.catalogName").value("closed-beta-demo"))
            .andExpect(jsonPath("$.roots.tags.created").value(6))
            .andExpect(jsonPath("$.relationships.meetingParticipants.added").value(18))
    }
}
