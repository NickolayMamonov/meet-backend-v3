-- V1__Initial_schema.sql

-- Tags
CREATE TABLE tags (
    id BIGSERIAL PRIMARY KEY,
    text VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Users
CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    surname VARCHAR(100) NOT NULL,
    phone VARCHAR(20) UNIQUE NOT NULL,
    email VARCHAR(255),
    city VARCHAR(100) DEFAULT '',
    avatar_url TEXT,
    bio TEXT DEFAULT '',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- User interests (Many-to-Many)
CREATE TABLE user_interests (
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tag_id BIGINT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, tag_id)
);

-- User social media
CREATE TABLE user_social_media (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    platform VARCHAR(50) NOT NULL,
    username VARCHAR(255) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, platform)
);

-- Communities
CREATE TABLE communities (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT NOT NULL,
    image_url TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Community tags (Many-to-Many)
CREATE TABLE community_tags (
    community_id BIGINT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
    tag_id BIGINT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (community_id, tag_id)
);

-- Community subscribers (Many-to-Many)
CREATE TABLE community_subscribers (
    community_id BIGINT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (community_id, user_id)
);

-- Meetings
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
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Meeting tags (Many-to-Many)
CREATE TABLE meeting_tags (
    meeting_id BIGINT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    tag_id BIGINT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (meeting_id, tag_id)
);

-- Meeting participants (Many-to-Many)
CREATE TABLE meeting_participants (
    meeting_id BIGINT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (meeting_id, user_id)
);

-- Indexes
CREATE INDEX idx_meetings_time ON meetings(time);
CREATE INDEX idx_meetings_status ON meetings(status);
CREATE INDEX idx_users_phone ON users(phone);
