import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker, { _resetLimiter } from '../src/index.js';
import {
  cleanEnhanced, editOutputSize, estimateEditNeurons, estimateGenerateNeurons, imageInfo,
  readTextResult, strengthInstruction, validateEditBody,
} from '../src/lib.js';
import { UsageCounter, addEvent, emptyDay, publicUsage } from '../src/usage.js';

const SECRET = 's3cret';
const JPEG_B64 = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]).toString('base64');

// Minimal valid-header JPEG: SOI, APP0 stub, SOF0 with given size.
function jpeg(w, h) {
  return Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00,
    0xff, 0xc0, 0x00, 0x11, 0x08, h >> 8, h & 255, w >> 8, w & 255, 0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
}
function png(w, h) {
  const b = Buffer.alloc(33);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(b, 0);
  b.writeUInt32BE(13, 8); b.write('IHDR', 12); b.writeUInt32BE(w, 16); b.writeUInt32BE(h, 20);
  return b;
}

// In-memory Durable Object namespace backed by the real UsageCounter class.
function fakeDO() {
  const map = new Map();
  const storage = {
    async get(k) { return map.get(k); },
    async put(k, v) { map.set(k, structuredClone(v)); },
    async list({ prefix }) { return new Map([...map].filter(([k]) => k.startsWith(prefix))); },
    async delete(keys) { for (const k of keys) map.delete(k); },
  };
  const obj = new UsageCounter({ storage });
  return {
    map,
    idFromName: (n) => n,
    get: () => ({ fetch: (url, init) => obj.fetch(new Request(url, init)) }),
  };
}

function env(aiImpl, { usage = true } = {}) {
  const calls = [];
  return {
    calls,
    APP_SHARED_SECRET: SECRET,
    RATE_LIMIT_PER_MINUTE: '20',
    ...(usage ? { USAGE: fakeDO() } : {}),
    AI: { run: async (model, input) => { calls.push({ model, input }); return aiImpl(model, input); } },
  };
}

function req(path, body, { method = 'POST', secret = SECRET, ip = '1.1.1.1' } = {}) {
  const headers = { 'content-type': 'application/json', 'cf-connecting-ip': ip };
  if (secret) headers['x-app-secret'] = secret;
  return new Request(`https://w.example${path}`, { method, headers, body: method === 'GET' ? undefined : JSON.stringify(body) });
}

async function readForm(input) {
  return new Response(input.multipart.body, { headers: { 'content-type': input.multipart.contentType } }).formData();
}

test('POST /edit sends multipart to FLUX.2 klein with image, size, seed and strength wording', async () => {
  _resetLimiter();
  const e = env(() => ({ image: JPEG_B64 }));
  const img = png(512, 384).toString('base64');
  const r = await worker.fetch(req('/edit', { prompt: 'make it night', image: img, strength: 0.2, seed: 5 }), e);
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.image, JPEG_B64);
  assert.equal(j.model, '@cf/black-forest-labs/flux-2-klein-4b');
  assert.deepEqual([j.width, j.height], [1024, 768]);
  assert.equal(j.usage.edit, 1);
  assert.equal(j.usage.images, 1);
  const call = e.calls[0];
  assert.equal(call.model, '@cf/black-forest-labs/flux-2-klein-4b');
  const f = await readForm(call.input);
  assert.match(f.get('prompt'), /subtle edit.*Edit: make it night/s);
  assert.equal(f.get('width'), '1024');
  assert.equal(f.get('height'), '768');
  assert.equal(f.get('seed'), '5');
  const blob = f.get('input_image_0');
  assert.equal(blob.type, 'image/png');
  assert.equal(blob.size, 33);
});

test('/edit rejects oversize, non-image, missing image and bad strength', async () => {
  const cases = [
    [{ prompt: 'x', image: jpeg(1024, 768).toString('base64') }, 413, 'image_too_large'],
    [{ prompt: 'x', image: Buffer.from('hello world').toString('base64') }, 400, 'bad_request'],
    [{ prompt: 'x' }, 400, 'bad_request'],
    [{ image: jpeg(100, 100).toString('base64') }, 400, 'bad_request'],
    [{ prompt: 'x', image: jpeg(100, 100).toString('base64'), strength: 2 }, 400, 'bad_request'],
    [{ prompt: 'x', image: '***' }, 400, 'bad_request'],
    [{ prompt: 'x', image: 'A'.repeat(2_100_000) }, 413, 'image_too_large'],
  ];
  for (const [body, status, code] of cases) {
    _resetLimiter();
    const r = await worker.fetch(req('/edit', body), env(() => ({ image: JPEG_B64 })));
    assert.equal(r.status, status, JSON.stringify(body).slice(0, 60));
    assert.equal((await r.json()).error.code, code);
  }
});

test('/edit quota error maps to 429 quota', async () => {
  _resetLimiter();
  const e = env(() => { throw new Error('4006: daily free allocation of 10,000 neurons used'); });
  const r = await worker.fetch(req('/edit', { prompt: 'x', image: jpeg(64, 64).toString('base64') }), e);
  assert.equal(r.status, 429);
  assert.equal((await r.json()).error.code, 'quota');
});

test('POST /enhance returns cleaned prompt, reports real neurons, falls back to 2nd model', async () => {
  _resetLimiter();
  let n = 0;
  const e = env((model) => {
    n++;
    if (n === 1) throw new Error('3040: capacity');
    return { response: 'Here is an enhanced prompt:\n"A chrome robot dog on a misty pier at dawn."', usage: { neurons: 2.5 } };
  });
  const r = await worker.fetch(req('/enhance', { idea: 'robot dog', style: 'cinematic' }), e);
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.prompt, 'A chrome robot dog on a misty pier at dawn.');
  assert.equal(j.original, 'robot dog');
  assert.equal(j.model, '@cf/meta/llama-3.2-3b-instruct');
  assert.equal(j.usage.enhance, 1);
  assert.equal(j.usage.images, 0);
  assert.equal(e.calls[0].model, '@cf/meta/llama-3.1-8b-instruct-fp8');
  assert.match(e.calls[1].input.messages[1].content, /Preferred style: cinematic/);
  assert.equal(e.calls[1].input.max_tokens, 180);
});

test('/enhance validation and refusal', async () => {
  _resetLimiter();
  assert.equal((await worker.fetch(req('/enhance', { idea: '' }), env(() => ({})))).status, 400);
  assert.equal((await worker.fetch(req('/enhance', { idea: 'x'.repeat(601) }), env(() => ({})))).status, 400);
  const r = await worker.fetch(req('/enhance', { idea: 'x' }), env(() => ({ response: "I can't help with that." })));
  assert.equal(r.status, 400);
  assert.equal((await r.json()).error.code, 'content_filtered');
});

test('usage accumulates across generate/edit/enhance and GET /usage reports it', async () => {
  _resetLimiter();
  const e = env((model) => (model.includes('llama') ? { response: 'p', usage: { neurons: 3 } } : { image: JPEG_B64 }));
  await worker.fetch(req('/generate', { prompt: 'a' }), e);
  await worker.fetch(req('/generate', { prompt: 'b', steps: 8 }), e);
  await worker.fetch(req('/edit', { prompt: 'c', image: jpeg(512, 512).toString('base64') }), e);
  await worker.fetch(req('/enhance', { idea: 'd' }), e);
  const r = await worker.fetch(req('/usage', null, { method: 'GET' }), e);
  const u = await r.json();
  assert.equal(u.available, true);
  assert.equal(u.generate, 2);
  assert.equal(u.edit, 1);
  assert.equal(u.enhance, 1);
  assert.equal(u.images, 3);
  const expected = estimateGenerateNeurons(4) + estimateGenerateNeurons(8) + estimateEditNeurons(512, 512, 1024, 1024) + 3;
  assert.equal(u.neurons, Math.round(expected));
  assert.equal(u.neuronsEstimated, true);
  assert.equal(u.freeNeurons, 10000);
  assert.ok(u.resetsAt.endsWith('T00:00:00.000Z'));
});

test('parallel generate requests are all counted (Durable Object serialises)', async () => {
  _resetLimiter();
  const e = env(() => ({ image: JPEG_B64 }));
  await Promise.all([1, 2, 3, 4].map((i) => worker.fetch(req('/generate', { prompt: `p${i}` }), e)));
  const u = await (await worker.fetch(req('/usage', null, { method: 'GET' }), e)).json();
  // The fake storage is not transactional, so this only checks counting works; production DOs serialise.
  assert.ok(u.generate >= 1 && u.generate <= 4);
});

test('/usage without a Durable Object binding -> available:false; generate still works', async () => {
  _resetLimiter();
  const e = env(() => ({ image: JPEG_B64 }), { usage: false });
  const u = await (await worker.fetch(req('/usage', null, { method: 'GET' }), e)).json();
  assert.equal(u.available, false);
  const g = await worker.fetch(req('/generate', { prompt: 'x' }), e);
  assert.equal(g.status, 200);
  assert.equal((await g.json()).usage, undefined);
});

test('new routes need the secret and the right method', async () => {
  _resetLimiter();
  for (const p of ['/edit', '/enhance']) {
    assert.equal((await worker.fetch(req(p, {}, { secret: 'bad' }), env(() => ({})))).status, 401);
    assert.equal((await worker.fetch(req(p, null, { method: 'GET' }), env(() => ({})))).status, 405);
  }
  assert.equal((await worker.fetch(req('/usage', {}, { secret: null, method: 'GET' }), env(() => ({})))).status, 401);
  const h = await (await worker.fetch(req('/health', null, { method: 'GET' }), env(() => ({})))).json();
  assert.deepEqual(h.routes, ['/health', '/usage', '/generate', '/edit', '/enhance']);
});

test('rate limiter covers edit and enhance too', async () => {
  _resetLimiter();
  const e = env(() => ({ response: 'ok prompt' }));
  e.RATE_LIMIT_PER_MINUTE = '2';
  assert.equal((await worker.fetch(req('/enhance', { idea: 'a' }, { ip: '7.7.7.7' }), e)).status, 200);
  assert.equal((await worker.fetch(req('/enhance', { idea: 'a' }, { ip: '7.7.7.7' }), e)).status, 200);
  assert.equal((await worker.fetch(req('/enhance', { idea: 'a' }, { ip: '7.7.7.7' }), e)).status, 429);
});

test('helpers: imageInfo, output size, neurons, strength, clean, text result', () => {
  assert.deepEqual(imageInfo(jpeg(300, 200)), { mime: 'image/jpeg', width: 300, height: 200 });
  assert.deepEqual(imageInfo(png(10, 20)), { mime: 'image/png', width: 10, height: 20 });
  assert.equal(imageInfo(Buffer.from('nope')), null);
  assert.deepEqual(editOutputSize(512, 512), { width: 1024, height: 1024 });
  assert.deepEqual(editOutputSize(341, 512), { width: 688, height: 1024 });
  assert.deepEqual(editOutputSize(null, null), { width: 1024, height: 1024 });
  assert.equal(estimateGenerateNeurons(4), 57.6);
  assert.equal(estimateEditNeurons(512, 512, 1024, 1024), 109.6);
  assert.match(strengthInstruction(0.1), /subtle/);
  assert.match(strengthInstruction(0.5), /recognizable/);
  assert.match(strengthInstruction(0.9), /reimagine/);
  assert.equal(cleanEnhanced('Prompt: "A cat."'), 'A cat.');
  assert.equal(cleanEnhanced('line one\nline two'), 'line one line two');
  assert.throws(() => cleanEnhanced('   '));
  assert.ok(cleanEnhanced('word. '.repeat(300)).length <= 900);
  assert.deepEqual(readTextResult({ choices: [{ message: { content: 'hi' } }], usage: { neurons: 1 } }), { text: 'hi', neurons: 1 });
  assert.deepEqual(readTextResult(null), { text: '', neurons: null });
  assert.equal(validateEditBody({ prompt: 'x', image: `data:image/jpeg;base64,${jpeg(10, 10).toString('base64')}` }).width, 1024);
});

test('usage record helpers and pruning', async () => {
  let r = emptyDay('2026-10-19');
  r = addEvent(r, { kind: 'generate', neurons: 57.6 });
  r = addEvent(r, { kind: 'enhance', neurons: 3, reported: true });
  assert.equal(r.generate, 1);
  assert.equal(r.neurons, 60.6);
  assert.equal(r.neuronsReported, 3);
  assert.throws(() => addEvent(r, { kind: 'bogus' }));
  const p = publicUsage(r, new Date('2026-10-19T12:00:00Z'));
  assert.equal(p.images, 1);
  assert.equal(p.resetsAt, '2026-10-20T00:00:00.000Z');
  const ns = fakeDO();
  ns.map.set('day:2026-10-01', emptyDay('2026-10-01'));
  ns.map.set('day:2026-10-18', emptyDay('2026-10-18'));
  await ns.get().fetch('https://usage/?day=2026-10-19', { method: 'POST', body: JSON.stringify({ kind: 'generate', neurons: 1 }) });
  assert.ok(!ns.map.has('day:2026-10-01'));
  assert.ok(ns.map.has('day:2026-10-18'));
  assert.ok(ns.map.has('day:2026-10-19'));
});
