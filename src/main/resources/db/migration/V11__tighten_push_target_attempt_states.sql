-- V11 tightens the legal attempt range for each target state without
-- rewriting the additive V10 migration.
ALTER TABLE meeting_reminder_targets
    DROP CONSTRAINT ck_reminder_target_attempt_reason;

ALTER TABLE meeting_reminder_targets
    ADD CONSTRAINT ck_reminder_target_attempt_reason CHECK (
        (status = 'PENDING' AND attempts = 0)
        OR (status = 'LEASED' AND attempts BETWEEN 1 AND 5)
        OR (status = 'RETRY_WAIT' AND attempts BETWEEN 1 AND 4)
        OR (status IN ('SENT', 'INVALID', 'FAILED') AND attempts BETWEEN 1 AND 5)
        OR (status = 'SKIPPED' AND attempts BETWEEN 0 AND 5)
    );
