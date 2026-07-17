package dev.whysoezzy.meet.config

import jakarta.validation.constraints.NotBlank
import org.springframework.boot.context.properties.ConfigurationProperties
import org.springframework.validation.annotation.Validated

@Validated
@ConfigurationProperties(prefix = "app.admin")
data class AdminProperties(
    @field:NotBlank(message = "app.admin.api-key must be provided")
    val apiKey: String = "",
) {
    init {
        require(apiKey.isNotBlank()) {
            "app.admin.api-key must be provided"
        }
    }
}
