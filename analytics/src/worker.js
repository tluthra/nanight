import { dashboard } from './dashboard.js';

const headers = {
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
};

const response = (body, status = 200, extra = {}) => new Response(body, {
  status, headers: { ...headers, ...extra },
});

export function dayAt(date, offset = 0) {
  return new Date(date.getTime() + offset * 86_400_000).toISOString().slice(0, 10);
}

export function validPayload(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).sort().join(',') === 'app_version,installation_id,macos_version'
    && typeof value.installation_id === 'string'
    && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value.installation_id)
    && typeof value.app_version === 'string' && /^\d{1,4}(\.\d{1,4}){0,3}$/.test(value.app_version)
    && typeof value.macos_version === 'string' && /^\d{1,3}$/.test(value.macos_version);
}

async function readPayload(request) {
  if (!request.body) throw new Error('empty');
  const reader = request.body.getReader();
  const chunks = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > 512) {
      await reader.cancel();
      throw new RangeError('too large');
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder().decode(bytes));
}

async function digest(value) {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
}

async function authorized(request, password) {
  const expected = `Basic ${btoa(`nanight:${password}`)}`;
  const actual = request.headers.get('Authorization') ?? '';
  const [a, b] = await Promise.all([digest(actual), digest(expected)]);
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}

export async function collect(request, env, now = new Date()) {
  if (request.headers.get('Content-Type')?.split(';')[0].trim() !== 'application/json') {
    return response('Expected JSON', 415);
  }
  // Used transiently for throttling, never stored in D1 or application logs.
  const ipHash = Array.from(await digest(request.headers.get('CF-Connecting-IP') ?? 'local'),
    byte => byte.toString(16).padStart(2, '0')).join('');
  const { success } = await env.PING_RATE_LIMIT.limit({ key: ipHash });
  if (!success) return response('Too many requests', 429, { 'Retry-After': '60' });

  let payload;
  try { payload = await readPayload(request); }
  catch (error) { return response('Invalid payload', error instanceof RangeError ? 413 : 400); }
  if (!validPayload(payload)) return response('Invalid payload', 400);

  await env.DB.prepare(`INSERT INTO daily_usage (day, installation_id, app_version, macos_version)
    VALUES (?, ?, ?, ?) ON CONFLICT (day, installation_id) DO NOTHING`)
    .bind(dayAt(now), payload.installation_id.toLowerCase(), payload.app_version, payload.macos_version).run();
  return response(null, 204);
}

export async function prune(env, now = new Date()) {
  const cutoff = dayAt(now, -89);
  // D1 batch is transactional: aggregate before removing installation records.
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO daily_totals (day, installations)
      SELECT day, COUNT(*) FROM daily_usage WHERE day < ? GROUP BY day
      ON CONFLICT (day) DO UPDATE SET installations = excluded.installations`).bind(cutoff),
    env.DB.prepare('DELETE FROM daily_usage WHERE day < ?').bind(cutoff),
  ]);
}

export async function stats(env, now = new Date()) {
  const today = dayAt(now);
  const [active, daily, versions] = await env.DB.batch([
    env.DB.prepare(`SELECT
      COUNT(DISTINCT CASE WHEN day = ? THEN installation_id END) AS daily,
      COUNT(DISTINCT CASE WHEN day >= ? THEN installation_id END) AS weekly,
      COUNT(DISTINCT installation_id) AS monthly
      FROM daily_usage WHERE day >= ? AND day <= ?`)
      .bind(today, dayAt(now, -6), dayAt(now, -29), today),
    env.DB.prepare(`SELECT day, COUNT(*) AS installations FROM daily_usage
      WHERE day >= ? AND day <= ? GROUP BY day
      UNION ALL SELECT day, installations FROM daily_totals WHERE day >= ? AND day <= ?
      ORDER BY day DESC`).bind(dayAt(now, -364), today, dayAt(now, -364), today),
    env.DB.prepare(`SELECT app_version, macos_version, COUNT(*) AS installations FROM (
      SELECT app_version, macos_version,
        ROW_NUMBER() OVER (PARTITION BY installation_id ORDER BY day DESC) AS latest
      FROM daily_usage WHERE day >= ? AND day <= ?
    ) WHERE latest = 1 GROUP BY app_version, macos_version ORDER BY installations DESC`)
      .bind(dayAt(now, -29), today),
  ]);
  return { today, active: active.results[0], daily: daily.results, versions: versions.results };
}

export default {
  async fetch(request, env) {
    try {
      const path = new URL(request.url).pathname;
      if (path === '/v1/ping') {
        return request.method === 'POST' ? await collect(request, env)
          : response('Method not allowed', 405, { Allow: 'POST' });
      }
      if (path !== '/' || request.method !== 'GET') return response('Not found', 404);
      if (!env.DASHBOARD_PASSWORD) return response('Dashboard not configured', 503);
      if (!(await authorized(request, env.DASHBOARD_PASSWORD))) {
        return response('Authentication required', 401, { 'WWW-Authenticate': 'Basic realm="Nanight analytics", charset="UTF-8"' });
      }
      return response(dashboard(await stats(env)), 200, { 'Content-Type': 'text/html; charset=utf-8' });
    } catch {
      // Do not log request bodies, IDs, credentials, or connection metadata.
      return response('Temporarily unavailable', 503);
    }
  },
  async scheduled(_controller, env) { await prune(env); },
};
