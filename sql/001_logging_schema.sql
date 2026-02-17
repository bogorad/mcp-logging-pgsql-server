-- Logging schema for PostgreSQL + MCP query layer.
-- Companion artifact for LOGGING_PGSQL_MCP.md.

begin;

create schema if not exists observability;

create table if not exists observability.app_log_events (
  id bigint generated always as identity primary key,
  project text not null,
  service text not null,
  component text,
  logger text,
  level text not null check (level in ('trace', 'debug', 'info', 'warn', 'error', 'fatal')),
  logged_at timestamptz not null,
  trace_id text,
  span_id text,
  message text not null,
  payload jsonb not null,
  raw jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_log_time
  on observability.app_log_events (logged_at desc);

create index if not exists idx_log_project_time
  on observability.app_log_events (project, logged_at desc);

create index if not exists idx_log_project_level_time
  on observability.app_log_events (project, level, logged_at desc);

create index if not exists idx_log_project_service_time
  on observability.app_log_events (project, service, logged_at desc);

create index if not exists idx_log_project_trace
  on observability.app_log_events (project, trace_id, logged_at asc);

create index if not exists idx_log_payload_gin
  on observability.app_log_events using gin (payload jsonb_path_ops);

-- Optional acceleration for message substring search.
create extension if not exists pg_trgm;

create index if not exists idx_log_message_trgm
  on observability.app_log_events using gin (message gin_trgm_ops);

-- Roles are created idempotently so the script can be re-run.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'log_writer') then
    create role log_writer login;
  end if;

  if not exists (select 1 from pg_roles where rolname = 'log_reader') then
    create role log_reader login;
  end if;
end
$$;

grant usage on schema observability to log_writer, log_reader;

grant insert on observability.app_log_events to log_writer;
grant select on observability.app_log_events to log_reader;

grant usage, select on sequence observability.app_log_events_id_seq to log_writer;

alter role log_reader set statement_timeout = '3s';
alter role log_reader set idle_in_transaction_session_timeout = '5s';

-- Retention helper, can be called from cron or a scheduler.
create or replace function observability.cleanup_old_logs(retention_interval interval)
returns bigint
language plpgsql
as $$
declare
  deleted_count bigint;
begin
  delete from observability.app_log_events
  where logged_at < now() - retention_interval;

  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

comment on function observability.cleanup_old_logs(interval)
  is 'Deletes log events older than the provided interval and returns deleted row count.';

commit;
