package dev.whysoezzy.meet.api.dto

data class IngestTriggerResponse(
    val runs: List<IngestRunSummary>,
    val purgedPast: Int = 0,
)

data class IngestRunSummary(
    val source: String,
    val status: String,
    val fetched: Int,
    val created: Int,
    val updated: Int,
    val skipped: Int,
    val errorMessage: String?,
)