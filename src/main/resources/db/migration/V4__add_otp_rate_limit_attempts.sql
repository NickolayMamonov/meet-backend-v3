CREATE TABLE otp_rate_limit_attempts (
    id BIGSERIAL PRIMARY KEY,
    scope VARCHAR(16) NOT NULL,
    subject_key CHAR(64) NOT NULL,
    attempted_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_otp_rate_limit_scope CHECK (scope IN ('phone', 'ip', 'device'))
);

CREATE INDEX idx_otp_rate_limit_attempts_scope_subject_attempted
    ON otp_rate_limit_attempts (scope, subject_key, attempted_at);
