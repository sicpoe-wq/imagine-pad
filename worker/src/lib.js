// Pure helpers for the Imagine Pad Worker (unit-tested with `node --test`).

export const MODEL = '@cf/black-forest-labs/flux-1-schnell';
// FLUX.2 [klein] 4B: unified generation + editing, multipart input, reference images < 512x512.
export const EDIT_MODEL = '@cf/black-forest-labs/flux-2-klein-4b';
// Prompt enhancer: small, cheap instruct models (~2-4 neurons per call). Second is a fallback.
export const TEXT_MODELS = ['@cf/meta/llama-3.1-8b-instruct-fp8', '@cf/meta/llama-3.2-3b-instruct'];
export const MAX_PROMPT = 2048; // model limit
export const MAX_IDEA = 600;
export const MAX_EDIT_IMAGE_BYTES = 1_500_000;
export const MAX_EDIT_INPUT_SIDE = 512; // docs: reference images must be under 512x512
export const FREE_NEURONS_PER_DAY = 10_000;
export const SECRET_HEADER = 'x-app-secret';

export class HttpError extends Error {
  constructor(status, code, message, extra = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

export function jsonResponse(obj, status = 200, headers = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers },
  });
}

export function errorResponse(err) {
  const headers = {};
  if (err.extra && err.extra.retryAfter != null) headers['retry-after'] = String(err.extra.retryAfter);
  return jsonResponse({ error: { code: err.code, message: err.message, ...err.extra } }, err.status, headers);
}

/** Constant-time string compare. */
export function safeEqual(a, b) {
  const enc = new TextEncoder();
  const x = enc.encode(String(a));
  const y = enc.encode(String(b));
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

/**
 * Shared-secret check. This is a light deterrent only: the secret ships inside
 * the APK and can be extracted. It stops casual drive-by use of the URL.
 */
export function checkSecret(request, env) {
  const expected = env.APP_SHARED_SECRET;
  if (!expected) {
    throw new HttpError(500, 'not_configured', 'APP_SHARED_SECRET is not set on the Worker.');
  }
  const got = request.headers.get(SECRET_HEADER) || '';
  if (!safeEqual(got, expected)) {
    throw new HttpError(401, 'unauthorized', 'Missing or wrong app secret.');
  }
}

/** Validate and normalise a POST /generate body. */
export function validateBody(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    throw new HttpError(400, 'bad_request', 'Body must be a JSON object.');
  }
  const prompt = typeof body.prompt === 'string' ? body.prompt.trim() : '';
  if (!prompt) throw new HttpError(400, 'bad_request', 'prompt is required.');
  if (prompt.length > MAX_PROMPT) {
    throw new HttpError(400, 'bad_request', `prompt must be at most ${MAX_PROMPT} characters.`);
  }
  let steps = 4;
  if (body.steps !== undefined && body.steps !== null) {
    if (!Number.isInteger(body.steps) || body.steps < 1 || body.steps > 8) {
      throw new HttpError(400, 'bad_request', 'steps must be an integer from 1 to 8.');
    }
    steps = body.steps;
  }
  let seed;
  if (body.seed !== undefined && body.seed !== null) {
    if (!Number.isInteger(body.seed) || body.seed < 0 || body.seed > 4294967295) {
      throw new HttpError(400, 'bad_request', 'seed must be a non-negative integer.');
    }
    seed = body.seed;
  }
  // FLUX.1 schnell on Workers AI takes only prompt/steps/seed: output is 1024x1024.
  const ignored = ['width', 'height'].filter((k) => body[k] !== undefined);
  return { prompt, steps, seed, ignored };
}

/** Map a Workers AI exception to an HttpError with an app-facing code. */
export function mapAiError(e) {
  const msg = String((e && (e.message || e)) || 'unknown error');
  const m = msg.toLowerCase();
  // Free plan: "4006: you have used up your daily free allocation of 10,000 neurons".
  if (m.includes('4006') || m.includes('daily free allocation') || m.includes('neurons')) {
    return new HttpError(429, 'quota', 'Cloudflare daily free allocation used up. Resets at 00:00 UTC.', {
      resetsAt: nextUtcMidnight().toISOString(),
    });
  }
  if (m.includes('3040') || m.includes('capacity') || m.includes('rate limit') || m.includes('too many')) {
    return new HttpError(503, 'upstream', 'Workers AI is at capacity. Try again shortly.', { retryAfter: 10 });
  }
  if (m.includes('timeout') || m.includes('timed out') || m.includes('3007')) {
    return new HttpError(504, 'upstream_timeout', 'Workers AI timed out.');
  }
  if (m.includes('nsfw') || m.includes('safety') || m.includes('flagged') || m.includes('moderation')) {
    return new HttpError(400, 'content_filtered', 'The prompt was refused by the safety filter.');
  }
  if (m.includes('input') && (m.includes('invalid') || m.includes('schema'))) {
    return new HttpError(400, 'bad_request', msg.slice(0, 300));
  }
  return new HttpError(502, 'upstream', `Workers AI error: ${msg.slice(0, 300)}`);
}

export function nextUtcMidnight(now = new Date()) {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1));
}

/**
 * Tiny in-memory fixed-window limiter. Best effort only: each Worker isolate
 * keeps its own counters, so it limits bursts, not a global quota.
 */
export class RateLimiter {
  constructor(limit, windowMs = 60_000, now = () => Date.now()) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.now = now;
    this.hits = new Map();
  }
  check(key) {
    const t = this.now();
    let e = this.hits.get(key);
    if (!e || t - e.start >= this.windowMs) {
      e = { start: t, count: 0 };
      this.hits.set(key, e);
    }
    e.count++;
    if (this.hits.size > 5000) {
      for (const [k, v] of this.hits) if (t - v.start >= this.windowMs) this.hits.delete(k);
    }
    if (e.count > this.limit) {
      const retryAfter = Math.max(1, Math.ceil((e.start + this.windowMs - t) / 1000));
      throw new HttpError(429, 'rate_limited', 'Too many requests. Slow down.', { retryAfter });
    }
  }
}

// ---------------------------------------------------------------- neurons

/**
 * Neuron ESTIMATES from the Workers AI pricing page (image models do not
 * report usage in their response). 512x512 tiles are rounded up.
 *   flux-1-schnell: 4.80 / output tile + 9.60 / step
 *   flux-2-klein-4b: 5.37 / input tile + 26.05 / output tile
 */
export function tiles(w, h) {
  return Math.ceil(w / 512) * Math.ceil(h / 512);
}
export function estimateGenerateNeurons(steps, w = 1024, h = 1024) {
  return round1(tiles(w, h) * 4.8 + steps * 9.6);
}
export function estimateEditNeurons(inW, inH, outW, outH) {
  return round1(tiles(inW, inH) * 5.37 + tiles(outW, outH) * 26.05);
}
function round1(x) {
  return Math.round(x * 10) / 10;
}

export function utcDay(now = new Date()) {
  return now.toISOString().slice(0, 10);
}

// ---------------------------------------------------------------- images

export function b64ToBytes(b64) {
  let s = String(b64 || '');
  const comma = s.indexOf(',');
  if (s.startsWith('data:') && comma > 0) s = s.slice(comma + 1);
  s = s.replace(/\s+/g, '');
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(s)) throw new HttpError(400, 'bad_request', 'image must be base64.');
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Read width/height from JPEG, PNG or WebP headers. Returns null if unknown. */
export function imageInfo(b) {
  if (b.length >= 24 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) {
    const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    return { mime: 'image/png', width: dv.getUint32(16), height: dv.getUint32(20) };
  }
  if (b.length >= 4 && b[0] === 0xff && b[1] === 0xd8) {
    let i = 2;
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) { i++; continue; }
      const marker = b[i + 1];
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { i += 2; continue; }
      const len = (b[i + 2] << 8) | b[i + 3];
      // SOF0..SOF15 except DHT(C4), JPG(C8), DAC(CC)
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        return { mime: 'image/jpeg', height: (b[i + 5] << 8) | b[i + 6], width: (b[i + 7] << 8) | b[i + 8] };
      }
      i += 2 + len;
    }
    return { mime: 'image/jpeg', width: null, height: null };
  }
  if (b.length >= 30 && b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
      b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) {
    const fourcc = String.fromCharCode(b[12], b[13], b[14], b[15]);
    if (fourcc === 'VP8X') {
      return { mime: 'image/webp', width: 1 + (b[24] | (b[25] << 8) | (b[26] << 16)), height: 1 + (b[27] | (b[28] << 8) | (b[29] << 16)) };
    }
    if (fourcc === 'VP8 ') {
      return { mime: 'image/webp', width: (b[26] | (b[27] << 8)) & 0x3fff, height: (b[28] | (b[29] << 8)) & 0x3fff };
    }
    if (fourcc === 'VP8L') {
      const v = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      return { mime: 'image/webp', width: (v & 0x3fff) + 1, height: ((v >> 14) & 0x3fff) + 1 };
    }
    return { mime: 'image/webp', width: null, height: null };
  }
  return null;
}

/** Output size for an edit: keep the input aspect, long side `longSide`, multiples of 16. */
export function editOutputSize(inW, inH, longSide = 1024) {
  if (!inW || !inH) return { width: longSide, height: longSide };
  const r = inW / inH;
  let w = r >= 1 ? longSide : longSide * r;
  let h = r >= 1 ? longSide / r : longSide;
  const snap = (x) => Math.min(1920, Math.max(256, Math.round(x / 16) * 16));
  return { width: snap(w), height: snap(h) };
}

/**
 * FLUX.2 klein has no img2img "strength" input, so the strength slider is
 * turned into an instruction. This is a hint to the model, not exact denoising.
 */
export function strengthInstruction(strength) {
  if (strength <= 0.35) {
    return 'Make only a subtle edit to image 0. Keep the same composition, subject, pose, framing and colors; change only what is asked.';
  }
  if (strength >= 0.75) {
    return 'Use image 0 as loose inspiration. Boldly reimagine it as asked; composition and details may change a lot.';
  }
  return 'Edit image 0 as asked while keeping its main subject and overall composition recognizable.';
}

export function validateEditBody(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    throw new HttpError(400, 'bad_request', 'Body must be a JSON object.');
  }
  const prompt = typeof body.prompt === 'string' ? body.prompt.trim() : '';
  if (!prompt) throw new HttpError(400, 'bad_request', 'prompt is required.');
  if (prompt.length > 1500) throw new HttpError(400, 'bad_request', 'prompt must be at most 1500 characters.');
  if (typeof body.image !== 'string' || !body.image) throw new HttpError(400, 'bad_request', 'image (base64) is required.');
  if (body.image.length > Math.ceil(MAX_EDIT_IMAGE_BYTES * 4 / 3) + 64) {
    throw new HttpError(413, 'image_too_large', 'Image is too large. Resize it to at most 512x512 first.');
  }
  const bytes = b64ToBytes(body.image);
  const info = imageInfo(bytes);
  if (!info) throw new HttpError(400, 'bad_request', 'image must be a JPEG, PNG or WebP.');
  if (info.width && info.height && (info.width > MAX_EDIT_INPUT_SIDE || info.height > MAX_EDIT_INPUT_SIDE)) {
    throw new HttpError(413, 'image_too_large',
      `Image is ${info.width}x${info.height}; it must be at most ${MAX_EDIT_INPUT_SIDE}x${MAX_EDIT_INPUT_SIDE}.`);
  }
  let strength = 0.5;
  if (body.strength !== undefined && body.strength !== null) {
    if (typeof body.strength !== 'number' || !(body.strength >= 0 && body.strength <= 1)) {
      throw new HttpError(400, 'bad_request', 'strength must be a number from 0 to 1.');
    }
    strength = body.strength;
  }
  let seed;
  if (body.seed !== undefined && body.seed !== null) {
    if (!Number.isInteger(body.seed) || body.seed < 0 || body.seed > 2147483647) {
      throw new HttpError(400, 'bad_request', 'seed must be a non-negative integer.');
    }
    seed = body.seed;
  }
  const out = editOutputSize(info.width, info.height, 1024);
  return { prompt, bytes, info, strength, seed, ...out };
}

// ---------------------------------------------------------------- enhance

export const ENHANCE_SYSTEM =
  'You rewrite a short image idea into ONE vivid, detailed prompt for an AI image generator. ' +
  "Keep the user's subject and intent exactly; do not add people, text or brands they did not ask for. " +
  'Add concrete details: subject appearance, setting, lighting, camera angle or composition, mood and art style. ' +
  'Keep it safe for work and family friendly. Write it as a single paragraph under 70 words. ' +
  'Output ONLY the prompt: no title, no quotes, no lists, no explanations.';

export function validateEnhanceBody(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    throw new HttpError(400, 'bad_request', 'Body must be a JSON object.');
  }
  const idea = typeof body.idea === 'string' ? body.idea.trim() : '';
  if (!idea) throw new HttpError(400, 'bad_request', 'idea is required.');
  if (idea.length > MAX_IDEA) throw new HttpError(400, 'bad_request', `idea must be at most ${MAX_IDEA} characters.`);
  const style = typeof body.style === 'string' ? body.style.trim().slice(0, 200) : '';
  return { idea, style };
}

export function enhanceMessages(idea, style) {
  const user = style ? `Idea: ${idea}\nPreferred style: ${style}` : `Idea: ${idea}`;
  return [
    { role: 'system', content: ENHANCE_SYSTEM },
    { role: 'user', content: user },
  ];
}

const REFUSAL = /^(i can(no|')t|i'm sorry|i am sorry|sorry,|i won't|i will not|as an ai)/i;

/** Clean the model's reply into a single prompt line. Throws on refusal/empty. */
export function cleanEnhanced(text) {
  let s = String(text || '').trim();
  s = s.replace(/^```[a-z]*\s*|```$/gi, '').trim();
  s = s.replace(/^(here(?:'s| is) (?:an? )?(?:enhanced |detailed |improved )?prompt[^:]*:\s*)/i, '');
  s = s.replace(/^(enhanced |improved |detailed )?prompt\s*:\s*/i, '');
  s = s.replace(/\s*\n+\s*/g, ' ').trim();
  s = s.replace(/^["'“”‘’]+|["'“”‘’]+$/g, '').trim();
  if (!s) throw new HttpError(502, 'upstream', 'The text model returned nothing.');
  if (REFUSAL.test(s)) throw new HttpError(400, 'content_filtered', 'The enhancer refused this idea.');
  if (s.length > 900) {
    const cut = s.slice(0, 900);
    const dot = cut.lastIndexOf('.');
    s = dot > 400 ? cut.slice(0, dot + 1) : cut.trim();
  }
  return s;
}

/** Workers AI text responses come in two shapes; pull out text + reported neurons. */
export function readTextResult(out) {
  if (!out || typeof out !== 'object') return { text: '', neurons: null };
  const text = typeof out.response === 'string' ? out.response
    : out.choices?.[0]?.message?.content ?? '';
  const n = out.usage?.neurons;
  return { text, neurons: typeof n === 'number' ? n : null };
}
