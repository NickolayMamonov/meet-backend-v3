CREATE INDEX idx_otp_rate_limit_attempts_attempted_at
    ON otp_rate_limit_attempts (attempted_at, id);
