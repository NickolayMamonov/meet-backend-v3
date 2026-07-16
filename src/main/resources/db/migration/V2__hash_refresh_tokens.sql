-- Legacy refresh tokens were persisted in plaintext. Revoke them rather than
-- retaining plaintext values or adding a database-specific hashing dependency.
DELETE FROM refresh_tokens;

DROP INDEX IF EXISTS idx_refresh_token;

ALTER TABLE refresh_tokens
    DROP COLUMN token,
    ADD COLUMN token_hash VARCHAR(64) NOT NULL,
    ADD CONSTRAINT chk_refresh_tokens_token_hash
        CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    ADD CONSTRAINT uq_refresh_tokens_token_hash UNIQUE (token_hash);
