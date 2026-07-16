package dev.whysoezzy.meet.config

import jakarta.validation.constraints.Max
import jakarta.validation.constraints.Min
import jakarta.validation.constraints.NotBlank
import org.springframework.boot.context.properties.ConfigurationProperties
import org.springframework.validation.annotation.Validated
import java.nio.charset.StandardCharsets

@Validated
@ConfigurationProperties(prefix = "app.jwt")
data class JwtProperties(
    @field:NotBlank(message = "app.jwt.secret must be provided")
    val secret: String = "",
    @field:Min(value = 60_000, message = "app.jwt.access-token-expiration-ms must be at least one minute")
    @field:Max(value = 86_400_000, message = "app.jwt.access-token-expiration-ms must not exceed one day")
    val accessTokenExpirationMs: Long = 900_000,
    @field:Min(value = 1, message = "app.jwt.refresh-token-expiration-days must be positive")
    val refreshTokenExpirationDays: Long = 30,
) {
    init {
        require(secret.toByteArray(StandardCharsets.UTF_8).size >= MINIMUM_SECRET_BYTES) {
            "app.jwt.secret must contain at least $MINIMUM_SECRET_BYTES UTF-8 bytes"
        }
    }

    companion object {
        const val MINIMUM_SECRET_BYTES = 32
    }
}
