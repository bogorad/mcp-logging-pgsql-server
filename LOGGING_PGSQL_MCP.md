# Logging with PostgreSQL + MCP for LLM Search

## Executive Summary

This whitepaper defines a production-friendly logging design for small-to-medium local systems where application logs are emitted as JSONL and queried by an LLM through Model Context Protocol (MCP).

Scope assumptions:
- Log volume: about 5 MiB/day
- Ingestion source: application-generated JSON log events
- Storage target: PostgreSQL
- Query channel: MCP tools used by local AI assistants

Primary outcomes:
- Keep direct in-app log writes (no separate collector needed)
- Preserve full raw events (`jsonb`) while indexing high-value fields
- Expose bounded, read-only MCP tools for safe LLM retrieval
- Support fast workflows such as tail, filtered search, and trace reconstruction

## Whitepaper Parts

Part I: Architecture and operating model (this document, sections below)
- problem statement
- data model and indexes
- MCP tool contracts
- security, retention, migration, verification

Part II: Companion SQL artifact (implemented)
- file: `sql/001_logging_schema.sql`
- includes schema, indexes, roles/grants, and retention helper function

Part III: Companion MCP server skeleton (implemented)
- directory: repository root (`./`)
- includes TypeScript stdio MCP server and setup docs

Part IV: Companion sample query catalog (implemented)
- file: `sql/002_sample_queries.sql`
- includes ready-to-run debug, triage, and operational queries

## Part I: Architecture and Operating Model

## Problem Statement

JSONL files are simple and reliable for append-only logging, but they degrade quickly for interactive AI-assisted debugging:
- slow scanning over longer windows
- weak ad hoc filtering across fields
- hard correlation by `trace_id`/`request_id`
- poor governance for access controls and query limits

The target solution is an indexed store plus strict MCP contracts so LLM tools are deterministic, auditable, and safe.

## Decision Record

### Chosen data layout

Use one shared table across all projects with a mandatory `project` column.

Why:
- single migration path
- one MCP query surface
- easier cross-project diagnostics
- lower operational overhead at this data volume

### Rejected alternative

One table per project.

Why rejected for now:
- duplicated schema and indexes
- more migration and maintenance friction
- no material operational gain at 5 MiB/day

When to revisit:
- hard regulatory separation by project
- incompatible retention or data governance rules
- independent DB ownership boundaries

## Architecture

1. Application emits structured JSON log events.
2. Application writes events directly to PostgreSQL.
3. MCP server reads PostgreSQL through a read-only role.
4. LLM uses MCP tools (`tail_logs`, `search_logs`, `get_trace`, `get_context`).

## Data Flow

1. Event produced in application runtime.
2. Event normalized to canonical schema.
3. Row inserted into `observability.app_log_events`.
4. MCP tool receives user query intent.
5. MCP tool maps arguments to parameterized SQL.
6. Query result is returned in bounded form.

## Canonical Event Contract

Use this event shape at write time:

```json
{
  "ts": "2026-02-17T12:34:56.789Z",
  "project": "my_app",
  "service": "api",
  "component": "billing",
  "level": "debug",
  "trace_id": "8f6f2d",
  "span_id": "3c1",
  "message": "invoice queued",
  "payload": {
    "order_id": "ord_123",
    "attempt": 2
  }
}
```

Minimum required fields:
- `ts`
- `project`
- `service`
- `level`
- `message`

Recommended correlation fields:
- `trace_id`
- `span_id`
- request/session identifiers used by your app

## PostgreSQL Schema

```sql
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
```

## Index Strategy

```sql
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
```

Optional substring search on `message`:

```sql
create extension if not exists pg_trgm;

create index if not exists idx_log_message_trgm
  on observability.app_log_events using gin (message gin_trgm_ops);
```

## Write Path (Application-Side)

### Mapping rules

- `logged_at <- ts` (fallback to `now()`)
- `payload` stores structured event details
- `raw` stores full original event object for forward compatibility

### Insert template

```sql
insert into observability.app_log_events (
  project,
  service,
  component,
  logger,
  level,
  logged_at,
  trace_id,
  span_id,
  message,
  payload,
  raw
) values (
  $1, $2, $3, $4, $5,
  $6, $7, $8, $9,
  $10::jsonb,
  $11::jsonb
);
```

### Reliability guidance

- Keep logging writes non-blocking for request handlers.
- Use small async batches when throughput spikes.
- Fail-open for logging path if business transactions must not block.
- Track dropped-log counters if queue or insert fails.

## MCP Layer Design

MCP tools should be narrow and bounded. The model never receives direct SQL execution.

### Tool 1: `tail_logs`

Purpose: recent events.

Inputs:
- `project` (required)
- `service` (optional)
- `level` (optional)
- `limit` (default 100, max 500)

SQL shape:

```sql
select id, logged_at, level, service, component, message, trace_id
from observability.app_log_events
where project = $1
  and ($2 is null or service = $2)
  and ($3 is null or level = $3)
order by logged_at desc
limit $4;
```

### Tool 2: `search_logs`

Purpose: filtered search over time windows and text.

Inputs:
- `project` (required)
- `service` (optional)
- `level` (optional)
- `trace_id` (optional)
- `q` (optional substring search on `message`)
- `from_ts`, `to_ts` (optional)
- `limit` (default 100, max 500)

SQL shape:

```sql
select id, logged_at, level, service, component, message, trace_id
from observability.app_log_events
where project = $1
  and ($2 is null or service = $2)
  and ($3 is null or level = $3)
  and ($4 is null or trace_id = $4)
  and ($5 is null or logged_at >= $5)
  and ($6 is null or logged_at <= $6)
  and ($7 is null or message ilike ('%' || $7 || '%'))
order by logged_at desc
limit $8;
```

### Tool 3: `get_trace`

Purpose: reconstruct a full execution path.

Inputs:
- `project` (required)
- `trace_id` (required)
- `limit` (default 200, max 2000)

SQL shape:

```sql
select id, logged_at, level, service, component, message, payload
from observability.app_log_events
where project = $1
  and trace_id = $2
order by logged_at asc
limit $3;
```

### Tool 4: `get_context`

Purpose: pull neighboring rows around one event.

Inputs:
- `project` (required)
- `id` (required)
- `before` (default 20, max 200)
- `after` (default 20, max 200)

Implementation note:
- fetch anchor row timestamp first
- query bounded window before and after

## Example MCP Tool Input Schemas

```json
{
  "name": "search_logs",
  "description": "Search logs by project, time, level, service, trace, and text",
  "inputSchema": {
    "type": "object",
    "properties": {
      "project": { "type": "string", "minLength": 1 },
      "service": { "type": "string" },
      "level": {
        "type": "string",
        "enum": ["trace", "debug", "info", "warn", "error", "fatal"]
      },
      "trace_id": { "type": "string" },
      "q": { "type": "string" },
      "from_ts": { "type": "string", "format": "date-time" },
      "to_ts": { "type": "string", "format": "date-time" },
      "limit": { "type": "integer", "minimum": 1, "maximum": 500, "default": 100 }
    },
    "required": ["project"],
    "additionalProperties": false
  }
}
```

## Security Model

### Database roles

```sql
create role log_writer login password 'REPLACE_ME';
create role log_reader login password 'REPLACE_ME';

grant usage on schema observability to log_writer, log_reader;

grant insert on observability.app_log_events to log_writer;
grant select on observability.app_log_events to log_reader;

grant usage, select on sequence observability.app_log_events_id_seq to log_writer;
```

### Session hardening for MCP connections

Set at role or connection level:
- `statement_timeout = '3s'`
- `idle_in_transaction_session_timeout = '5s'`
- read-only transactions for all MCP tool queries

### Tool-level guardrails

- Require `project` in every tool.
- Enforce max `limit`.
- Default time window for wide queries (for example, last 24h).
- Reject empty unconstrained text searches with large limits.

## Retention and Maintenance

### Retention

Initial recommendation: 30 days.

Cleanup statement:

```sql
delete from observability.app_log_events
where logged_at < now() - interval '30 days';
```

### Maintenance cadence

- daily cleanup job
- default autovacuum is enough at this scale
- monitor index bloat quarterly

## Operational Metrics

Track these metrics from day one:
- ingest rate (rows/min)
- ingest failure count
- MCP query latency p50/p95
- MCP query timeout/error count
- storage size by table and index

## Migration Plan from JSONL Files

1. Deploy table and indexes.
2. Add direct PG write in logging path.
3. Keep JSONL emission during transition window.
4. Backfill historical JSONL (optional).
5. Enable MCP tools in development environment.
6. Verify result quality with real debugging tasks.
7. Move to staging and production.
8. Decide whether to keep file logs or disable them.

## Verification Plan

### Functional checks

- `tail_logs` returns newest rows in order.
- `search_logs` respects every filter.
- `get_trace` returns chronological chain.
- `get_context` returns bounded neighbors around target event.

### Safety checks

- MCP user cannot write or alter schema.
- tool requests beyond max limits are rejected.
- statement timeout protects from runaway queries.

### Performance checks

- p95 query latency below 200 ms for common filters at current volume.
- p95 query latency below 500 ms for message substring search.

## Failure Modes and Mitigations

1. DB unavailable during app write
   - mitigation: queue + retry, drop counter, fail-open policy
2. Unbounded model queries
   - mitigation: strict tool schema + hard limits
3. Missing correlation fields (`trace_id`)
   - mitigation: standardize instrumentation in app middleware
4. Query quality drift over time
   - mitigation: add tested query examples in MCP tool docs

## Cost and Capacity Notes

At 5 MiB/day:
- yearly raw event payload remains modest
- PostgreSQL single-node setup is sufficient
- no partitioning requirement in first phase

Trigger to introduce partitioning:
- data volume increase by an order of magnitude
- retention beyond one year with frequent wide time scans

## Recommended Defaults

- one shared table with `project`
- 30-day retention
- four MCP tools only (`tail_logs`, `search_logs`, `get_trace`, `get_context`)
- read-only MCP role
- `limit` max 500 for generic searches

## Implementation Checklist

- [ ] Create `observability` schema and `app_log_events` table
- [ ] Create indexes
- [ ] Create `log_writer` and `log_reader` roles
- [ ] Implement app insert mapping
- [ ] Implement MCP tools with strict input schemas
- [ ] Add SQL sample query catalog for manual triage and MCP parity checks
- [ ] Add statement timeout and query limits
- [ ] Add retention cleanup job
- [ ] Run functional, safety, and latency checks

## Part II: Companion SQL Artifact (Implemented)

Companion file:
- `sql/001_logging_schema.sql`

What this part includes:
- idempotent creation of `observability.app_log_events`
- index set aligned with `tail_logs`, `search_logs`, and `get_trace`
- optional trigram extension/index for message substring search
- read/write role split (`log_writer`, `log_reader`)
- role-level guardrails for MCP reads (`statement_timeout`, `idle_in_transaction_session_timeout`)
- retention helper function `observability.cleanup_old_logs(interval)`

Usage order:
1. apply `sql/001_logging_schema.sql`
2. set credentials for `log_writer` and `log_reader`
3. point application writes to `log_writer`
4. point MCP reads to `log_reader`

## Part III: Companion MCP Server Skeleton (Implemented)

Companion directory:
- repository root (`./`)

Included files:
- `flake.nix`
- `package.json`
- `tsconfig.json`
- `.env.example`
- `src/index.ts`
- `README.md`

Implemented tool surface:
- `tail_logs`
- `search_logs`
- `get_trace`
- `get_context`

Server design notes:
- Nix dev shell (`flake.nix`) pins toolchain for reproducibility (`nodejs_24`, `pnpm`, `postgresql`, shell `zsh`)
- stdio transport for local MCP client integration
- read-only query execution path with parameterized SQL
- hard limits (`LOG_DEFAULT_LIMIT`, `LOG_MAX_LIMIT`) and field validation via Zod
- table identifier validation through `LOG_TABLE` format checks

Quick start (from repository root):
1. `nix develop path:.`
2. `pnpm install`
3. `pnpm run build`
4. `node dist/index.js`

Client configuration example is included in:
- `README.md`

## Part IV: Companion Sample Query Catalog (Implemented)

Companion file:
- `sql/002_sample_queries.sql`

What this part includes:
- tail and filtered search query templates
- trace reconstruction and neighbor context retrieval
- error-rate and noisy-message operational summaries
- retention inspection and cleanup invocation examples

Usage guidance:
1. open `sql/002_sample_queries.sql`
2. update literal filter values for your project/service/time window
3. run the selected query in `psql` or your SQL client
4. compare SQL results against MCP tool outputs during verification

## Appendix A: Example Prompt to MCP

"Show errors for `project=my_app`, `service=api`, last 30 minutes, max 100 rows."

Expected MCP behavior:
1. route to `search_logs`
2. set `from_ts = now - 30m`
3. set `level = error`
4. cap `limit = 100`
5. return rows sorted newest first

## Appendix B: Future Extensions

- add `count_logs` tool for quick aggregate summaries
- add payload-field filter tool for known keys
- add lightweight dashboards over same table
- add row-level access control if project isolation requirements increase
