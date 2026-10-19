import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker, { _resetLimiter } from '../src/index.js';
import { RateLimiter, mapAiError, safeEqual, validateBody, nextUtcMidnight } from '../src/lib.js';

const SECRET = 'test-secret-123';
const JPEG_B64 = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]).toString('base64');

function env(aiImpl) {
  const calls = [];
  return {
    calls,
    APP_SHARED_SECRET: SECRET,
    RATE_LIMIT_PER_MINUTE: '6',
    AI: { run: async (model, input) => { calls.push({ model, input }); return aiImpl(model, input); } },
  };
}
const ok = () => ({ image: JPEG_B64 });

function req(body, { secret = SECRET, method = 'POST', path = '/generate', ip = '1.2.3.4', accept } = {}) {
  const headers = { 'content-type': 'application/json', 'cf-connecting-ip': ip };
  if (secret !== null) headers['x-app-secret'] = secret;
  if (accept) headers.accept = accept;
  return new Request(`https://w.example${path}`, {
    method, headers, body: method === 'GET' ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
  });
}

test('generate success returns base64 JSON, passes steps, drops seed (schema rejects it)', async () => {
  _resetLimiter();
  const e = env(ok);
  const r = await worker.fetch(req({ prompt: ' a cat ', steps: 6, seed: 42, width: 512 }), e);
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.image, JPEG_B64);
  assert.equal(j.seed, null);
  assert.equal(j.seedIgnored, true);
  assert.match(j.note, /width ignored/);
  assert.deepEqual(e.calls[0], { model: '@cf/black-forest-labs/flux-1-schnell', input: { prompt: 'a cat', steps: 6 } });
});

test('default steps is 4 and seed omitted', async () => {
  _resetLimiter();
  const e = env(ok);
  await worker.fetch(req({ prompt: 'x' }), e);
  assert.deepEqual(e.calls[0].input, { prompt: 'x', steps: 4 });
});

test('Accept: image/jpeg returns raw bytes', async () => {
  _resetLimiter();
  const r = await worker.fetch(req({ prompt: 'x' }, { accept: 'image/jpeg' }), env(ok));
  assert.equal(r.headers.get('content-type'), 'image/jpeg');
  const b = new Uint8Array(await r.arrayBuffer());
  assert.equal(b[0], 0xff);
});

test('missing / wrong secret -> 401 unauthorized', async () => {
  _resetLimiter();
  for (const s of [null, 'nope']) {
    const r = await worker.fetch(req({ prompt: 'x' }, { secret: s }), env(ok));
    assert.equal(r.status, 401);
    assert.equal((await r.json()).error.code, 'unauthorized');
  }
});

test('secret not configured -> 500 not_configured', async () => {
  const e = env(ok); delete e.APP_SHARED_SECRET;
  const r = await worker.fetch(req({ prompt: 'x' }), e);
  assert.equal(r.status, 500);
  assert.equal((await r.json()).error.code, 'not_configured');
});

test('validation errors -> 400 bad_request', async () => {
  const bad = [{}, { prompt: '' }, { prompt: 'x'.repeat(2049) }, { prompt: 'x', steps: 0 }, { prompt: 'x', steps: 9 },
    { prompt: 'x', steps: 2.5 }, { prompt: 'x', seed: -1 }, { prompt: 'x', seed: 'a' }, [1], 'not json'];
  for (const b of bad) {
    _resetLimiter();
    const r = await worker.fetch(req(b), env(ok));
    assert.equal(r.status, 400, JSON.stringify(b).slice(0, 40));
    assert.equal((await r.json()).error.code, 'bad_request');
  }
});

test('routing: GET /generate 405, unknown path 404, /health ok', async () => {
  assert.equal((await worker.fetch(req(null, { method: 'GET' }), env(ok))).status, 405);
  assert.equal((await worker.fetch(req({}, { path: '/x' }), env(ok))).status, 404);
  const h = await worker.fetch(req(null, { method: 'GET', path: '/health' }), env(ok));
  assert.equal(h.status, 200);
  assert.equal((await h.json()).ok, true);
  assert.equal((await worker.fetch(req(null, { method: 'GET', path: '/health', secret: 'bad' }), env(ok))).status, 401);
});

test('daily free allocation error -> 429 quota with resetsAt', async () => {
  _resetLimiter();
  const e = env(() => { throw new Error('4006: you have used up your daily free allocation of 10,000 neurons, please upgrade'); });
  const r = await worker.fetch(req({ prompt: 'x' }), e);
  assert.equal(r.status, 429);
  const j = await r.json();
  assert.equal(j.error.code, 'quota');
  assert.ok(j.error.resetsAt.endsWith('T00:00:00.000Z'));
});

test('AI error mapping', () => {
  assert.equal(mapAiError(new Error('3040: Capacity temporarily exceeded')).code, 'upstream');
  assert.equal(mapAiError(new Error('Request timed out')).code, 'upstream_timeout');
  assert.equal(mapAiError(new Error('NSFW content detected')).code, 'content_filtered');
  assert.equal(mapAiError(new Error('boom')).status, 502);
});

test('empty AI output -> 502 upstream', async () => {
  _resetLimiter();
  const r = await worker.fetch(req({ prompt: 'x' }), env(() => ({})));
  assert.equal(r.status, 502);
  assert.equal((await r.json()).error.code, 'upstream');
});

test('per-IP rate limit -> 429 rate_limited with Retry-After', async () => {
  _resetLimiter();
  const e = env(ok);
  for (let i = 0; i < 6; i++) assert.equal((await worker.fetch(req({ prompt: 'x' }, { ip: '9.9.9.9' }), e)).status, 200);
  const r = await worker.fetch(req({ prompt: 'x' }, { ip: '9.9.9.9' }), e);
  assert.equal(r.status, 429);
  assert.ok(Number(r.headers.get('retry-after')) >= 1);
  assert.equal((await r.json()).error.code, 'rate_limited');
  assert.equal((await worker.fetch(req({ prompt: 'x' }, { ip: '8.8.8.8' }), e)).status, 200);
});

test('RateLimiter window resets', () => {
  let t = 0;
  const l = new RateLimiter(1, 1000, () => t);
  l.check('a');
  assert.throws(() => l.check('a'));
  t = 1000;
  l.check('a');
});

test('helpers', () => {
  assert.ok(safeEqual('abc', 'abc'));
  assert.ok(!safeEqual('abc', 'abd'));
  assert.ok(!safeEqual('abc', 'abcd'));
  assert.equal(nextUtcMidnight(new Date('2026-10-19T23:59:00Z')).toISOString(), '2026-10-20T00:00:00.000Z');
  assert.deepEqual(validateBody({ prompt: 'p', height: 1 }).ignored, ['height']);
});
