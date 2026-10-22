import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import worker, { collect, dayAt, prune, stats } from '../src/worker.js';

const id = 'fca2bea4-7185-4dab-b302-42f4ecb84a6b';
const payload = { installation_id: id, app_version: '0.0.9', macos_version: '26' };
const now = new Date('2026-10-21T12:00:00Z');
const request = (body = payload, options = {}) => new Request('https://analytics.example/v1/ping', {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), ...options,
});

async function fixture(t) {
  const mf = new Miniflare(convertV4MiniflareOptions({
    cf: false,
    modules: ['worker.js', 'dashboard.js'].map(name => ({
      type: 'ESModule', path: new URL(`../src/${name}`, import.meta.url).pathname,
    })),
    compatibilityDate: '2026-10-21', d1Databases: ['DB'],
    bindings: { DASHBOARD_PASSWORD: 'test-password' },
    ratelimits: { PING_RATE_LIMIT: { namespace_id: '1001', simple: { limit: 60, period: 60 } } },
  }));
  t.after(() => mf.dispose());
  const DB = await mf.getD1Database('DB');
  const schema = await readFile(new URL('../migrations/0001_usage.sql', import.meta.url), 'utf8');
  for (const statement of schema.split(';').filter(part => part.trim())) await DB.prepare(statement).run();
  return { mf, env: { DB, PING_RATE_LIMIT: { limit: async () => ({ success: true }) }, DASHBOARD_PASSWORD: 'test-password' } };
}

test('real Worker accepts daily pings, deduplicates, and protects the dashboard', async t => {
  const { mf, env } = await fixture(t);
  for (let i = 0; i < 2; i++) assert.equal((await mf.dispatchFetch('https://analytics.example/v1/ping', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload),
  })).status, 204);
  assert.equal((await env.DB.prepare('SELECT COUNT(*) AS n FROM daily_usage').first()).n, 1);
  assert.equal((await mf.dispatchFetch('https://analytics.example/')).status, 401);
  assert.equal((await mf.dispatchFetch('https://analytics.example/', { headers: { Authorization: `Basic ${btoa('nanight:wrong')}` } })).status, 401);
  const dashboard = await mf.dispatchFetch('https://analytics.example/', { headers: { Authorization: `Basic ${btoa('nanight:test-password')}` } });
  assert.equal(dashboard.status, 200);
  assert.equal(dashboard.headers.get('Cache-Control'), 'no-store');
  const html = await dashboard.text();
  assert.ok(html.includes('Usage at a glance'));
  assert.ok(html.includes('0.0.9'));
  assert.ok(!html.includes(id));
  assert.equal((await mf.dispatchFetch('https://analytics.example/v1/ping')).status, 405);
});

test('rejects unknown fields, malformed values, oversized bodies, and rate limited requests', async t => {
  const { env } = await fixture(t);
  for (const invalid of [null, [], { ...payload, email: 'private@example.com' }, { ...payload, installation_id: 'not-a-uuid' },
    { ...payload, app_version: '<script>' }, { ...payload, macos_version: '26.1' }]) {
    assert.equal((await collect(request(invalid), env, now)).status, 400);
  }
  assert.equal((await collect(request(payload, { body: '{' }), env, now)).status, 400);
  assert.equal((await collect(request(payload, { body: 'x'.repeat(513) }), env, now)).status, 413);
  assert.equal((await collect(request(payload, { headers: {} }), env, now)).status, 415);
  assert.equal((await collect(request(), { ...env, PING_RATE_LIMIT: { limit: async () => ({ success: false }) } }, now)).status, 429);
  assert.equal((await env.DB.prepare('SELECT COUNT(*) AS n FROM daily_usage').first()).n, 0);
  assert.equal((await worker.fetch(new Request('https://analytics.example/'), { ...env, DASHBOARD_PASSWORD: undefined })).status, 503);
});

test('counts unique installations across periods and uses each installation’s latest version', async t => {
  const { env } = await fixture(t);
  const secondID = '9a58b77a-1e0e-458f-a2ee-2033bfa3ff4b';
  await collect(request(payload), env, new Date('2026-09-22T01:00:00Z'));
  await collect(request({ ...payload, app_version: '0.0.10' }), env, now);
  await collect(request({ ...payload, installation_id: secondID }), env, new Date('2026-10-15T23:00:00Z'));
  // Uppercase IDs represent the same installation and must deduplicate.
  await collect(request({ ...payload, installation_id: id.toUpperCase() }), env, now);
  const result = await stats(env, now);
  assert.deepEqual(result.active, { daily: 1, weekly: 2, monthly: 2 });
  assert.equal(result.versions.length, 2);
  assert.equal(result.versions.reduce((sum, row) => sum + row.installations, 0), 2);
  assert.equal(result.daily.find(row => row.day === '2026-10-21').installations, 1);
});

test('retention removes identifiers after 90 UTC dates and preserves aggregate counts idempotently', async t => {
  const { env } = await fixture(t);
  for (const daysAgo of [89, 90, 91]) {
    await collect(request(), env, new Date(`${dayAt(now, -daysAgo)}T12:00:00Z`));
  }
  await prune(env, now);
  await prune(env, now);
  const { results } = await env.DB.prepare('SELECT * FROM daily_usage').all();
  assert.equal(results.length, 1);
  assert.equal(results[0].day, dayAt(now, -89));
  const totals = await env.DB.prepare('SELECT * FROM daily_totals ORDER BY day').all();
  assert.equal(totals.results.length, 2);
  assert.deepEqual(Object.keys(totals.results[0]).sort(), ['day', 'installations']);
  assert.equal(totals.results[0].installations, 1);
  assert.equal((await stats(env, now)).daily.length, 3);
});
