package dev.whysoezzy.meet.integration

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.jayway.jsonpath.JsonPath
import dev.whysoezzy.meet.domain.entity.AuthIdentity
import dev.whysoezzy.meet.domain.entity.AuthIdentityType
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.AuthIdentityRepository
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import dev.whysoezzy.meet.service.auth.otp.ActivationOutcome
import dev.whysoezzy.meet.service.auth.otp.OtpChallengeLifecycle
import dev.whysoezzy.meet.service.auth.otp.OtpHasher
import dev.whysoezzy.meet.service.auth.otp.SensitiveOtpCode
import dev.whysoezzy.meet.service.email.EmailOtpMessage
import dev.whysoezzy.meet.service.email.EmailOtpSender
import dev.whysoezzy.meet.service.sms.SmsSender
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mockingDetails
import org.mockito.Mockito.reset
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.mock.mockito.MockBean
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.header
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import java.util.Base64
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ApiMvcIntegrationTest(
    @Autowired private val mockMvc: MockMvc,
    @Autowired private val identities: AuthIdentityRepository,
    @Autowired private val hasher: OtpHasher,
    @Autowired private val lifecycle: OtpChallengeLifecycle,
) : IntegrationTestSupport() {
    @MockBean
    private lateinit var emailSender: EmailOtpSender

    @MockBean
    private lateinit var smsSender: SmsSender

    @BeforeEach
    fun setUp() {
        resetDatabase()
        reset(emailSender, smsSender)
    }

    @Test
    fun `phone send success activates HMAC challenge and preserves exact wire response`() {
        mockMvc.perform(
            post("/auth/send-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"phone":"+15550000088"}"""),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.message").value("OTP sent successfully"))

        val delivery = mockingDetails(smsSender).invocations.single()
        assertEquals("+15550000088", delivery.arguments[0])
        val code = delivery.arguments[1] as String
        assertTrue(code.matches(Regex("^[0-9]{6}$")))
        assertEquals(
            "ACTIVE",
            jdbcTemplate.queryForObject(
                "SELECT status FROM otp_codes WHERE channel = 'PHONE' AND identifier = '+15550000088'",
                String::class.java,
            ),
        )

        val response = mockMvc.perform(
            post("/auth/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"phone":"+15550000088","code":"$code"}"""),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.isNewUser").value(true))
            .andExpect(jsonPath("$.user.phone").value("+15550000088"))
            .andReturn()
            .response
            .contentAsString
        assertEquals(
            "+15550000088",
            jwtPayload(JsonPath.read(response, "$.accessToken")).path("phone").asText(),
        )

        mockMvc.perform(
            post("/auth/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"phone":"+15550000088","code":"$code"}"""),
        )
            .andExpect(status().isUnauthorized)
            .andExpect(jsonPath("$.code").value("UNAUTHORIZED"))
            .andExpect(jsonPath("$.message").value("Invalid or expired OTP code"))
            .andExpect(header().doesNotExist("Retry-After"))
    }

    @Test
    fun `phone wrong expired and exhausted challenges preserve the frozen HTTP response`() {
        val cases = listOf(
            Triple("+15550000091", "111111", "wrong"),
            Triple("+15550000092", "222222", "expired"),
            Triple("+15550000093", "333333", "exhausted"),
        )
        cases.forEach { (phone, code, state) ->
            activate(AuthIdentifier.phone(phone), code)
            when (state) {
                "expired" -> jdbcTemplate.update(
                    """
                    UPDATE otp_codes
                    SET expires_at = clock_timestamp() - INTERVAL '1 second'
                    WHERE channel = 'PHONE' AND identifier = ?
                    """.trimIndent(),
                    phone,
                )
                "exhausted" -> jdbcTemplate.update(
                    """
                    UPDATE otp_codes
                    SET status = 'EXHAUSTED', failed_attempts = max_attempts
                    WHERE channel = 'PHONE' AND identifier = ?
                    """.trimIndent(),
                    phone,
                )
            }
            val submittedCode = if (state == "wrong") "999999" else code

            mockMvc.perform(
                post("/auth/verify-otp")
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("""{"phone":"$phone","code":"$submittedCode"}"""),
            )
                .andExpect(status().isUnauthorized)
                .andExpect(jsonPath("$.status").value(401))
                .andExpect(jsonPath("$.code").value("UNAUTHORIZED"))
                .andExpect(jsonPath("$.message").value("Invalid or expired OTP code"))
                .andExpect(jsonPath("$.path").value("/auth/verify-otp"))
                .andExpect(header().doesNotExist("Retry-After"))
        }
    }

    @Test
    fun `delete restore logout and auth version invalidation remain monotonic for email identities`() {
        val initialCode = requestEmailCode("restore@example.com")
        val initial = mockMvc.perform(
            post("/auth/email/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"email":"restore@example.com","code":"$initialCode"}"""),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.isNewUser").value(true))
            .andReturn()
            .response
            .contentAsString
        val userId = JsonPath.read<Int>(initial, "$.user.id").toLong()
        val oldAccess = JsonPath.read<String>(initial, "$.accessToken")
        val oldRefresh = JsonPath.read<String>(initial, "$.refreshToken")

        mockMvc.perform(delete("/profile").bearer(oldAccess))
            .andExpect(status().isOk)
        val deleted = users.findById(userId).orElseThrow()
        val deletedAuthVersion = deleted.authVersion
        assertTrue(deleted.isDeleted)
        assertEquals(1L, deletedAuthVersion)

        mockMvc.perform(get("/profile").bearer(oldAccess))
            .andExpect(status().isUnauthorized)
        mockMvc.perform(
            post("/auth/refresh")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"refreshToken":"$oldRefresh"}"""),
        ).andExpect(status().isUnauthorized)

        val restoreCode = requestEmailCode("restore@example.com")
        val restoredResponse = mockMvc.perform(
            post("/auth/email/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"email":"restore@example.com","code":"$restoreCode"}"""),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.isNewUser").value(false))
            .andExpect(jsonPath("$.user.id").value(userId))
            .andReturn()
            .response
            .contentAsString
        val restoredAccess = JsonPath.read<String>(restoredResponse, "$.accessToken")
        val restoredRefresh = JsonPath.read<String>(restoredResponse, "$.refreshToken")
        val restored = users.findById(userId).orElseThrow()
        assertFalse(restored.isDeleted)
        assertEquals(deletedAuthVersion, restored.authVersion)

        mockMvc.perform(post("/auth/logout").bearer(restoredAccess))
            .andExpect(status().isOk)
        assertEquals(deletedAuthVersion + 1, users.findById(userId).orElseThrow().authVersion)
        mockMvc.perform(
            post("/auth/refresh")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"refreshToken":"$restoredRefresh"}"""),
        ).andExpect(status().isUnauthorized)
    }

    @Test
    fun `phone auth refresh and profile behavior remain compatible over the unified store`() {
        val data = fixture()
        data.alice.showCommunities = false
        data.alice.showMeetings = false
        data.alice.notificationsEnabled = false
        users.save(data.alice)
        activatePhone(data.alice, "123456")

        val authResponse = mockMvc.perform(
            post("/auth/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"phone":"+15550000001","code":"123456"}"""),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.isNewUser").value(false))
            .andExpect(jsonPath("$.user.id").value(data.alice.id))
            .andExpect(jsonPath("$.user.interests").isEmpty)
            .andExpect(jsonPath("$.user.showCommunities").value(true))
            .andExpect(jsonPath("$.user.showMeetings").value(true))
            .andExpect(jsonPath("$.user.notificationsEnabled").value(true))
            .andReturn()
            .response
            .contentAsString
        val accessToken = JsonPath.read<String>(authResponse, "$.accessToken")
        val refreshToken = JsonPath.read<String>(authResponse, "$.refreshToken")
        assertEquals("+15550000001", jwtPayload(accessToken).path("phone").asText())

        mockMvc.perform(get("/profile").bearer(accessToken))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.email").value("alice@example.test"))
            .andExpect(jsonPath("$.interests[0].text").value("Kotlin"))
            .andExpect(jsonPath("$.showCommunities").value(false))
            .andExpect(jsonPath("$.showMeetings").value(false))
            .andExpect(jsonPath("$.notificationsEnabled").value(false))

        mockMvc.perform(
            put("/profile")
                .bearer(accessToken)
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    """{"city":"Saint Petersburg","description":"Platform engineer","interestIds":[${data.kotlin.id}]}""",
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

        val saved = users.findById(requireNotNull(data.alice.id)).orElseThrow()
        assertEquals("fcm-device-token", saved.fcmToken)
        assertFalse(saved.showMeetings)
    }

    @Test
    fun `real email flow commits failed counters then refreshes logs out and deletes`() {
        val code = requestEmailCode("Person@Example.COM")

        val row = jdbcTemplate.queryForMap(
            """
            SELECT identifier, code_hash, hash_salt, status
            FROM otp_codes
            WHERE channel = 'EMAIL'
            """.trimIndent(),
        )
        assertEquals("person@example.com", row["identifier"])
        assertEquals("ACTIVE", row["status"])
        assertEquals(32, (row["code_hash"] as ByteArray).size)
        assertEquals(16, (row["hash_salt"] as ByteArray).size)
        assertFalse(row.values.any { it == code })

        val wrongCode = if (code == "000000") "000001" else "000000"
        mockMvc.perform(
            post("/auth/email/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"email":"person@example.com","code":"$wrongCode"}"""),
        )
            .andExpect(status().isUnauthorized)
            .andExpect(jsonPath("$.code").value("OTP_INVALID_OR_EXPIRED"))
            .andExpect(jsonPath("$.message").value("Invalid or expired OTP code."))
            .andExpect(header().doesNotExist("Retry-After"))
        assertEquals(
            1,
            jdbcTemplate.queryForObject(
                """
                SELECT failed_attempts
                FROM otp_codes
                WHERE channel = 'EMAIL' AND identifier = 'person@example.com'
                """.trimIndent(),
                Int::class.java,
            ),
        )
        assertEquals(
            1L,
            jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM otp_rate_limit_attempts WHERE scope = 'verify_email'",
                Long::class.java,
            ),
        )

        val response = mockMvc.perform(
            post("/auth/email/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"email":"person@example.com","code":"$code","name":"Email","surname":"User"}"""),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.isNewUser").value(true))
            .andExpect(jsonPath("$.user.email").value("person@example.com"))
            .andExpect(jsonPath("$.user.phone").doesNotExist())
            .andReturn()
            .response
            .contentAsString
        val accessToken = JsonPath.read<String>(response, "$.accessToken")
        val refreshToken = JsonPath.read<String>(response, "$.refreshToken")
        val payload = jwtPayload(accessToken)
        assertFalse(payload.has("phone"))
        assertFalse(payload.has("email"))

        val userId = payload.path("sub").asLong()
        val user = users.findById(userId).orElseThrow()
        assertNull(user.phone)
        assertEquals("person@example.com", user.email)
        assertEquals(
            userId,
            identities.findByTypeAndNormalizedIdentifier(
                AuthIdentityType.EMAIL,
                "person@example.com",
            )?.user?.id,
        )

        val refreshResponse = mockMvc.perform(
            post("/auth/refresh")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"refreshToken":"$refreshToken"}"""),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.accessToken").isNotEmpty)
            .andExpect(jsonPath("$.refreshToken").isNotEmpty)
            .andReturn()
            .response
            .contentAsString
        val rotatedAccess = JsonPath.read<String>(refreshResponse, "$.accessToken")
        val rotatedRefresh = JsonPath.read<String>(refreshResponse, "$.refreshToken")

        mockMvc.perform(post("/auth/logout").bearer(rotatedAccess))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.message").value("Logged out successfully"))
        mockMvc.perform(
            post("/auth/refresh")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"refreshToken":"$rotatedRefresh"}"""),
        ).andExpect(status().isUnauthorized)

        val deleteCode = requestEmailCode("person@example.com")
        val deleteAuth = mockMvc.perform(
            post("/auth/email/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"email":"person@example.com","code":"$deleteCode"}"""),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.isNewUser").value(false))
            .andReturn()
            .response
            .contentAsString
        val deleteAccess = JsonPath.read<String>(deleteAuth, "$.accessToken")
        mockMvc.perform(delete("/profile").bearer(deleteAccess))
            .andExpect(status().isOk)
        val deletedUser = users.findById(userId).orElseThrow()
        assertTrue(deletedUser.isDeleted)
        assertEquals(2L, deletedUser.authVersion)

        mockMvc.perform(
            post("/auth/email/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"email":"person@example.com","code":"$code"}"""),
        )
            .andExpect(status().isUnauthorized)
            .andExpect(jsonPath("$.code").value("OTP_INVALID_OR_EXPIRED"))
    }

    @Test
    fun `profile email without an auth identity never selects that account`() {
        val legacy = users.save(
            User("Legacy", "Profile", "+15550000077", email = "profile@example.com"),
        )
        val code = requestEmailCode("profile@example.com")

        val response = mockMvc.perform(
            post("/auth/email/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"email":"profile@example.com","code":"$code"}"""),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.isNewUser").value(true))
            .andReturn()
            .response
            .contentAsString
        val authenticatedId = JsonPath.read<Int>(response, "$.user.id").toLong()

        assertNotEquals(legacy.id, authenticatedId)
        assertEquals(2L, users.count())
    }

    @Test
    fun `meeting and community endpoints retain authenticated behavior`() {
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

    private fun tokenFor(user: User): String {
        activatePhone(user, "123456")
        val body = mockMvc.perform(
            post("/auth/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"phone":"${user.phone}","code":"123456"}"""),
        ).andExpect(status().isOk).andReturn().response.contentAsString
        return JsonPath.read(body, "$.accessToken")
    }

    private fun activatePhone(user: User, code: String) {
        val identifier = AuthIdentifier.phone(requireNotNull(user.phone))
        identities.save(
            AuthIdentity(
                user = user,
                type = AuthIdentityType.PHONE,
                normalizedIdentifier = identifier.canonicalValue,
            ),
        )
        activate(identifier, code)
    }

    private fun activate(identifier: AuthIdentifier, code: String) {
        val sensitiveCode = SensitiveOtpCode.validated(code)
        val pending = lifecycle.createPending(identifier, hasher.hash(identifier, sensitiveCode))
        assertEquals(ActivationOutcome.Activated, lifecycle.activate(pending.id))
    }

    private fun requestEmailCode(email: String): String {
        mockMvc.perform(
            post("/auth/email/send-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content(jacksonObjectMapper().writeValueAsString(mapOf("email" to email))),
        )
            .andExpect(status().isAccepted)
            .andExpect(
                jsonPath("$.message").value(
                    "If the address can receive email, a verification code will be sent.",
                ),
            )
        val message = mockingDetails(emailSender).invocations.last().arguments.single() as EmailOtpMessage
        return message.code
    }

    private fun jwtPayload(token: String) =
        jacksonObjectMapper().readTree(
            Base64.getUrlDecoder().decode(token.split('.')[1]),
        )

    private fun org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder.bearer(token: String) =
        header("Authorization", "Bearer $token")
}
