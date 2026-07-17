package dev.whysoezzy.meet.security

import dev.whysoezzy.meet.config.JwtProperties
import io.jsonwebtoken.Claims
import io.jsonwebtoken.JwtException
import io.jsonwebtoken.Jwts
import io.jsonwebtoken.security.Keys
import mu.KotlinLogging
import org.springframework.stereotype.Service
import java.util.Date
import javax.crypto.SecretKey

private val logger = KotlinLogging.logger {}

@Service
class JwtService(
    properties: JwtProperties,
) {
    private val accessTokenExpirationMs = properties.accessTokenExpirationMs
    private val signingKey: SecretKey = Keys.hmacShaKeyFor(properties.secret.toByteArray())

    fun generateAccessToken(userId: Long, phone: String, authVersion: Long): String {
        return Jwts.builder()
            .subject(userId.toString())
            .claim("phone", phone)
            .claim(AUTH_VERSION_CLAIM, authVersion)
            .issuedAt(Date())
            .expiration(Date(System.currentTimeMillis() + accessTokenExpirationMs))
            .signWith(signingKey)
            .compact()
    }

    fun validateToken(token: String): Boolean {
        return try {
            getClaims(token)
            true
        } catch (e: JwtException) {
            logger.warn { "Invalid JWT token: ${e.message}" }
            false
        } catch (e: IllegalArgumentException) {
            logger.warn { "JWT claims empty: ${e.message}" }
            false
        }
    }

    fun getUserIdFromToken(token: String): Long {
        return getClaims(token).subject.toLong()
    }

    fun getAuthVersionFromToken(token: String): Long? =
        getClaims(token)[AUTH_VERSION_CLAIM]?.let { (it as Number).toLong() }

    private fun getClaims(token: String): Claims {
        return Jwts.parser()
            .verifyWith(signingKey)
            .build()
            .parseSignedClaims(token)
            .payload
    }

    private companion object {
        const val AUTH_VERSION_CLAIM = "av"
    }
}
