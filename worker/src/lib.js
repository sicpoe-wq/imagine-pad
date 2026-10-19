// Pure helpers for the Imagine Pad Worker (unit-tested with `node --test`).

export const MODEL = '@cf/black-forest-labs/flux-1-schnell';
export const MAX_PROMPT = 2048; // model limit
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
