package dev.whysoezzy.meet.catalog

import dev.whysoezzy.meet.api.error.ConflictException
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

data class RealCatalogAttestation(
    val kind: String,
    val catalogKey: String,
    val digest: String,
    val intent: RealCatalogIntent,
    val targetEnvironment: String,
    val recoveryPointId: String?,
    val recoveryProofSchema: String?,
    val recoveryProofDigest: String?,
    val expiresAt: Instant,
)

class RealCatalogAttestationVerifier(
    private val secret: String,
) {
    fun verify(
        reference: String,
        expectedKind: String,
        expectedCatalogKey: String,
        expectedDigest: String,
        expectedIntent: RealCatalogIntent,
        expectedTargetEnvironment: String,
        now: Instant,
    ): RealCatalogAttestation {
        if (secret.toByteArray(StandardCharsets.UTF_8).size < MIN_SECRET_BYTES) {
            throw ConflictException("Real catalog attestations are not configured")
        }
        val parts = reference.split('.')
        if (parts.size != SEGMENT_COUNT || parts.firstOrNull() != PREFIX) {
            throw ConflictException("Invalid real catalog attestation")
        }
        val payload = parts.dropLast(1).joinToString(".")
        val expectedSignature = sign(payload)
        val suppliedSignature = runCatching { hex(parts.last()) }.getOrNull()
            ?: throw ConflictException("Invalid real catalog attestation")
        if (!MessageDigest.isEqual(expectedSignature, suppliedSignature)) {
            throw ConflictException("Invalid real catalog attestation")
        }
        val decoded = parts.drop(1).dropLast(1).map { decode(it) }
        val kind = decoded[0]
        val catalogKey = decoded[1]
        val digest = decoded[2]
        val intent = runCatching { RealCatalogIntent.valueOf(decoded[3]) }.getOrNull()
            ?: throw ConflictException("Invalid real catalog attestation")
        val target = decoded[4]
        val recoveryPointId = decoded[5].takeUnless { it == EMPTY }
        val recoveryProofSchema = decoded[6].takeUnless { it == EMPTY }
        val recoveryProofDigest = decoded[7].takeUnless { it == EMPTY }
        val expiresAt = runCatching { Instant.ofEpochSecond(decoded[8].toLong()) }.getOrNull()
            ?: throw ConflictException("Invalid real catalog attestation")
        if (kind != expectedKind ||
            catalogKey != expectedCatalogKey ||
            digest != expectedDigest ||
            intent != expectedIntent ||
            target != expectedTargetEnvironment ||
            !expiresAt.isAfter(now)
        ) {
            throw ConflictException("Real catalog attestation binding conflict")
        }
        return RealCatalogAttestation(
            kind = kind,
            catalogKey = catalogKey,
            digest = digest,
            intent = intent,
            targetEnvironment = target,
            recoveryPointId = recoveryPointId,
            recoveryProofSchema = recoveryProofSchema,
            recoveryProofDigest = recoveryProofDigest,
            expiresAt = expiresAt,
        )
    }

    private fun sign(payload: String): ByteArray =
        Mac.getInstance("HmacSHA256").apply {
            init(SecretKeySpec(secret.toByteArray(StandardCharsets.UTF_8), "HmacSHA256"))
        }.doFinal(payload.toByteArray(StandardCharsets.UTF_8))

    private fun hex(value: String): ByteArray {
        require(value.length == 64 && value.all { it in "0123456789abcdef" })
        return ByteArray(32) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    private fun decode(value: String): String =
        runCatching {
            String(Base64.getUrlDecoder().decode(value), StandardCharsets.UTF_8)
        }.getOrElse { throw ConflictException("Invalid real catalog attestation") }

    companion object {
        const val PREFIX = "rca1"
        const val RECOVERY_PROOF_SCHEMA = "meet-backend/closed-beta-database-proof/v2"
        const val CONTENT = "CONTENT"
        const val MUTATION = "MUTATION"
        const val RECOVERY = "RECOVERY"
        const val MIN_SECRET_BYTES = 32
        private const val EMPTY = "-"
        private const val SEGMENT_COUNT = 11
    }
}
