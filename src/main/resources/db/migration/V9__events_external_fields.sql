-- Внешние события (агрегация). Аддитивная миграция: только ADD COLUMN.
-- Существующие строки получают source='MANUAL', is_online=false; остальные новые поля — NULL.
ALTER TABLE meetings
    ADD COLUMN source             VARCHAR(20)  NOT NULL DEFAULT 'MANUAL',
    ADD COLUMN source_external_id VARCHAR(255),
    ADD COLUMN external_url       TEXT,
    ADD COLUMN is_online          BOOLEAN      NOT NULL DEFAULT false,
    ADD COLUMN ingested_at        TIMESTAMP,
    ADD COLUMN dedup_hash         VARCHAR(64);

-- Идемпотентность ингестии: одно событие площадки = одна строка (source + id на площадке).
-- MANUAL-события имеют source_external_id IS NULL и под индекс не попадают
-- (в PostgreSQL NULL-значения считаются различными).
CREATE UNIQUE INDEX uq_meetings_source_external
    ON meetings (source, source_external_id)
    WHERE source_external_id IS NOT NULL;