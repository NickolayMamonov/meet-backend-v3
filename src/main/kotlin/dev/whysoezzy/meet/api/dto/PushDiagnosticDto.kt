package dev.whysoezzy.meet.api.dto

import java.util.UUID

enum class PushDiagnosticMode {
    SINGLE,
    DEDUP_PAIR,
}

data class PushDiagnosticRequest(
    val userId: Long,
    val installationId: UUID,
    val meetingId: Long,
    val reminderOffsetMinutes: Int,
    val mode: PushDiagnosticMode,
)

data class PushDiagnosticResponse(
    val result: String,
    val first: String? = null,
    val second: String? = null,
)
