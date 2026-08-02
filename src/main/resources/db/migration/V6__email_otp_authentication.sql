CREATE TABLE auth_identities (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type VARCHAR(16) NOT NULL,
    normalized_identifier VARCHAR(254) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_auth_identities_type CHECK (type IN ('PHONE', 'EMAIL')),
    CONSTRAINT chk_auth_identities_identifier_nonblank CHECK (btrim(normalized_identifier) <> ''),
    CONSTRAINT uq_auth_identities_type_identifier UNIQUE (type, normalized_identifier),
    CONSTRAINT uq_auth_identities_user_type UNIQUE (user_id, type)
);

INSERT INTO auth_identities (user_id, type, normalized_identifier)
SELECT id, 'PHONE', phone
FROM users
WHERE phone IS NOT NULL;

ALTER TABLE users
    ALTER COLUMN phone DROP NOT NULL;

DELETE FROM otp_codes;

DROP INDEX IF EXISTS idx_otp_phone;
DROP INDEX IF EXISTS idx_otp_expires;

ALTER TABLE otp_codes
    RENAME COLUMN phone TO identifier;

ALTER TABLE otp_codes
    ALTER COLUMN identifier TYPE VARCHAR(254),
    DROP COLUMN code,
    DROP COLUMN is_used,
    ADD COLUMN channel VARCHAR(16) NOT NULL,
    ADD COLUMN code_hash BYTEA NOT NULL,
    ADD COLUMN hash_salt BYTEA NOT NULL,
    ADD COLUMN hash_key_id VARCHAR(32) NOT NULL,
    ADD COLUMN status VARCHAR(24) NOT NULL,
    ADD COLUMN failed_attempts INT NOT NULL DEFAULT 0,
    ADD COLUMN max_attempts INT NOT NULL,
    ADD COLUMN activated_at TIMESTAMP,
    ADD COLUMN consumed_at TIMESTAMP,
    ADD CONSTRAINT chk_otp_codes_channel CHECK (channel IN ('PHONE', 'EMAIL')),
    ADD CONSTRAINT chk_otp_codes_status CHECK (
        status IN (
            'PENDING',
            'ACTIVE',
            'CONSUMED',
            'EXHAUSTED',
            'EXPIRED',
            'SUPERSEDED',
            'DELIVERY_FAILED'
        )
    ),
    ADD CONSTRAINT chk_otp_codes_identifier_nonblank CHECK (btrim(identifier) <> ''),
    ADD CONSTRAINT chk_otp_codes_hash_length CHECK (octet_length(code_hash) = 32),
    ADD CONSTRAINT chk_otp_codes_salt_length CHECK (octet_length(hash_salt) = 16),
    ADD CONSTRAINT chk_otp_codes_hash_key_id CHECK (hash_key_id ~ '^[A-Za-z0-9._~-]{1,32}$'),
    ADD CONSTRAINT chk_otp_codes_attempts CHECK (
        failed_attempts >= 0
        AND max_attempts BETWEEN 1 AND 10
        AND failed_attempts <= max_attempts
    );

CREATE INDEX idx_otp_codes_channel_identifier_latest
    ON otp_codes (channel, identifier, id DESC);

CREATE UNIQUE INDEX uq_otp_codes_active
    ON otp_codes (channel, identifier)
    WHERE status = 'ACTIVE';

CREATE INDEX idx_otp_codes_status_expires_id
    ON otp_codes (status, expires_at, id);

ALTER TABLE otp_rate_limit_attempts
    DROP CONSTRAINT chk_otp_rate_limit_scope,
    ADD CONSTRAINT chk_otp_rate_limit_scope CHECK (
        scope IN (
            'phone',
            'email',
            'ip',
            'device',
            'verify_phone',
            'verify_email',
            'verify_ip',
            'verify_device'
        )
    );
