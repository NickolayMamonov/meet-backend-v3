package dev.whysoezzy.meet.api

import dev.whysoezzy.meet.api.controller.AdminPushController
import dev.whysoezzy.meet.api.dto.PushDiagnosticMode as RequestMode
import dev.whysoezzy.meet.api.dto.PushDiagnosticRequest
import dev.whysoezzy.meet.api.error.BadRequestException
import dev.whysoezzy.meet.service.push.DiagnosticCallResult
import dev.whysoezzy.meet.service.push.DiagnosticAggregateResult
import dev.whysoezzy.meet.service.push.PushDiagnosticResponse
import dev.whysoezzy.meet.service.push.PushDiagnosticService
import jakarta.servlet.http.HttpServletRequest
import org.junit.jupiter.api.Test
import org.mockito.Mockito
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class PushDiagnosticControllerMvcTest {
    private val service = Mockito.mock(PushDiagnosticService::class.java)
    private val controller = AdminPushController(service)
    private val request = Mockito.mock(HttpServletRequest::class.java)
    private val installationId = "123e4567-e89b-12d3-a456-426614174000"

    @Test
    fun `diagnostic maps accepted single and dedup pair results to safe response categories`() {
        Mockito.`when`(request.parameterMap).thenReturn(emptyMap())
        val singleCommand = dev.whysoezzy.meet.service.push.PushDiagnosticCommand(
            7,
            java.util.UUID.fromString(installationId),
            42,
            60,
            dev.whysoezzy.meet.service.push.PushDiagnosticMode.SINGLE,
        )
        Mockito.`when`(service.send(singleCommand)).thenReturn(
            PushDiagnosticResponse.Single(DiagnosticCallResult.Accepted),
        )
        val single = controller.diagnostic(
            PushDiagnosticRequest(7, installationId, 42, 60, RequestMode.SINGLE),
            request,
        )
        @Suppress("UNCHECKED_CAST")
        val singleBody = single.body!! as Map<String, String>
        assertEquals("ACCEPTED", singleBody["result"])

        val pairCommand = singleCommand.copy(mode = dev.whysoezzy.meet.service.push.PushDiagnosticMode.DEDUP_PAIR)
        Mockito.`when`(service.send(pairCommand)).thenReturn(
            PushDiagnosticResponse.Pair(
                DiagnosticAggregateResult.ACCEPTED_PAIR,
                DiagnosticCallResult.Accepted,
                DiagnosticCallResult.Accepted,
            ),
        )
        val pair = controller.diagnostic(
            PushDiagnosticRequest(7, installationId, 42, 60, RequestMode.DEDUP_PAIR),
            request,
        )
        @Suppress("UNCHECKED_CAST")
        val pairBody = pair.body!! as Map<String, String>
        assertEquals("ACCEPTED_PAIR", pairBody["result"])
        assertEquals("ACCEPTED", pairBody["first"])
        assertEquals("ACCEPTED", pairBody["second"])
    }

    @Test
    fun `diagnostic rejects query targeting and noncanonical request values`() {
        Mockito.`when`(request.parameterMap).thenReturn(mapOf("topic" to arrayOf("all")))
        assertFailsWith<BadRequestException> {
            controller.diagnostic(
                PushDiagnosticRequest(7, installationId, 42, 60, RequestMode.SINGLE),
                request,
            )
        }

        Mockito.`when`(request.parameterMap).thenReturn(emptyMap())
        listOf(
            PushDiagnosticRequest(0, installationId, 42, 60, RequestMode.SINGLE),
            PushDiagnosticRequest(7, installationId.uppercase(), 42, 60, RequestMode.SINGLE),
            PushDiagnosticRequest(7, installationId, 42, 30, RequestMode.SINGLE),
        ).forEach { invalid ->
            assertFailsWith<BadRequestException> { controller.diagnostic(invalid, request) }
        }
    }
}
