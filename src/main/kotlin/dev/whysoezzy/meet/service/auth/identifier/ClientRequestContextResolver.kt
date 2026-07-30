package dev.whysoezzy.meet.service.auth.identifier

import dev.whysoezzy.meet.config.ClientIpProperties
import dev.whysoezzy.meet.service.OtpRequestContext
import jakarta.servlet.http.HttpServletRequest
import org.springframework.stereotype.Component

@Component
class ClientRequestContextResolver(
    properties: ClientIpProperties,
) {
    private val trustedProxies = TrustedProxySet.from(properties.trustedProxyCidrs)
    private val maxForwardedHops = properties.maxForwardedHops

    fun resolve(request: HttpServletRequest, deviceId: DeviceId?): OtpRequestContext =
        OtpRequestContext(
            clientIp = resolveIp(request),
            deviceId = deviceId,
        )

    private fun resolveIp(request: HttpServletRequest): NormalizedIp? {
        val remote = IpLiteralParser.parse(request.remoteAddr) ?: return null
        if (!trustedProxies.contains(remote)) {
            return remote
        }

        val forwarded = request.getHeader("X-Forwarded-For") ?: return remote
        val parts = forwarded.split(',').map(String::trim)
        if (parts.isEmpty() || parts.size > maxForwardedHops) {
            return remote
        }
        val chain = parts.map { IpLiteralParser.parse(it) ?: return remote } + remote
        for (index in chain.lastIndex downTo 0) {
            val candidate = chain[index]
            if (!trustedProxies.contains(candidate) || index == 0) {
                return candidate
            }
        }
        return remote
    }
}
