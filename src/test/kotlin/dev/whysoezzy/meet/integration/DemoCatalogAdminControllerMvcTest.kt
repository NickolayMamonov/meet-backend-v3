package dev.whysoezzy.meet.integration

import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status

class DemoCatalogAdminControllerMvcTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var mockMvc: MockMvc

    @BeforeEach
    fun clear() = resetDatabase()

    @Test
    fun `authenticated admin route is absent while bootstrap is disabled`() {
        mockMvc.perform(
            post("/admin/demo-catalog/bootstrap")
                .header("X-Admin-Key", "test-only-admin-key")
                .contentType("application/json")
                .content("""{"scheduleAnchorDate":"2099-01-01","catalogValidThrough":"2098-12-01T00:00:00Z"}"""),
        ).andExpect(status().isNotFound)
    }

    @Test
    fun `missing admin key is rejected before routing`() {
        mockMvc.perform(
            post("/admin/demo-catalog/bootstrap")
                .contentType("application/json")
                .content("""{"scheduleAnchorDate":"2099-01-01","catalogValidThrough":"2098-12-01T00:00:00Z"}"""),
        ).andExpect(status().isForbidden)
    }
}
