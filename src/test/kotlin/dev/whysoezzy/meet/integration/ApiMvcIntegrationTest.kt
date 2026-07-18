package dev.whysoezzy.meet.integration

import com.jayway.jsonpath.JsonPath
import dev.whysoezzy.meet.domain.entity.OtpCode
import dev.whysoezzy.meet.domain.repository.OtpRepository
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import java.time.LocalDateTime
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ApiMvcIntegrationTest(
    @Autowired private val mockMvc: MockMvc,
    @Autowired private val otpCodes: OtpRepository,
) : IntegrationTestSupport() {

    @BeforeEach
    fun setUp() = resetDatabase()

    @Test
    fun `auth and profile endpoints verify OTP refresh JWT and persist profile changes`() {
        val data = fixture()
        otpCodes.save(OtpCode(data.alice.phone, "123456", LocalDateTime.now().plusMinutes(5)))

        val authResponse = mockMvc.perform(
            post("/auth/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"phone":"+15550000001","code":"123456"}"""),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.isNewUser").value(false))
            .andExpect(jsonPath("$.user.id").value(data.alice.id))
            .andReturn()
            .response
            .contentAsString
        val accessToken = JsonPath.read<String>(authResponse, "$.accessToken")
        val refreshToken = JsonPath.read<String>(authResponse, "$.refreshToken")

        mockMvc.perform(get("/profile").bearer(accessToken))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.email").value("alice@example.test"))

        mockMvc.perform(
            put("/profile")
                .bearer(accessToken)
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    """{"city":"Saint Petersburg","description":"Platform engineer","interestIds":[${data.kotlin.id}],"showMeetings":false}""",
                ),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.city").value("Saint Petersburg"))
            .andExpect(jsonPath("$.showMeetings").value(false))

        mockMvc.perform(
            put("/profile/fcm-token").bearer(accessToken)
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"fcmToken":"fcm-device-token"}"""),
        ).andExpect(status().isOk)

        mockMvc.perform(
            post("/auth/refresh")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"refreshToken":"$refreshToken"}"""),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.accessToken").isNotEmpty)
            .andExpect(jsonPath("$.refreshToken").isNotEmpty)

        val saved = users.findById(data.alice.id!!).orElseThrow()
        assertTrue(saved.fcmToken == "fcm-device-token")
        assertFalse(saved.showMeetings)
    }

    @Test
    fun `meeting and community endpoints expose public data and apply authenticated membership changes`() {
        val data = fixture()
        val token = tokenFor(data.alice)

        mockMvc.perform(get("/profile").bearer(token))
            .andExpect(status().isOk)

        mockMvc.perform(get("/meetings").param("tagId", data.kotlin.id.toString()))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$[0].id").value(data.meeting.id))
            .andExpect(jsonPath("$[0].isUserInParticipants").value(false))
        mockMvc.perform(get("/meetings/search").param("query", "PostgreSQL"))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$[0].title").value("Kotlin testing meetup"))

        mockMvc.perform(post("/meetings/${data.meeting.id}/join").bearer(token))
            .andExpect(status().isOk)
        mockMvc.perform(get("/user/meetings").bearer(token))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$[0].id").value(data.meeting.id))
        mockMvc.perform(delete("/meetings/${data.meeting.id}/leave").bearer(token))
            .andExpect(status().isOk)

        mockMvc.perform(get("/communities/search").param("query", "Kotlin"))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$[0].isSubscribed").value(false))
        mockMvc.perform(post("/communities/${data.community.id}/subscribe").bearer(token))
            .andExpect(status().isOk)
        mockMvc.perform(get("/communities/${data.community.id}").bearer(token))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.isSubscribed").value(true))
        mockMvc.perform(delete("/communities/${data.community.id}/subscribe").bearer(token))
            .andExpect(status().isOk)
    }

    @Test
    fun `tags and ads endpoints serialize repository-backed fixtures`() {
        val data = fixture()

        mockMvc.perform(get("/api/v1/tags"))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.success").value(true))
            .andExpect(jsonPath("$.data[?(@.text == 'Kotlin')]").isNotEmpty)

        mockMvc.perform(get("/api/ads"))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$[?(@.id == ${data.textAd.id})]").isNotEmpty)
        mockMvc.perform(get("/api/ads/${data.textAd.id}"))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.type").value("TEXT"))
        mockMvc.perform(get("/api/ads/${data.communityAd.id}"))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.type").value("COMMUNITIES"))
            .andExpect(jsonPath("$.communities[0].id").value(data.community.id))
    }

    private fun tokenFor(user: dev.whysoezzy.meet.domain.entity.User): String {
        otpCodes.save(OtpCode(user.phone, "123456", LocalDateTime.now().plusMinutes(5)))
        val body = mockMvc.perform(
            post("/auth/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"phone":"${user.phone}","code":"123456"}"""),
        ).andExpect(status().isOk).andReturn().response.contentAsString
        return JsonPath.read(body, "$.accessToken")
    }

    private fun org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder.bearer(token: String) =
        header("Authorization", "Bearer $token")
}
