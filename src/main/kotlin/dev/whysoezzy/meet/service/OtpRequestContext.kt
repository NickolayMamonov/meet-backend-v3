package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.service.auth.identifier.DeviceId
import dev.whysoezzy.meet.service.auth.identifier.NormalizedIp

data class OtpRequestContext(
    val clientIp: NormalizedIp?,
    val deviceId: DeviceId?,
) {
    companion object {
        val EMPTY = OtpRequestContext(clientIp = null, deviceId = null)
    }
}
