package dev.whysoezzy.meet.catalog

import jakarta.persistence.Column
import jakarta.persistence.Entity
import jakarta.persistence.EnumType
import jakarta.persistence.Enumerated
import jakarta.persistence.Id
import jakarta.persistence.Lob
import jakarta.persistence.Table
import java.time.Instant

@Entity
@Table(name = "real_catalog_revisions")
class RealCatalogRevisionEntity(
    @Id
    @Column(nullable = false, length = 64)
    var digest: String,

    @Column(name = "catalog_key", nullable = false, length = 80)
    var catalogKey: String,

    @Column(name = "revision_label", nullable = false, length = 120)
    var revisionLabel: String,

    @Column(name = "schema_version", nullable = false, length = 32)
    var schemaVersion: String,

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    var intent: RealCatalogIntent,

    @Column(name = "predecessor_digest", length = 64)
    var predecessorDigest: String? = null,

    @Lob
    @Column(name = "manifest_bytes", nullable = false, columnDefinition = "bytea")
    var manifestBytes: ByteArray,

    @Column(name = "resolved_snapshot", nullable = false, columnDefinition = "TEXT")
    var resolvedSnapshot: String,

    @Column(name = "invitation_at", nullable = false)
    var invitationAt: Instant,

    @Column(name = "window_end_at", nullable = false)
    var windowEndAt: Instant,

    @Column(name = "review_at", nullable = false)
    var reviewAt: Instant,

    @Column(name = "next_review_at", nullable = false)
    var nextReviewAt: Instant,

    @Column(name = "discoverable_until", nullable = false)
    var discoverableUntil: Instant,

    @Column(name = "content_approval_ref", nullable = false, length = 160)
    var contentApprovalRef: String,

    @Column(name = "mutation_approval_ref", nullable = false, length = 160)
    var mutationApprovalRef: String,

    @Column(name = "recovery_point_ref", nullable = false, length = 160)
    var recoveryPointRef: String,

    @Column(name = "applied_at", nullable = false)
    var appliedAt: Instant,

    @Column(nullable = false)
    var generation: Long,
) {
    protected constructor() : this(
        digest = "",
        catalogKey = "",
        revisionLabel = "",
        schemaVersion = "",
        intent = RealCatalogIntent.INITIAL,
        manifestBytes = byteArrayOf(),
        resolvedSnapshot = "",
        invitationAt = Instant.EPOCH,
        windowEndAt = Instant.EPOCH,
        reviewAt = Instant.EPOCH,
        nextReviewAt = Instant.EPOCH,
        discoverableUntil = Instant.EPOCH,
        contentApprovalRef = "",
        mutationApprovalRef = "",
        recoveryPointRef = "",
        appliedAt = Instant.EPOCH,
        generation = 0,
    )
}

@Entity
@Table(name = "real_catalog_state")
class RealCatalogStateEntity(
    @Id
    @Column(name = "catalog_key", nullable = false, length = 80)
    var catalogKey: String,

    @Column(name = "current_digest", nullable = false, length = 64)
    var currentDigest: String,

    @Column(nullable = false)
    var generation: Long,

    @Enumerated(EnumType.STRING)
    @Column(name = "current_intent", nullable = false, length = 20)
    var currentIntent: RealCatalogIntent,

    @Column(name = "invitation_at", nullable = false)
    var invitationAt: Instant,

    @Column(name = "window_end_at", nullable = false)
    var windowEndAt: Instant,

    @Column(name = "review_at", nullable = false)
    var reviewAt: Instant,

    @Column(name = "next_review_at", nullable = false)
    var nextReviewAt: Instant,

    @Column(name = "discoverable_until", nullable = false)
    var discoverableUntil: Instant,

    @Column(name = "owner_role", nullable = false, length = 80)
    var ownerRole: String,
) {
    protected constructor() : this(
        catalogKey = "",
        currentDigest = "",
        generation = 0,
        currentIntent = RealCatalogIntent.INITIAL,
        invitationAt = Instant.EPOCH,
        windowEndAt = Instant.EPOCH,
        reviewAt = Instant.EPOCH,
        nextReviewAt = Instant.EPOCH,
        discoverableUntil = Instant.EPOCH,
        ownerRole = "",
    )
}
