-- Compatibility for dev databases created between the schema consolidation
-- and refresh-token hashing migrations. Those databases recorded the old
-- dev seed as V2, which now belongs to V2__hash_refresh_tokens.sql.
--
-- These checksums are Flyway CRC32 values for immutable historical scripts:
--   1174224222 = V2__dev_seed.sql
--    946899043 = V2__hash_refresh_tokens.sql
DO $repair_legacy_dev_seed$
DECLARE
    legacy_v2 RECORD;
    has_plaintext_token BOOLEAN;
    has_token_hash BOOLEAN;
    successful_v2_count INTEGER;
    repaired_row_count INTEGER;
BEGIN
    IF to_regclass('flyway_schema_history') IS NULL THEN
        RETURN;
    END IF;

    SELECT count(*)
    INTO successful_v2_count
    FROM flyway_schema_history
    WHERE version = '2'
      AND success = TRUE;

    IF successful_v2_count > 1 THEN
        RAISE EXCEPTION 'Multiple successful Flyway V2 history rows found';
    END IF;

    SELECT installed_rank
    INTO legacy_v2
    FROM flyway_schema_history
    WHERE version = '2'
      AND description = 'dev seed'
      AND type = 'SQL'
      AND script = 'V2__dev_seed.sql'
      AND checksum = 1174224222
      AND success = TRUE
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'refresh_tokens'
          AND column_name = 'token'
    ) INTO has_plaintext_token;

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'refresh_tokens'
          AND column_name = 'token_hash'
    ) INTO has_token_hash;

    IF NOT has_plaintext_token OR has_token_hash THEN
        RAISE EXCEPTION
            'Legacy dev Flyway history does not match the expected plaintext refresh-token schema';
    END IF;

    DELETE FROM refresh_tokens;
    DROP INDEX IF EXISTS idx_refresh_token;

    ALTER TABLE refresh_tokens
        DROP COLUMN token,
        ADD COLUMN token_hash VARCHAR(64) NOT NULL,
        ADD CONSTRAINT chk_refresh_tokens_token_hash
            CHECK (token_hash ~ '^[0-9a-f]{64}$'),
        ADD CONSTRAINT uq_refresh_tokens_token_hash UNIQUE (token_hash);

    UPDATE flyway_schema_history
    SET description = 'hash refresh tokens',
        script = 'V2__hash_refresh_tokens.sql',
        checksum = 946899043
    WHERE installed_rank = legacy_v2.installed_rank;

    GET DIAGNOSTICS repaired_row_count = ROW_COUNT;
    IF repaired_row_count <> 1 THEN
        RAISE EXCEPTION 'Expected to repair exactly one legacy Flyway V2 history row';
    END IF;

    RAISE NOTICE 'Repaired legacy dev migration history for refresh-token hashing';
END;
$repair_legacy_dev_seed$;
