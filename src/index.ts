import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { Pool, type QueryResultRow } from 'pg';
import { z } from 'zod';

const LEVELS = ['trace', 'debug', 'info', 'warn', 'error', 'fatal'] as const;
const levelSchema = z.enum(LEVELS);

function parsePositiveInt(input: string | undefined, fallback: number): number {
  if (!input) {
    return fallback;
  }
  const parsed = Number.parseInt(input, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }
  return parsed;
}

function normalizeText(input: string | undefined): string | null {
  if (!input) {
    return null;
  }
  const trimmed = input.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizeDate(input: string | undefined): string | null {
  if (!input) {
    return null;
  }
  const parsed = new Date(input);
  if (Number.isNaN(parsed.getTime())) {
    throw new Error(`Invalid date-time value: ${input}`);
  }
  return parsed.toISOString();
}

function parseQualifiedTable(input: string): string {
  const validPattern = /^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$/;
  if (!validPattern.test(input)) {
    throw new Error('LOG_TABLE must be in the format schema.table using only letters, numbers, and underscores.');
  }
  return input;
}

const LOG_TABLE = parseQualifiedTable(process.env.LOG_TABLE ?? 'observability.app_log_events');
const DEFAULT_LIMIT = parsePositiveInt(process.env.LOG_DEFAULT_LIMIT, 100);
const MAX_LIMIT = parsePositiveInt(process.env.LOG_MAX_LIMIT, 500);

if (DEFAULT_LIMIT > MAX_LIMIT) {
  throw new Error('LOG_DEFAULT_LIMIT cannot be larger than LOG_MAX_LIMIT.');
}

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  application_name: 'mcp-logging-pgsql-server'
});

type LogRow = {
  id: string;
  logged_at: string;
  level: string;
  service: string;
  component: string | null;
  message: string;
  trace_id: string | null;
  payload?: unknown;
};

async function runReadOnlyQuery<T extends QueryResultRow>(sql: string, values: readonly unknown[]): Promise<T[]> {
  const client = await pool.connect();
  try {
    await client.query('begin read only');
    const result = await client.query<T>(sql, values as unknown[]);
    await client.query('commit');
    return result.rows;
  } catch (error) {
    try {
      await client.query('rollback');
    } catch {
      // Ignore rollback failures.
    }
    throw error;
  } finally {
    client.release();
  }
}

function clampLimit(input: number | undefined): number {
  if (input === undefined) {
    return DEFAULT_LIMIT;
  }
  return Math.min(Math.max(input, 1), MAX_LIMIT);
}

function formatOutput(rows: readonly LogRow[]): { content: [{ type: 'text'; text: string }]; structuredContent: { count: number; rows: readonly LogRow[] } } {
  const structuredContent = { count: rows.length, rows };
  return {
    content: [{ type: 'text', text: JSON.stringify(structuredContent, null, 2) }],
    structuredContent
  };
}

const server = new McpServer({
  name: 'logging-pgsql',
  version: '0.1.0'
});

server.registerTool(
  'tail_logs',
  {
    title: 'Tail logs',
    description: 'Return newest log rows with optional service and level filters.',
    inputSchema: {
      project: z.string().min(1),
      service: z.string().min(1).optional(),
      level: levelSchema.optional(),
      limit: z.number().int().min(1).max(MAX_LIMIT).optional()
    }
  },
  async ({ project, service, level, limit }) => {
    const rows = await runReadOnlyQuery<LogRow>(
      `
      select id, logged_at, level, service, component, message, trace_id
      from ${LOG_TABLE}
      where project = $1
        and ($2::text is null or service = $2)
        and ($3::text is null or level = $3)
      order by logged_at desc
      limit $4
      `,
      [project, normalizeText(service), level ?? null, clampLimit(limit)]
    );

    return formatOutput(rows);
  }
);

server.registerTool(
  'search_logs',
  {
    title: 'Search logs',
    description: 'Search logs by project, time range, level, service, trace id, and message substring.',
    inputSchema: {
      project: z.string().min(1),
      service: z.string().min(1).optional(),
      level: levelSchema.optional(),
      trace_id: z.string().min(1).optional(),
      q: z.string().min(1).optional(),
      from_ts: z.string().optional(),
      to_ts: z.string().optional(),
      limit: z.number().int().min(1).max(MAX_LIMIT).optional()
    }
  },
  async ({ project, service, level, trace_id, q, from_ts, to_ts, limit }) => {
    const rows = await runReadOnlyQuery<LogRow>(
      `
      select id, logged_at, level, service, component, message, trace_id
      from ${LOG_TABLE}
      where project = $1
        and ($2::text is null or service = $2)
        and ($3::text is null or level = $3)
        and ($4::text is null or trace_id = $4)
        and ($5::timestamptz is null or logged_at >= $5)
        and ($6::timestamptz is null or logged_at <= $6)
        and ($7::text is null or message ilike ('%' || $7 || '%'))
      order by logged_at desc
      limit $8
      `,
      [
        project,
        normalizeText(service),
        level ?? null,
        normalizeText(trace_id),
        normalizeDate(from_ts),
        normalizeDate(to_ts),
        normalizeText(q),
        clampLimit(limit)
      ]
    );

    return formatOutput(rows);
  }
);

server.registerTool(
  'get_trace',
  {
    title: 'Get trace',
    description: 'Return all rows for a trace id in chronological order.',
    inputSchema: {
      project: z.string().min(1),
      trace_id: z.string().min(1),
      limit: z.number().int().min(1).max(2000).optional()
    }
  },
  async ({ project, trace_id, limit }) => {
    const effectiveLimit = Math.min(clampLimit(limit), 2000);

    const rows = await runReadOnlyQuery<LogRow>(
      `
      select id, logged_at, level, service, component, message, trace_id, payload
      from ${LOG_TABLE}
      where project = $1
        and trace_id = $2
      order by logged_at asc
      limit $3
      `,
      [project, trace_id, effectiveLimit]
    );

    return formatOutput(rows);
  }
);

server.registerTool(
  'get_context',
  {
    title: 'Get context',
    description: 'Return neighboring rows around a specific event id.',
    inputSchema: {
      project: z.string().min(1),
      id: z.union([z.number().int().positive(), z.string().min(1)]),
      before: z.number().int().min(0).max(200).optional(),
      after: z.number().int().min(0).max(200).optional()
    }
  },
  async ({ project, id, before, after }) => {
    const beforeCount = before ?? 20;
    const afterCount = after ?? 20;
    const targetId = typeof id === 'number' ? String(id) : id;

    const anchors = await runReadOnlyQuery<LogRow>(
      `
      select id, logged_at, level, service, component, message, trace_id, payload
      from ${LOG_TABLE}
      where project = $1
        and id = $2
      limit 1
      `,
      [project, targetId]
    );

    if (anchors.length === 0) {
      throw new Error(`No log row found for project='${project}' and id='${targetId}'.`);
    }

    const anchor = anchors[0];

    const beforeRows = await runReadOnlyQuery<LogRow>(
      `
      select id, logged_at, level, service, component, message, trace_id, payload
      from ${LOG_TABLE}
      where project = $1
        and logged_at < $2
      order by logged_at desc
      limit $3
      `,
      [project, anchor.logged_at, beforeCount]
    );

    const afterRows = await runReadOnlyQuery<LogRow>(
      `
      select id, logged_at, level, service, component, message, trace_id, payload
      from ${LOG_TABLE}
      where project = $1
        and logged_at > $2
      order by logged_at asc
      limit $3
      `,
      [project, anchor.logged_at, afterCount]
    );

    const rows = [...beforeRows.reverse(), anchor, ...afterRows];
    return formatOutput(rows);
  }
);

async function shutdown(signal: string): Promise<void> {
  process.stderr.write(`[logging-pgsql] Received ${signal}, shutting down.\n`);
  await pool.end();
  process.exit(0);
}

process.on('SIGINT', () => {
  void shutdown('SIGINT');
});

process.on('SIGTERM', () => {
  void shutdown('SIGTERM');
});

async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write(`[logging-pgsql] Ready on stdio using table ${LOG_TABLE}.\n`);
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
  process.stderr.write(`[logging-pgsql] Fatal error: ${message}\n`);
  void pool.end();
  process.exit(1);
});
