package dev.whysoezzy.meet.integration

import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.content
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status

class DemoCatalogPublicAssetsMvcTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var mockMvc: MockMvc

    @BeforeEach
    fun clear() = resetDatabase()

    @Test
    fun `exact public assets are anonymous and typed`() {
        mockMvc.perform(get("/demo-assets/v1/community-moscow.png"))
            .andExpect(status().isOk)
            .andExpect(content().contentType(MediaType.IMAGE_PNG))
        mockMvc.perform(get("/demo-events/organize-online"))
            .andExpect(status().isOk)
            .andExpect(content().contentTypeCompatibleWith(MediaType.TEXT_HTML))
    }
}
