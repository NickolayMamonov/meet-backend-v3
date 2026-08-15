ALTER TABLE users
    ADD COLUMN demo_catalog_key VARCHAR(160),
    ADD CONSTRAINT ck_users_demo_catalog_key_nonblank
        CHECK (demo_catalog_key IS NULL OR btrim(demo_catalog_key) <> '');
CREATE UNIQUE INDEX uq_users_demo_catalog_key
    ON users (demo_catalog_key)
    WHERE demo_catalog_key IS NOT NULL;

ALTER TABLE communities
    ADD COLUMN demo_catalog_key VARCHAR(160),
    ADD CONSTRAINT ck_communities_demo_catalog_key_nonblank
        CHECK (demo_catalog_key IS NULL OR btrim(demo_catalog_key) <> '');
CREATE UNIQUE INDEX uq_communities_demo_catalog_key
    ON communities (demo_catalog_key)
    WHERE demo_catalog_key IS NOT NULL;

ALTER TABLE meetings
    ADD COLUMN demo_catalog_key VARCHAR(160),
    ADD CONSTRAINT ck_meetings_demo_catalog_key_nonblank
        CHECK (demo_catalog_key IS NULL OR btrim(demo_catalog_key) <> '');
CREATE UNIQUE INDEX uq_meetings_demo_catalog_key
    ON meetings (demo_catalog_key)
    WHERE demo_catalog_key IS NOT NULL;

ALTER TABLE tags
    ADD COLUMN demo_catalog_key VARCHAR(160),
    ADD CONSTRAINT ck_tags_demo_catalog_key_nonblank
        CHECK (demo_catalog_key IS NULL OR btrim(demo_catalog_key) <> '');
CREATE UNIQUE INDEX uq_tags_demo_catalog_key
    ON tags (demo_catalog_key)
    WHERE demo_catalog_key IS NOT NULL;

ALTER TABLE ad_blocks
    ADD COLUMN demo_catalog_key VARCHAR(160),
    ADD CONSTRAINT ck_ad_blocks_demo_catalog_key_nonblank
        CHECK (demo_catalog_key IS NULL OR btrim(demo_catalog_key) <> '');
CREATE UNIQUE INDEX uq_ad_blocks_demo_catalog_key
    ON ad_blocks (demo_catalog_key)
    WHERE demo_catalog_key IS NOT NULL;

CREATE TABLE demo_catalog_state (
    catalog_name VARCHAR(80) PRIMARY KEY,
    manifest_version VARCHAR(80) NOT NULL,
    schedule_anchor_date DATE NOT NULL,
    catalog_valid_through TIMESTAMPTZ NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL
);
