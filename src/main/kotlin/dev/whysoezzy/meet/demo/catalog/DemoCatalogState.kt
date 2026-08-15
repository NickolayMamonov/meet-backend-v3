package dev.whysoezzy.meet.demo.catalog

import jakarta.persistence.Column
import jakarta.persistence.Entity
import jakarta.persistence.Id
import jakarta.persistence.Table
import java.time.Instant
import java.time.LocalDate

@Entity
@Table(name = "demo_catalog_state")
class DemoCatalogState(
    @Id
    @Column(name = "catalog_name", length = 80)
    var catalogName: String,
    @Column(name = "manifest_version", nullable = false, length = 80)
    var manifestVersion: String,
    @Column(name = "schedule_anchor_date", nullable = false)
    var scheduleAnchorDate: LocalDate,
    @Column(name = "catalog_valid_through", nullable = false)
    var catalogValidThrough: Instant,
    @Column(name = "applied_at", nullable = false)
    var appliedAt: Instant,
)
