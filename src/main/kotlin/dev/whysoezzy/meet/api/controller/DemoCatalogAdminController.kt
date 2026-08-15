package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.DemoCatalogBootstrapRequest
import dev.whysoezzy.meet.api.dto.DemoCatalogBootstrapResponse
import dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapService
import jakarta.validation.Valid
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/admin/demo-catalog")
@ConditionalOnProperty(prefix = "app.demo-catalog", name = ["bootstrap-enabled"], havingValue = "true")
class DemoCatalogAdminController(
    private val bootstrapService: DemoCatalogBootstrapService,
) {
    @PostMapping("/bootstrap")
    fun bootstrap(
        @Valid @RequestBody request: DemoCatalogBootstrapRequest,
    ): ResponseEntity<DemoCatalogBootstrapResponse> =
        ResponseEntity.ok(DemoCatalogBootstrapResponse.from(bootstrapService.bootstrap(request.toCommand())))
}
