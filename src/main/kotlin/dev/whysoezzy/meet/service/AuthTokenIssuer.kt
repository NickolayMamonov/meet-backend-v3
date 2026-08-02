package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.AuthResponse
import dev.whysoezzy.meet.api.dto.RefreshTokenResponse
import dev.whysoezzy.meet.config.JwtProperties
import dev.whysoezzy.meet.domain.entity.RefreshToken
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.RefreshTokenRepository
import dev.whysoezzy.meet.security.JwtService
import org.springframework.stereotype.Component
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.LocalDateTime
import java.util.Base64
import java.util.HexFormat

@Component
class AuthTokenIssuer(
    private val refreshTokenRepository: RefreshTokenRepository,
    private val jwtService: JwtService,
    private val jwtProperties: JwtProperties,
    private val profileMapper: UserProfileMapper,
) {
    fun issue(user: User, isNewUser: Boolean): AuthResponse {
        val refreshToken = persistRefreshToken(user)
        return AuthResponse(
            accessToken = jwtService.generateAccessToken(requireNotNull(user.id), user.phone, user.authVersion),
            refreshToken = refreshToken,
            isNewUser = isNewUser,
            user = profileMapper.toAuthProfileDto(user),
        )
    }

    fun rotate(user: User, currentToken: RefreshToken): RefreshTokenResponse {
        val accessToken = jwtService.generateAccessToken(requireNotNull(user.id), user.phone, user.authVersion)
        refreshTokenRepository.delete(currentToken)
        return RefreshTokenResponse(
            accessToken = accessToken,
            refreshToken = persistRefreshToken(user),
        )
    }

    fun hashRefreshToken(refreshToken: String): String =
        HexFormat.of().formatHex(
            MessageDigest.getInstance("SHA-256").digest(refreshToken.toByteArray(Charsets.UTF_8)),
        )

    private fun persistRefreshToken(user: User): String {
        val value = generateRefreshToken()
        refreshTokenRepository.save(
            RefreshToken(
                user = user,
                tokenHash = hashRefreshToken(value),
                expiresAt = LocalDateTime.now().plusDays(jwtProperties.refreshTokenExpirationDays),
                authVersion = user.authVersion,
            ),
        )
        return value
    }

    private fun generateRefreshToken(): String =
        ByteArray(REFRESH_TOKEN_BYTES)
            .also(secureRandom::nextBytes)
            .let { Base64.getUrlEncoder().withoutPadding().encodeToString(it) }

    private companion object {
        const val REFRESH_TOKEN_BYTES = 32
        val secureRandom = SecureRandom()
    }
}
