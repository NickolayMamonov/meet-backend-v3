package dev.whysoezzy.meet.service.auth.identifier

import dev.whysoezzy.meet.config.ClientIpProperties
import org.junit.jupiter.api.Test
import org.springframework.mock.web.MockHttpServletRequest
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ClientRequestContextResolverTest {
    @Test
    fun `ignores spoofed forwarding headers from an untrusted peer`() {
        val request = MockHttpServletRequest().apply {
            remoteAddr = "198.51.100.7"
            addHeader("X-Forwarded-For", "203.0.113.9")
        }

        val context = ClientRequestContextResolver(ClientIpProperties()).resolve(request, null)

        assertEquals("198.51.100.7", context.clientIp?.value)
    }

    @Test
    fun `walks a trusted proxy chain from right to left`() {
        val request = MockHttpServletRequest().apply {
            remoteAddr = "10.0.0.1"
            addHeader("X-Forwarded-For", "203.0.113.9, 10.0.0.2")
        }
        val resolver = ClientRequestContextResolver(
            ClientIpProperties(trustedProxyCidrs = listOf("10.0.0.0/8")),
        )

        assertEquals("203.0.113.9", resolver.resolve(request, null).clientIp?.value)
    }

    @Test
    fun `falls back for malformed or excessive chains without resolving hostnames`() {
        val resolver = ClientRequestContextResolver(
            ClientIpProperties(
                trustedProxyCidrs = listOf("10.0.0.0/8"),
                maxForwardedHops = 2,
            ),
        )
        val malformed = MockHttpServletRequest().apply {
            remoteAddr = "10.0.0.1"
            addHeader("X-Forwarded-For", "not-a-host")
        }
        val excessive = MockHttpServletRequest().apply {
            remoteAddr = "10.0.0.1"
            addHeader("X-Forwarded-For", "203.0.113.1, 203.0.113.2, 203.0.113.3")
        }

        assertEquals("10.0.0.1", resolver.resolve(malformed, null).clientIp?.value)
        assertEquals("10.0.0.1", resolver.resolve(excessive, null).clientIp?.value)
        assertNull(IpLiteralParser.parse("example.com"))
        assertNull(IpLiteralParser.parse("fe80::1%eth0"))
        assertEquals("2001:db8:0:0:0:0:0:1", IpLiteralParser.parse("2001:db8::1")?.value)
    }
}
