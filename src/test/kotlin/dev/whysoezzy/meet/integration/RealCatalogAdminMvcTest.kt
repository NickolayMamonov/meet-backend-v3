package dev.whysoezzy.meet.integration

import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.http.MediaType
import org.springframework.test.context.TestPropertySource
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import kotlin.test.assertTrue

@TestPropertySource(
    properties = [
        "app.real-catalog.enabled=true",
        "app.real-catalog.target-environment=test-admin",
        "app.real-catalog.approved-media-hosts=example.test",
    ],
)
class RealCatalogAdminMvcTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var mockMvc: MockMvc

    @BeforeEach
    fun clear() = resetDatabase()

    @Test
    fun `admin key remains required and malformed preview is bounded`() {
        mockMvc.perform(
            post("/admin/real-catalog/preview")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"revision":"missing","digest":"not-a-digest"}"""),
        ).andExpect(status().isForbidden)

        mockMvc.perform(
            post("/admin/real-catalog/preview")
                .header("X-Admin-Key", "test-only-admin-key")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"revision":"missing","digest":"not-a-digest"}"""),
        ).andExpect(status().isBadRequest)

        val oversized = buildString {
            append("""{"revision":"missing","digest":"not-a-digest","padding":"""")
            append("x".repeat(20_000))
            append(""""}""")
        }
        val response = mockMvc.perform(
            post("/admin/real-catalog/preview")
                .header("X-Admin-Key", "test-only-admin-key")
                .contentType(MediaType.APPLICATION_JSON)
                .content(oversized),
        ).andExpect(status().isPayloadTooLarge)
            .andReturn()
        assertTrue(response.response.contentAsString.contains("PAYLOAD_TOO_LARGE"))
    }
}
