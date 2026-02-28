-- V3__Add_ad_blocks.sql

-- AdBlocks table
CREATE TABLE ad_blocks (
    id BIGSERIAL PRIMARY KEY,
    type VARCHAR(50) NOT NULL, -- 'COMMUNITY', 'TEXT', 'BANNER'
    is_active BOOLEAN NOT NULL DEFAULT true,

    -- For COMMUNITY type
    community_id BIGINT REFERENCES communities(id) ON DELETE CASCADE,

    -- For TEXT type
    title VARCHAR(255),
    description TEXT,
    action_text VARCHAR(100),
    action_url VARCHAR(500),

    -- For BANNER type
    image_url TEXT,
    background_color VARCHAR(20),

    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Index
CREATE INDEX idx_ad_blocks_type ON ad_blocks(type);
CREATE INDEX idx_ad_blocks_is_active ON ad_blocks(is_active);