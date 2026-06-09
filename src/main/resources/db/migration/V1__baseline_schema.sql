-- V1__baseline_schema.sql
-- Чистая консолидированная схема (бывшие V1–V10), БЕЗ тестовых данных.
-- Сид вынесен в db/seed/ и подключается только в dev-профиле.

-- =========================== Tags ===========================
CREATE TABLE tags (
    id BIGSERIAL PRIMARY KEY,
    text VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- =========================== Users ==========================
CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    surname VARCHAR(100) NOT NULL,
    phone VARCHAR(20) UNIQUE NOT NULL,
    email VARCHAR(255),
    city VARCHAR(100) DEFAULT '',
    avatar_url TEXT,
    bio TEXT DEFAULT '',
    role VARCHAR(100),
    show_communities BOOLEAN NOT NULL DEFAULT TRUE,
    show_meetings BOOLEAN NOT NULL DEFAULT TRUE,
    notifications_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    fcm_token TEXT,
    deleted_at TIMESTAMP,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE user_interests (
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tag_id BIGINT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, tag_id)
);

CREATE TABLE user_social_media (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    platform VARCHAR(50) NOT NULL,
    username VARCHAR(255) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, platform)
);

-- ======================= Communities ========================
CREATE TABLE communities (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT NOT NULL,
    image_url TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE community_tags (
    community_id BIGINT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
    tag_id BIGINT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (community_id, tag_id)
);

CREATE TABLE community_subscribers (
    community_id BIGINT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (community_id, user_id)
);

-- ========================= Meetings =========================
-- Включает внешние поля агрегатора (бывшая миграция V9).
CREATE TABLE meetings (
    id BIGSERIAL PRIMARY KEY,
    title VARCHAR(300) NOT NULL,
    description TEXT NOT NULL,
    image_url TEXT NOT NULL,
    time BIGINT NOT NULL,
    date VARCHAR(50) NOT NULL,
    address TEXT NOT NULL,
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    capacity INT NOT NULL DEFAULT 100,
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    person_host_id BIGINT REFERENCES users(id) ON DELETE SET NULL,
    community_host_id BIGINT REFERENCES communities(id) ON DELETE SET NULL,
    source VARCHAR(20) NOT NULL DEFAULT 'MANUAL',
    source_external_id VARCHAR(255),
    external_url TEXT,
    is_online BOOLEAN NOT NULL DEFAULT false,
    ingested_at TIMESTAMP,
    dedup_hash VARCHAR(64),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE meeting_tags (
    meeting_id BIGINT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    tag_id BIGINT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (meeting_id, tag_id)
);

CREATE TABLE meeting_participants (
    meeting_id BIGINT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (meeting_id, user_id)
);

-- ========================= Ad blocks ========================
-- Финальная форма (после удаления community_id/image_url/background_color в V5).
CREATE TABLE ad_blocks (
    id BIGSERIAL PRIMARY KEY,
    type VARCHAR(50) NOT NULL,            -- 'COMMUNITIES', 'TEXT', 'PEOPLE'
    is_active BOOLEAN NOT NULL DEFAULT true,
    title VARCHAR(255),
    description TEXT,
    action_text VARCHAR(100),
    action_url VARCHAR(500),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE ad_block_communities (
    ad_block_id BIGINT NOT NULL REFERENCES ad_blocks(id) ON DELETE CASCADE,
    community_id BIGINT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
    PRIMARY KEY (ad_block_id, community_id)
);

CREATE TABLE ad_block_users (
    ad_block_id BIGINT NOT NULL REFERENCES ad_blocks(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (ad_block_id, user_id)
);

-- =================== Auth (OTP + refresh) ===================
CREATE TABLE otp_codes (
    id BIGSERIAL PRIMARY KEY,
    phone VARCHAR(20) NOT NULL,
    code VARCHAR(10) NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    is_used BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE refresh_tokens (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token VARCHAR(512) UNIQUE NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ================= Ingestion journal (V10) ==================
CREATE TABLE ingestion_runs (
    id BIGSERIAL PRIMARY KEY,
    source VARCHAR(20) NOT NULL,
    status VARCHAR(20) NOT NULL,
    fetched_count INT NOT NULL DEFAULT 0,
    created_count INT NOT NULL DEFAULT 0,
    updated_count INT NOT NULL DEFAULT 0,
    skipped_count INT NOT NULL DEFAULT 0,
    error_message TEXT,
    started_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at TIMESTAMP,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ========================= Indexes ==========================
CREATE INDEX idx_meetings_time ON meetings(time);
CREATE INDEX idx_meetings_status ON meetings(status);
CREATE UNIQUE INDEX uq_meetings_source_external
    ON meetings (source, source_external_id)
    WHERE source_external_id IS NOT NULL;
CREATE INDEX idx_users_phone ON users(phone);
CREATE INDEX idx_users_deleted_at ON users(deleted_at);
CREATE INDEX idx_ad_blocks_type ON ad_blocks(type);
CREATE INDEX idx_ad_blocks_is_active ON ad_blocks(is_active);
CREATE INDEX idx_otp_phone ON otp_codes(phone);
CREATE INDEX idx_otp_expires ON otp_codes(expires_at);
CREATE INDEX idx_refresh_token ON refresh_tokens(token);
CREATE INDEX idx_ingestion_runs_source_started ON ingestion_runs (source, started_at DESC);
