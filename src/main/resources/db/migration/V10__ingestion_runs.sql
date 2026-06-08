-- Журнал прогонов ингестии (наблюдаемость): одна строка на источник за запуск.
CREATE TABLE ingestion_runs (
    id            BIGSERIAL    PRIMARY KEY,
    source        VARCHAR(20)  NOT NULL,
    status        VARCHAR(20)  NOT NULL,
    fetched_count INT          NOT NULL DEFAULT 0,
    created_count INT          NOT NULL DEFAULT 0,
    updated_count INT          NOT NULL DEFAULT 0,
    skipped_count INT          NOT NULL DEFAULT 0,
    error_message TEXT,
    started_at    TIMESTAMP    NOT NULL,
    finished_at   TIMESTAMP,
    created_at    TIMESTAMP    NOT NULL,
    updated_at    TIMESTAMP    NOT NULL
);

CREATE INDEX idx_ingestion_runs_source_started
    ON ingestion_runs (source, started_at DESC);