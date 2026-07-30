package dev.whysoezzy.meet.service.auth.identifier

import java.net.InetAddress

class NormalizedIp private constructor(
    internal val value: String,
    internal val addressBytes: ByteArray,
) {
    override fun toString(): String = "NormalizedIp(redacted)"

    companion object {
        internal fun from(bytes: ByteArray): NormalizedIp {
            val address = InetAddress.getByAddress(bytes)
            return NormalizedIp(address.hostAddress.substringBefore('%'), bytes.copyOf())
        }
    }
}

object IpLiteralParser {
    fun parse(raw: String?): NormalizedIp? {
        val literal = raw?.trim().orEmpty()
        if (literal.isEmpty() || '%' in literal) {
            return null
        }
        val bytes = if (':' in literal) {
            parseIpv6(literal)
        } else {
            parseIpv4(literal)
        } ?: return null
        return NormalizedIp.from(bytes)
    }

    private fun parseIpv4(literal: String): ByteArray? {
        val parts = literal.split('.')
        if (parts.size != 4) {
            return null
        }
        return ByteArray(4) { index ->
            val part = parts[index]
            if (part.isEmpty() || part.length > 3 || part.any { !it.isDigit() }) {
                return null
            }
            val value = part.toIntOrNull() ?: return null
            if (value !in 0..255 || (part.length > 1 && part.startsWith('0'))) {
                return null
            }
            value.toByte()
        }
    }

    private fun parseIpv6(literal: String): ByteArray? {
        if (literal.count { it == ':' } < 2 || literal.countSubstring("::") > 1) {
            return null
        }

        val doubleColon = literal.indexOf("::")
        val leftText = if (doubleColon >= 0) literal.substring(0, doubleColon) else literal
        val rightText = if (doubleColon >= 0) literal.substring(doubleColon + 2) else ""
        val left = parseIpv6Parts(leftText, allowIpv4Tail = doubleColon < 0) ?: return null
        val right = parseIpv6Parts(rightText, allowIpv4Tail = true) ?: return null
        val total = left.size + right.size

        val groups = when {
            doubleColon >= 0 && total < 8 -> left + List(8 - total) { 0 } + right
            doubleColon < 0 && total == 8 -> left
            else -> return null
        }

        return ByteArray(16).also { bytes ->
            groups.forEachIndexed { index, group ->
                bytes[index * 2] = (group ushr 8).toByte()
                bytes[index * 2 + 1] = group.toByte()
            }
        }
    }

    private fun parseIpv6Parts(text: String, allowIpv4Tail: Boolean): List<Int>? {
        if (text.isEmpty()) {
            return emptyList()
        }
        val parts = text.split(':')
        if (parts.any(String::isEmpty)) {
            return null
        }
        val groups = mutableListOf<Int>()
        parts.forEachIndexed { index, part ->
            if ('.' in part) {
                if (!allowIpv4Tail || index != parts.lastIndex) {
                    return null
                }
                val ipv4 = parseIpv4(part) ?: return null
                groups += ((ipv4[0].toInt() and 0xff) shl 8) or (ipv4[1].toInt() and 0xff)
                groups += ((ipv4[2].toInt() and 0xff) shl 8) or (ipv4[3].toInt() and 0xff)
            } else {
                if (part.length !in 1..4 || part.any { it.digitToIntOrNull(16) == null }) {
                    return null
                }
                groups += part.toInt(16)
            }
        }
        return groups
    }

    private fun String.countSubstring(value: String): Int {
        var count = 0
        var index = indexOf(value)
        while (index >= 0) {
            count++
            index = indexOf(value, index + value.length)
        }
        return count
    }
}

data class TrustedProxyCidr(
    private val network: ByteArray,
    private val prefixBits: Int,
) {
    fun contains(ip: NormalizedIp): Boolean {
        val candidate = ip.addressBytes
        if (candidate.size != network.size) {
            return false
        }
        val wholeBytes = prefixBits / 8
        val partialBits = prefixBits % 8
        for (index in 0 until wholeBytes) {
            if (candidate[index] != network[index]) {
                return false
            }
        }
        if (partialBits == 0) {
            return true
        }
        val mask = (0xff shl (8 - partialBits)) and 0xff
        return (candidate[wholeBytes].toInt() and mask) == (network[wholeBytes].toInt() and mask)
    }

    companion object {
        fun parse(raw: String): TrustedProxyCidr {
            val parts = raw.split('/')
            require(parts.size == 2) { "Invalid trusted proxy CIDR" }
            val ip = IpLiteralParser.parse(parts[0]) ?: throw IllegalArgumentException("Invalid trusted proxy CIDR")
            val prefix = parts[1].toIntOrNull() ?: throw IllegalArgumentException("Invalid trusted proxy CIDR")
            require(prefix in 0..(ip.addressBytes.size * 8)) { "Invalid trusted proxy CIDR" }
            return TrustedProxyCidr(mask(ip.addressBytes, prefix), prefix)
        }

        private fun mask(bytes: ByteArray, prefixBits: Int): ByteArray {
            val result = bytes.copyOf()
            val wholeBytes = prefixBits / 8
            val partialBits = prefixBits % 8
            if (partialBits != 0 && wholeBytes < result.size) {
                result[wholeBytes] =
                    (result[wholeBytes].toInt() and ((0xff shl (8 - partialBits)) and 0xff)).toByte()
            }
            for (index in (wholeBytes + if (partialBits == 0) 0 else 1) until result.size) {
                result[index] = 0
            }
            return result
        }
    }
}

class TrustedProxySet private constructor(
    private val cidrs: List<TrustedProxyCidr>,
) {
    fun contains(ip: NormalizedIp): Boolean = cidrs.any { it.contains(ip) }

    companion object {
        fun from(rawCidrs: List<String>): TrustedProxySet =
            TrustedProxySet(rawCidrs.map(TrustedProxyCidr::parse))
    }
}
