# mcp-logging-pgsql-server

Minimal stdio MCP server for querying PostgreSQL log events.

## Tools

- `tail_logs`
- `search_logs`
- `get_trace`
- `get_context`

## Quick Start

0. Enter the Nix dev shell:
   - `nix develop path:.`
1. Create schema and roles:
   - run `sql/001_logging_schema.sql` from the repository root (or use the absolute path)
   - optional: use `sql/002_sample_queries.sql` for SQL-side verification against MCP outputs
2. Install dependencies:
   - `pnpm install`
3. Build:
   - `pnpm run build`
4. Run:
   - `pnpm run start`

## Nix Dev Shell

This repository includes a `flake.nix` dev shell with:
- `nodejs_24`
- `pnpm`
- `postgresql` (`psql`, `pg_ctl`, `initdb`)
- `git`, `curl`, `jq`
- shell set to `zsh`

## Environment

Use `.env.example` as reference.

Required in most setups:
- `DATABASE_URL` with read-only credentials (`log_reader`)

Optional:
- `LOG_TABLE` (default: `observability.app_log_events`)
- `LOG_DEFAULT_LIMIT` (default: `100`)
- `LOG_MAX_LIMIT` (default: `500`)

## Claude Desktop MCP Config Example

```json
{
  "mcpServers": {
    "logging-pgsql": {
      "command": "node",
      "args": ["/home/chuck/git/mcp-logging-pgsql-server/dist/index.js"],
      "env": {
        "DATABASE_URL": "postgresql://log_reader:change_me@127.0.0.1:5432/app_logs",
        "LOG_TABLE": "observability.app_log_events",
        "LOG_DEFAULT_LIMIT": "100",
        "LOG_MAX_LIMIT": "500"
      }
    }
  }
}
```
