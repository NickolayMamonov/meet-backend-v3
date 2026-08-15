package dev.whysoezzy.meet.integration

import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.content
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user

class DemoCatalogPublicAssetsMvcTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var mockMvc: MockMvc

    @BeforeEach
    fun clear() = resetDatabase()

    @Test
    fun `all thirteen exact public assets are anonymous and typed`() {
        listOf(
            "community-moscow.png",
            "community-walks.png",
            "community-online.png",
            "meeting-moscow.png",
            "meeting-online.png",
            "avatar-01.png",
            "avatar-02.png",
            "avatar-03.png",
            "avatar-04.png",
            "avatar-05.png",
            "avatar-06.png",
        ).forEach { filename ->
            mockMvc.perform(get("/demo-assets/v1/$filename"))
                .andExpect(status().isOk)
                .andExpect(content().contentType(MediaType.IMAGE_PNG))
        }
        listOf("organize-online", "networking-online").forEach { page ->
            mockMvc.perform(get("/demo-events/$page"))
                .andExpect(status().isOk)
                .andExpect(content().contentTypeCompatibleWith(MediaType.TEXT_HTML))
        }
    }

    @Test
    fun `nearby public resource paths return not found`() {
        mockMvc.perform(get("/demo-assets/v1/not-approved.png").with(user("tester")))
            .andExpect(status().isNotFound)
        mockMvc.perform(get("/demo-events/not-approved").with(user("tester")))
            .andExpect(status().isNotFound)
    }
}
