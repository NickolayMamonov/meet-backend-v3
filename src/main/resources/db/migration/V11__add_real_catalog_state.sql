CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE real_catalog_revisions (
    digest VARCHAR(64) PRIMARY KEY,
    catalog_key VARCHAR(80) NOT NULL,
    revision_label VARCHAR(120) NOT NULL,
    schema_version VARCHAR(32) NOT NULL,
    intent VARCHAR(20) NOT NULL,
    predecessor_digest VARCHAR(64),
    manifest_bytes BYTEA NOT NULL,
    resolved_snapshot TEXT NOT NULL,
    invitation_at TIMESTAMPTZ(3) NOT NULL,
    window_end_at TIMESTAMPTZ(3) NOT NULL,
    review_at TIMESTAMPTZ(3) NOT NULL,
    next_review_at TIMESTAMPTZ(3) NOT NULL,
    discoverable_until TIMESTAMPTZ(3) NOT NULL,
    content_approval_ref VARCHAR(160) NOT NULL,
    mutation_approval_ref VARCHAR(160) NOT NULL,
    recovery_point_ref VARCHAR(160) NOT NULL,
    applied_at TIMESTAMPTZ(3) NOT NULL,
    generation BIGINT NOT NULL,
    CONSTRAINT uq_real_catalog_revision_label UNIQUE (catalog_key, revision_label),
    CONSTRAINT ck_real_catalog_revision_digest CHECK (digest ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_real_catalog_revision_intent CHECK (intent IN ('INITIAL', 'REVIEW', 'NEW_WINDOW', 'CORRECT')),
    CONSTRAINT ck_real_catalog_revision_generation CHECK (generation > 0),
    CONSTRAINT ck_real_catalog_revision_window CHECK (window_end_at > invitation_at),
    CONSTRAINT ck_real_catalog_revision_review CHECK (review_at >= invitation_at),
    CONSTRAINT ck_real_catalog_revision_next_review CHECK (next_review_at = review_at + INTERVAL '7 days'),
    CONSTRAINT ck_real_catalog_revision_cutoff CHECK (discoverable_until <= window_end_at),
    CONSTRAINT fk_real_catalog_revision_predecessor
        FOREIGN KEY (predecessor_digest) REFERENCES real_catalog_revisions(digest)
);

CREATE TABLE real_catalog_state (
    catalog_key VARCHAR(80) PRIMARY KEY,
    current_digest VARCHAR(64) NOT NULL,
    generation BIGINT NOT NULL,
    current_intent VARCHAR(20) NOT NULL,
    invitation_at TIMESTAMPTZ(3) NOT NULL,
    window_end_at TIMESTAMPTZ(3) NOT NULL,
    review_at TIMESTAMPTZ(3) NOT NULL,
    next_review_at TIMESTAMPTZ(3) NOT NULL,
    discoverable_until TIMESTAMPTZ(3) NOT NULL,
    owner_role VARCHAR(80) NOT NULL,
    CONSTRAINT fk_real_catalog_state_revision
        FOREIGN KEY (current_digest) REFERENCES real_catalog_revisions(digest)
        DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT ck_real_catalog_state_intent CHECK (current_intent IN ('INITIAL', 'REVIEW', 'NEW_WINDOW', 'CORRECT')),
    CONSTRAINT ck_real_catalog_state_generation CHECK (generation > 0),
    CONSTRAINT ck_real_catalog_state_window CHECK (window_end_at > invitation_at),
    CONSTRAINT ck_real_catalog_state_review CHECK (review_at >= invitation_at),
    CONSTRAINT ck_real_catalog_state_next_review CHECK (next_review_at = review_at + INTERVAL '7 days'),
    CONSTRAINT ck_real_catalog_state_cutoff CHECK (discoverable_until <= window_end_at)
);

CREATE INDEX idx_real_catalog_state_cutoff
    ON real_catalog_state (discoverable_until, catalog_key);

ALTER TABLE meetings
    ADD COLUMN real_catalog_key VARCHAR(80),
    ADD COLUMN real_catalog_item_key VARCHAR(120),
    ADD COLUMN real_catalog_active BOOLEAN,
    ADD COLUMN real_catalog_fingerprint VARCHAR(64),
    ADD CONSTRAINT fk_meetings_real_catalog_state
        FOREIGN KEY (real_catalog_key) REFERENCES real_catalog_state(catalog_key) ON DELETE RESTRICT,
    ADD CONSTRAINT ck_meetings_real_catalog_ownership CHECK (
        (real_catalog_key IS NULL
            AND real_catalog_item_key IS NULL
            AND real_catalog_active IS NULL
            AND real_catalog_fingerprint IS NULL)
        OR
        (real_catalog_key IS NOT NULL
            AND real_catalog_item_key IS NOT NULL
            AND btrim(real_catalog_item_key) <> ''
            AND real_catalog_active IS NOT NULL
            AND real_catalog_fingerprint ~ '^[0-9a-f]{64}$'
            AND demo_catalog_key IS NULL)
    );

ALTER TABLE communities
    ADD COLUMN real_catalog_key VARCHAR(80),
    ADD COLUMN real_catalog_item_key VARCHAR(120),
    ADD COLUMN real_catalog_active BOOLEAN,
    ADD COLUMN real_catalog_fingerprint VARCHAR(64),
    ADD CONSTRAINT fk_communities_real_catalog_state
        FOREIGN KEY (real_catalog_key) REFERENCES real_catalog_state(catalog_key) ON DELETE RESTRICT,
    ADD CONSTRAINT ck_communities_real_catalog_ownership CHECK (
        (real_catalog_key IS NULL
            AND real_catalog_item_key IS NULL
            AND real_catalog_active IS NULL
            AND real_catalog_fingerprint IS NULL)
        OR
        (real_catalog_key IS NOT NULL
            AND real_catalog_item_key IS NOT NULL
            AND btrim(real_catalog_item_key) <> ''
            AND real_catalog_active IS NOT NULL
            AND real_catalog_fingerprint ~ '^[0-9a-f]{64}$'
            AND demo_catalog_key IS NULL)
    );

CREATE UNIQUE INDEX uq_meetings_real_catalog_item
    ON meetings (real_catalog_key, real_catalog_item_key)
    WHERE real_catalog_key IS NOT NULL;

CREATE UNIQUE INDEX uq_communities_real_catalog_item
    ON communities (real_catalog_key, real_catalog_item_key)
    WHERE real_catalog_key IS NOT NULL;

CREATE INDEX idx_meetings_real_catalog_discovery
    ON meetings (real_catalog_key, real_catalog_active, status, time, id);

CREATE INDEX idx_communities_real_catalog_discovery
    ON communities (real_catalog_key, real_catalog_active, id);
