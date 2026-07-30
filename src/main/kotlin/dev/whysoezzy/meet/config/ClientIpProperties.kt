package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties(prefix = "app.http.client-ip")
data class ClientIpProperties(
    val trustedProxyCidrs: List<String> = emptyList(),
    val maxForwardedHops: Int = 10,
) {
    init {
        require(maxForwardedHops in 1..100) {
            "app.http.client-ip.max-forwarded-hops must be between 1 and 100"
        }
    }
}
