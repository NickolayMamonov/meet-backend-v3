package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.error.BadRequestException
import dev.whysoezzy.meet.api.dto.PushDiagnosticRequest
import dev.whysoezzy.meet.service.push.PushDiagnosticCommand
import dev.whysoezzy.meet.service.push.PushDiagnosticMode
import dev.whysoezzy.meet.service.push.PushDiagnosticResponse
import dev.whysoezzy.meet.service.push.PushDiagnosticService
import dev.whysoezzy.meet.service.push.DiagnosticPushCondition
import jakarta.servlet.http.HttpServletRequest
import org.springframework.context.annotation.Conditional
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController
import java.util.UUID

@RestController
@RequestMapping("/admin/push")
@Conditional(DiagnosticPushCondition::class)
class AdminPushController(
    private val diagnosticService: PushDiagnosticService,
) {
    @PostMapping("/diagnostic")
    fun diagnostic(
        @RequestBody request: PushDiagnosticRequest,
        servletRequest: HttpServletRequest,
    ): ResponseEntity<Any> {
        if (!servletRequest.parameterMap.isNullOrEmpty()) {
            throw BadRequestException("Query parameters are not supported")
        }

        if (request.userId <= 0 || request.meetingId <= 0) {
            throw BadRequestException("Invalid diagnostic target")
        }
        if (request.reminderOffsetMinutes != 60 && request.reminderOffsetMinutes != 1_440) {
            throw BadRequestException("Invalid reminder offset")
        }
        if (request.installationId.toString() != request.installationId.toString().lowercase()) {
            throw BadRequestException("Invalid installation id")
        }
        val mode = when (request.mode.name) {
            "SINGLE" -> PushDiagnosticMode.SINGLE
            "DEDUP_PAIR" -> PushDiagnosticMode.DEDUP_PAIR
            else -> throw BadRequestException("Invalid diagnostic mode")
        }

        val command = PushDiagnosticCommand(
            userId = request.userId,
            installationId = request.installationId,
            meetingId = request.meetingId,
            reminderOffsetMinutes = request.reminderOffsetMinutes,
            mode = mode,
        )

        return when (val response = diagnosticService.send(command)) {
            is PushDiagnosticResponse.Single -> ResponseEntity.ok(
                mapOf("result" to response.result.asName()),
            )
            is PushDiagnosticResponse.Pair -> ResponseEntity.ok(
                mapOf(
                    "result" to response.result.name,
                    "first" to response.first.asName(),
                    "second" to response.second.asName(),
                ),
            )
        }
    }

    private fun dev.whysoezzy.meet.service.push.DiagnosticCallResult.asName(): String =
        when (this) {
            dev.whysoezzy.meet.service.push.DiagnosticCallResult.Accepted -> "ACCEPTED"
            dev.whysoezzy.meet.service.push.DiagnosticCallResult.InvalidTarget -> "INVALID_TARGET"
            dev.whysoezzy.meet.service.push.DiagnosticCallResult.RetryableFailure -> "RETRYABLE_FAILURE"
            dev.whysoezzy.meet.service.push.DiagnosticCallResult.ProviderUnavailable -> "PROVIDER_UNAVAILABLE"
            dev.whysoezzy.meet.service.push.DiagnosticCallResult.NotAttempted -> "NOT_ATTEMPTED"
        }
}
