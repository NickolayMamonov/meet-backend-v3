package dev.whysoezzy.meet.api.dto

enum class PushDiagnosticMode {
    SINGLE,
    DEDUP_PAIR,
}

data class PushDiagnosticRequest(
    val userId: Long,
    val installationId: String,
    val meetingId: Long,
    val reminderOffsetMinutes: Int,
    val mode: PushDiagnosticMode,
)

data class PushDiagnosticResponse(
    val result: String,
    val first: String? = null,
    val second: String? = null,
)
