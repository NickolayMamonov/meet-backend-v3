ALTER TABLE meetings
    ADD COLUMN timepad_eligible_until_ms BIGINT;

CREATE OR REPLACE FUNCTION public.timepad_policy_visible(
    meeting_id BIGINT,
    as_of_ms BIGINT
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY INVOKER
AS $$
    SELECT m.source <> 'TIMEPAD'
        OR m.demo_catalog_key IS NOT NULL
        OR (
            m.status = 'ACTIVE'
            AND m.timepad_eligible_until_ms IS NOT NULL
            AND m.timepad_eligible_until_ms > as_of_ms
            AND COALESCE(m.ends_at, m.time) > as_of_ms
        )
    FROM public.meetings AS m
    WHERE m.id = meeting_id
$$;
