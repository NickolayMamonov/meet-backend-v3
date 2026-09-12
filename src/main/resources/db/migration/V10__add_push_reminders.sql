ALTER TABLE meetings
    ADD COLUMN push_start_version BIGINT NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION bump_meeting_push_start_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.time IS DISTINCT FROM OLD.time THEN
        NEW.push_start_version := OLD.push_start_version + 1;
    ELSE
        NEW.push_start_version := OLD.push_start_version;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_meetings_push_start_version
    BEFORE UPDATE OF time, push_start_version ON meetings
    FOR EACH ROW
    EXECUTE FUNCTION bump_meeting_push_start_version();

CREATE TABLE push_installations (
    id UUID PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    fid TEXT COLLATE "C",
    status VARCHAR(20) NOT NULL,
    registration_version BIGINT NOT NULL,
    created_at TIMESTAMPTZ(3) NOT NULL,
    updated_at TIMESTAMPTZ(3) NOT NULL,
    last_seen_at TIMESTAMPTZ(3) NOT NULL,
    terminal_at TIMESTAMPTZ(3),
    CONSTRAINT uq_push_installation_id_user UNIQUE (id, user_id),
    CONSTRAINT ck_push_installation_status CHECK (
        status IN ('ACTIVE', 'UNREGISTERED', 'INVALID', 'EXPIRED', 'TRANSFERRED', 'ACCOUNT_DELETED')
    ),
    CONSTRAINT ck_push_installation_registration_version CHECK (registration_version > 0),
    CONSTRAINT ck_push_installation_fid CHECK (
        fid IS NULL OR octet_length(fid) BETWEEN 1 AND 1024
    ),
    CONSTRAINT ck_push_installation_lifecycle CHECK (
        (status = 'ACTIVE' AND fid IS NOT NULL AND terminal_at IS NULL)
        OR
        (status <> 'ACTIVE' AND fid IS NULL AND terminal_at IS NOT NULL)
    )
);

CREATE UNIQUE INDEX uq_push_installations_active_fid
    ON push_installations (fid)
    WHERE status = 'ACTIVE' AND fid IS NOT NULL;
CREATE INDEX idx_push_installations_owner_fresh
    ON push_installations (user_id, last_seen_at, id)
    WHERE status = 'ACTIVE';

CREATE TABLE meeting_reminder_claims (
    id UUID PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    meeting_id BIGINT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    reminder_offset_minutes INT NOT NULL,
    meeting_start_ms BIGINT NOT NULL,
    start_version BIGINT NOT NULL,
    due_at TIMESTAMPTZ(3) NOT NULL,
    deadline_at TIMESTAMPTZ(3) NOT NULL,
    issued_at TIMESTAMPTZ(3) NOT NULL,
    status VARCHAR(20) NOT NULL,
    completed_at TIMESTAMPTZ(3),
    CONSTRAINT uq_reminder_user_meeting_offset
        UNIQUE (user_id, meeting_id, reminder_offset_minutes),
    CONSTRAINT uq_reminder_claim_id_user UNIQUE (id, user_id),
    CONSTRAINT ck_reminder_offset CHECK (reminder_offset_minutes IN (60, 1440)),
    CONSTRAINT ck_reminder_start_version CHECK (start_version >= 0),
    CONSTRAINT ck_reminder_due_derived CHECK (
        due_at = to_timestamp((meeting_start_ms - reminder_offset_minutes * 60000)::double precision / 1000)
    ),
    CONSTRAINT ck_reminder_deadline_derived CHECK (deadline_at = due_at + INTERVAL '15 minutes'),
    CONSTRAINT ck_reminder_issued_window CHECK (issued_at >= due_at AND issued_at <= deadline_at),
    CONSTRAINT ck_reminder_status CHECK (status IN ('PENDING', 'SENT', 'FAILED', 'SKIPPED', 'NO_TARGET')),
    CONSTRAINT ck_reminder_completion CHECK (
        (status = 'PENDING' AND completed_at IS NULL)
        OR
        (status <> 'PENDING' AND completed_at IS NOT NULL)
    )
);

CREATE INDEX idx_reminder_claims_due
    ON meeting_reminder_claims (due_at, meeting_id, user_id, reminder_offset_minutes);
CREATE INDEX idx_reminder_claims_meeting ON meeting_reminder_claims (meeting_id);
CREATE INDEX idx_reminder_claims_user ON meeting_reminder_claims (user_id);

CREATE TABLE meeting_reminder_targets (
    id UUID PRIMARY KEY,
    claim_id UUID NOT NULL,
    user_id BIGINT NOT NULL,
    installation_id UUID NOT NULL,
    status VARCHAR(20) NOT NULL,
    attempts SMALLINT NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ(3) NOT NULL,
    lease_token UUID,
    lease_until TIMESTAMPTZ(3),
    reason VARCHAR(32),
    completed_at TIMESTAMPTZ(3),
    CONSTRAINT uq_reminder_target_installation UNIQUE (claim_id, installation_id),
    CONSTRAINT fk_reminder_target_claim
        FOREIGN KEY (claim_id, user_id) REFERENCES meeting_reminder_claims(id, user_id) ON DELETE CASCADE,
    CONSTRAINT fk_reminder_target_installation
        FOREIGN KEY (installation_id, user_id) REFERENCES push_installations(id, user_id) ON DELETE CASCADE,
    CONSTRAINT ck_reminder_target_status CHECK (
        status IN ('PENDING', 'LEASED', 'RETRY_WAIT', 'SENT', 'INVALID', 'FAILED', 'SKIPPED')
    ),
    CONSTRAINT ck_reminder_target_attempts CHECK (attempts BETWEEN 0 AND 5),
    CONSTRAINT ck_reminder_target_lease CHECK (
        (status = 'LEASED' AND lease_token IS NOT NULL AND lease_until IS NOT NULL)
        OR
        (status <> 'LEASED' AND lease_token IS NULL AND lease_until IS NULL)
    ),
    CONSTRAINT ck_reminder_target_completion CHECK (
        (status IN ('PENDING', 'LEASED') AND completed_at IS NULL AND reason IS NULL)
        OR
        (status = 'RETRY_WAIT' AND completed_at IS NULL
            AND reason IN ('TRANSIENT', 'PROVIDER_UNAVAILABLE'))
        OR
        (status IN ('SENT', 'INVALID', 'FAILED', 'SKIPPED') AND completed_at IS NOT NULL AND reason IS NOT NULL)
    ),
    CONSTRAINT ck_reminder_target_retry_reason CHECK (
        status <> 'RETRY_WAIT' OR reason IN ('TRANSIENT', 'PROVIDER_UNAVAILABLE')
    ),
    CONSTRAINT ck_reminder_target_attempt_reason CHECK (
        (status = 'PENDING' AND attempts = 0)
        OR (status = 'LEASED' AND attempts BETWEEN 1 AND 5)
        OR (status = 'RETRY_WAIT' AND attempts BETWEEN 1 AND 4)
        OR (status = 'SENT' AND attempts BETWEEN 1 AND 5 AND reason = 'ACCEPTED')
        OR (status = 'INVALID' AND attempts BETWEEN 1 AND 5 AND reason = 'UNREGISTERED')
        OR (status = 'FAILED' AND attempts = 5 AND reason = 'ATTEMPTS_EXHAUSTED')
        OR (
            status = 'SKIPPED'
            AND attempts BETWEEN 0 AND 5
            AND reason IN (
                'USER_UNAVAILABLE',
                'OPTED_OUT',
                'LEFT_MEETING',
                'MEETING_UNAVAILABLE',
                'START_CHANGED',
                'STARTED',
                'INSTALLATION_UNAVAILABLE',
                'INSTALLATION_STALE',
                'DEADLINE_PASSED'
            )
        )
    )
);

CREATE INDEX idx_reminder_targets_ready
    ON meeting_reminder_targets (next_attempt_at, id)
    WHERE status IN ('PENDING', 'RETRY_WAIT');
CREATE INDEX idx_reminder_targets_expired_lease
    ON meeting_reminder_targets (lease_until, id)
    WHERE status = 'LEASED';
CREATE INDEX idx_reminder_targets_claim ON meeting_reminder_targets (claim_id);
CREATE INDEX idx_reminder_targets_user ON meeting_reminder_targets (user_id);
CREATE INDEX idx_reminder_targets_installation ON meeting_reminder_targets (installation_id);
