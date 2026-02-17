-- Sample query catalog for LOGGING_PGSQL_MCP.md
--
-- Purpose:
-- - Provide ready-to-run diagnostics against observability.app_log_events
-- - Mirror the MCP tools with equivalent SQL for verification and triage
--
-- Notes:
-- - Replace literal values in each params CTE before execution.
-- - Keep limits bounded to protect interactive sessions.

-- -----------------------------------------------------------------------------
-- 1) tail_logs equivalent: newest rows by project/service/level
-- -----------------------------------------------------------------------------
with params as (
  select
    'my_app'::text as project,
    null::text as service,
    null::text as level,
    100::int as max_rows
)
select id, logged_at, level, service, component, message, trace_id
from observability.app_log_events, params
where project = params.project
  and (params.service is null or service = params.service)
  and (params.level is null or level = params.level)
order by logged_at desc
limit (select max_rows from params);

-- -----------------------------------------------------------------------------
-- 2) search_logs equivalent: time + service + level + trace + text
-- -----------------------------------------------------------------------------
with params as (
  select
    'my_app'::text as project,
    'api'::text as service,
    'error'::text as level,
    null::text as trace_id,
    'timeout'::text as query_text,
    now() - interval '30 minutes' as from_ts,
    now() as to_ts,
    200::int as max_rows
)
select id, logged_at, level, service, component, message, trace_id
from observability.app_log_events, params
where project = params.project
  and (params.service is null or service = params.service)
  and (params.level is null or level = params.level)
  and (params.trace_id is null or trace_id = params.trace_id)
  and (params.from_ts is null or logged_at >= params.from_ts)
  and (params.to_ts is null or logged_at <= params.to_ts)
  and (params.query_text is null or message ilike ('%' || params.query_text || '%'))
order by logged_at desc
limit (select max_rows from params);

-- -----------------------------------------------------------------------------
-- 3) get_trace equivalent: chronological trace reconstruction
-- -----------------------------------------------------------------------------
with params as (
  select
    'my_app'::text as project,
    'replace-with-trace-id'::text as trace_id,
    500::int as max_rows
)
select id, logged_at, level, service, component, message, trace_id, payload
from observability.app_log_events, params
where project = params.project
  and trace_id = params.trace_id
order by logged_at asc
limit (select max_rows from params);

-- -----------------------------------------------------------------------------
-- 4) get_context equivalent: rows around a given event id
-- -----------------------------------------------------------------------------
with params as (
  select
    'my_app'::text as project,
    123456::bigint as target_id,
    20::int as before_rows,
    20::int as after_rows
),
anchor as (
  select e.id, e.logged_at
  from observability.app_log_events e, params
  where e.project = params.project
    and e.id = params.target_id
  limit 1
),
before_slice as (
  select e.id, e.logged_at, e.level, e.service, e.component, e.message, e.trace_id, e.payload
  from observability.app_log_events e, params, anchor
  where e.project = params.project
    and e.logged_at < anchor.logged_at
  order by e.logged_at desc
  limit (select before_rows from params)
),
anchor_slice as (
  select e.id, e.logged_at, e.level, e.service, e.component, e.message, e.trace_id, e.payload
  from observability.app_log_events e, params
  where e.project = params.project
    and e.id = params.target_id
  limit 1
),
after_slice as (
  select e.id, e.logged_at, e.level, e.service, e.component, e.message, e.trace_id, e.payload
  from observability.app_log_events e, params, anchor
  where e.project = params.project
    and e.logged_at > anchor.logged_at
  order by e.logged_at asc
  limit (select after_rows from params)
)
select *
from (
  select * from before_slice
  union all
  select * from anchor_slice
  union all
  select * from after_slice
) rows
order by logged_at asc;

-- -----------------------------------------------------------------------------
-- 5) Error rate by minute for a project/service window
-- -----------------------------------------------------------------------------
with params as (
  select
    'my_app'::text as project,
    null::text as service,
    now() - interval '2 hours' as from_ts,
    now() as to_ts
)
select
  date_trunc('minute', logged_at) as minute_bucket,
  count(*) as error_count
from observability.app_log_events, params
where project = params.project
  and (params.service is null or service = params.service)
  and level in ('error', 'fatal')
  and logged_at >= params.from_ts
  and logged_at <= params.to_ts
group by minute_bucket
order by minute_bucket asc;

-- -----------------------------------------------------------------------------
-- 6) Top noisy messages in the last 24 hours
-- -----------------------------------------------------------------------------
with params as (
  select
    'my_app'::text as project,
    now() - interval '24 hours' as from_ts,
    now() as to_ts,
    25::int as max_rows
)
select message, count(*) as hits
from observability.app_log_events, params
where project = params.project
  and logged_at >= params.from_ts
  and logged_at <= params.to_ts
group by message
order by hits desc, message asc
limit (select max_rows from params);

-- -----------------------------------------------------------------------------
-- 7) Distinct error traces with first/last timestamps
-- -----------------------------------------------------------------------------
with params as (
  select
    'my_app'::text as project,
    now() - interval '6 hours' as from_ts,
    now() as to_ts,
    100::int as max_rows
)
select
  trace_id,
  min(logged_at) as first_seen,
  max(logged_at) as last_seen,
  count(*) as events
from observability.app_log_events, params
where project = params.project
  and level in ('error', 'fatal')
  and trace_id is not null
  and logged_at >= params.from_ts
  and logged_at <= params.to_ts
group by trace_id
order by last_seen desc
limit (select max_rows from params);

-- -----------------------------------------------------------------------------
-- 8) Table health quick check
-- -----------------------------------------------------------------------------
select
  count(*) as total_rows,
  min(logged_at) as oldest_logged_at,
  max(logged_at) as newest_logged_at
from observability.app_log_events;

-- -----------------------------------------------------------------------------
-- 9) Retention preview (rows eligible for deletion at 30 days)
-- -----------------------------------------------------------------------------
select count(*) as rows_older_than_30_days
from observability.app_log_events
where logged_at < now() - interval '30 days';

-- -----------------------------------------------------------------------------
-- 10) Retention cleanup execution (uncomment to run)
-- -----------------------------------------------------------------------------
-- select observability.cleanup_old_logs('30 days'::interval) as deleted_rows;
