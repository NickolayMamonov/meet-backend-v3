package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.PushInstallationDto
import dev.whysoezzy.meet.api.dto.PushInstallationRequest
import dev.whysoezzy.meet.api.error.BadRequestException
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.service.push.Fid
import dev.whysoezzy.meet.service.push.PushInstallationRecord
import dev.whysoezzy.meet.service.push.PushInstallationService
import dev.whysoezzy.meet.service.push.parseFid as parseFidValue
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import jakarta.validation.Valid
import org.springframework.http.HttpStatus
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.DeleteMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.PutMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController
import java.util.UUID

@RestController
@RequestMapping("/profile/push-installations")
@Tag(name = "Push installations")
class PushInstallationController(
    private val service: PushInstallationService,
    private val authUtils: AuthUtils,
) {
    @PostMapping
    @Operation(summary = "Register a push installation", security = [SecurityRequirement(name = "bearerAuth")])
    fun register(@Valid @RequestBody request: PushInstallationRequest): ResponseEntity<PushInstallationDto> {
        val result = service.register(authUtils.getCurrentUserId(), parseFid(request.fid))
        val body = result.installation.toDto()
        return ResponseEntity.status(if (result.created) HttpStatus.CREATED else HttpStatus.OK).body(body)
    }

    @PutMapping("/{installationId}")
    @Operation(summary = "Rotate a push installation", security = [SecurityRequirement(name = "bearerAuth")])
    fun rotate(
        @PathVariable installationId: String,
        @Valid @RequestBody request: PushInstallationRequest,
    ): PushInstallationDto {
        val id = parseCanonicalUuid(installationId)
        return service.rotate(authUtils.getCurrentUserId(), id, parseFid(request.fid)).installation.toDto()
    }

    @DeleteMapping("/{installationId}")
    @Operation(summary = "Unregister a push installation", security = [SecurityRequirement(name = "bearerAuth")])
    fun unregister(@PathVariable installationId: String): ResponseEntity<Void> {
        service.unregister(authUtils.getCurrentUserId(), parseCanonicalUuid(installationId))
        return ResponseEntity.noContent().build()
    }

    private fun parseFid(value: String): Fid =
        try {
            parseFidValue(value)
        } catch (_: IllegalArgumentException) {
            throw BadRequestException("Invalid FID")
        }

    private fun parseCanonicalUuid(value: String): UUID {
        if (!CANONICAL_UUID.matches(value) || value != value.lowercase()) {
            throw BadRequestException("Invalid installation ID")
        }
        return runCatching { UUID.fromString(value) }
            .getOrElse { throw BadRequestException("Invalid installation ID") }
    }

    private fun PushInstallationRecord.toDto() = PushInstallationDto(
        installationId = id,
        status = status.name,
        lastSeenAt = lastSeenAt,
    )

    private companion object {
        val CANONICAL_UUID = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    }
}
