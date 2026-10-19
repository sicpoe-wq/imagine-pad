import {
  MODEL, HttpError, RateLimiter, checkSecret, errorResponse, jsonResponse, mapAiError, validateBody,
} from './lib.js';

let limiter;

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      const path = url.pathname.replace(/\/+$/, '') || '/';

      if (path === '/health') {
        if (request.method !== 'GET') throw new HttpError(405, 'method_not_allowed', 'Use GET.');
        checkSecret(request, env);
        return jsonResponse({ ok: true, model: MODEL });
      }
      if (path !== '/generate') throw new HttpError(404, 'not_found', 'Use POST /generate.');
      if (request.method !== 'POST') throw new HttpError(405, 'method_not_allowed', 'Use POST.');

      checkSecret(request, env);

      const perMin = parseInt(env.RATE_LIMIT_PER_MINUTE || '6', 10);
      if (!limiter || limiter.limit !== perMin) limiter = new RateLimiter(perMin);
      limiter.check(request.headers.get('cf-connecting-ip') || 'unknown');

      let body;
      try {
        body = await request.json();
      } catch {
        throw new HttpError(400, 'bad_request', 'Body must be valid JSON.');
      }
      const { prompt, steps, seed, ignored } = validateBody(body);

      let out;
      try {
        // Workers AI's flux-1-schnell schema rejects a 'seed' property, so it is not forwarded.
        const input = { prompt, steps };
        out = await env.AI.run(MODEL, input);
      } catch (e) {
        throw mapAiError(e);
      }
      if (!out || typeof out.image !== 'string' || out.image.length === 0) {
        throw new HttpError(502, 'upstream', 'Workers AI returned no image.');
      }
      const wantsJpeg = (request.headers.get('accept') || '').includes('image/jpeg');
      if (wantsJpeg) {
        const bin = Uint8Array.from(atob(out.image), (c) => c.charCodeAt(0));
        return new Response(bin, { headers: { 'content-type': 'image/jpeg', 'cache-control': 'no-store' } });
      }
      return jsonResponse({
        image: out.image,
        mime: 'image/jpeg',
        model: MODEL,
        steps,
        seed: null,
        width: 1024,
        height: 1024,
        ...(seed !== undefined ? { seedIgnored: true } : {}),
        ...(ignored.length ? { note: `${ignored.join(' and ')} ignored: FLUX.1 schnell outputs 1024x1024` } : {}),
      });
    } catch (e) {
      if (e instanceof HttpError) return errorResponse(e);
      return errorResponse(new HttpError(500, 'internal', 'Unexpected Worker error.'));
    }
  },
};

// Exposed for tests only.
export function _resetLimiter() {
  limiter = undefined;
}
