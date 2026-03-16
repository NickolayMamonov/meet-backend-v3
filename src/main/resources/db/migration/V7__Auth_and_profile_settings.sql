-- V7__Auth_and_profile_settings.sql

-- OTP коды для SMS-аутентификации
CREATE TABLE otp_codes (
    id BIGSERIAL PRIMARY KEY,
    phone VARCHAR(20) NOT NULL,
    code VARCHAR(10) NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    is_used BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_otp_phone ON otp_codes(phone);
CREATE INDEX idx_otp_expires ON otp_codes(expires_at);

-- Refresh токены для JWT
CREATE TABLE refresh_tokens (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token VARCHAR(512) UNIQUE NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_refresh_token ON refresh_tokens(token);

-- Новые поля пользователя
ALTER TABLE users
    ADD COLUMN show_communities BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN show_meetings BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN notifications_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN fcm_token TEXT,
    ADD COLUMN deleted_at TIMESTAMP;

CREATE INDEX idx_users_deleted_at ON users(deleted_at);
