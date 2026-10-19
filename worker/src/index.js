import {
  EDIT_MODEL, MODEL, TEXT_MODELS, HttpError, RateLimiter, checkSecret, cleanEnhanced, enhanceMessages,
  errorResponse, estimateEditNeurons, estimateGenerateNeurons, jsonResponse, mapAiError, readTextResult,
  strengthInstruction, validateBody, validateEditBody, validateEnhanceBody,
} from './lib.js';
import { readUsage, recordUsage } from './usage.js';

export { UsageCounter } from './usage.js';

let limiter;

const ROUTES = {
  '/health': 'GET',
  '/usage': 'GET',
  '/generate': 'POST',
  '/edit': 'POST',
  '/enhance': 'POST',
};

async function readJson(request) {
  try {
    return await request.json();
  } catch {
    throw new HttpError(400, 'bad_request', 'Body must be valid JSON.');
  }
}

async function handleGenerate(request, env) {
  const body = await readJson(request);
  const { prompt, steps, seed, ignored } = validateBody(body);
  let out;
  try {
    // Workers AI's flux-1-schnell schema rejects a 'seed' property, so it is not forwarded.
    out = await env.AI.run(MODEL, { prompt, steps });
  } catch (e) {
    throw mapAiError(e);
  }
  if (!out || typeof out.image !== 'string' || out.image.length === 0) {
    throw new HttpError(502, 'upstream', 'Workers AI returned no image.');
  }
  const usage = await recordUsage(env, { kind: 'generate', neurons: estimateGenerateNeurons(steps) });
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
    ...(usage ? { usage } : {}),
    ...(seed !== undefined ? { seedIgnored: true } : {}),
    ...(ignored.length ? { note: `${ignored.join(' and ')} ignored: FLUX.1 schnell outputs 1024x1024` } : {}),
  });
}

async function handleEdit(request, env) {
  const body = await readJson(request);
  const { prompt, bytes, info, strength, seed, width, height } = validateEditBody(body);
  const form = new FormData();
  form.append('prompt', `${strengthInstruction(strength)} Edit: ${prompt}`);
  form.append('input_image_0', new Blob([bytes], { type: info.mime }), `input.${info.mime.split('/')[1]}`);
  form.append('width', String(width));
  form.append('height', String(height));
  if (seed !== undefined) form.append('seed', String(seed));
  const serialized = new Response(form);
  let out;
  try {
    out = await env.AI.run(EDIT_MODEL, {
      multipart: { body: serialized.body, contentType: serialized.headers.get('content-type') },
    });
  } catch (e) {
    throw mapAiError(e);
  }
  if (!out || typeof out.image !== 'string' || out.image.length === 0) {
    throw new HttpError(502, 'upstream', 'Workers AI returned no edited image.');
  }
  const usage = await recordUsage(env, {
    kind: 'edit', neurons: estimateEditNeurons(info.width || 512, info.height || 512, width, height),
  });
  return jsonResponse({
    image: out.image,
    mime: 'image/jpeg',
    model: EDIT_MODEL,
    width,
    height,
    strength,
    seed: seed ?? null,
    ...(usage ? { usage } : {}),
  });
}

async function handleEnhance(request, env) {
  const body = await readJson(request);
  const { idea, style } = validateEnhanceBody(body);
  const messages = enhanceMessages(idea, style);
  let lastErr;
  for (const model of TEXT_MODELS) {
    let out;
    try {
      out = await env.AI.run(model, { messages, max_tokens: 180, temperature: 0.7 });
    } catch (e) {
      lastErr = mapAiError(e);
      if (lastErr.code === 'quota' || lastErr.code === 'content_filtered') throw lastErr;
      continue;
    }
    const { text, neurons } = readTextResult(out);
    const prompt = cleanEnhanced(text);
    const usage = await recordUsage(env, {
      kind: 'enhance', neurons: neurons ?? 3, reported: neurons != null,
    });
    return jsonResponse({ prompt, original: idea, model, ...(usage ? { usage } : {}) });
  }
  throw lastErr || new HttpError(502, 'upstream', 'Prompt enhancer unavailable.');
}

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      const path = url.pathname.replace(/\/+$/, '') || '/';
      const method = ROUTES[path];
      if (!method) throw new HttpError(404, 'not_found', `Unknown route. Use ${Object.keys(ROUTES).join(', ')}.`);
      if (request.method !== method) throw new HttpError(405, 'method_not_allowed', `Use ${method}.`);

      checkSecret(request, env);

      if (path === '/health') {
        return jsonResponse({ ok: true, model: MODEL, editModel: EDIT_MODEL, textModel: TEXT_MODELS[0], routes: Object.keys(ROUTES) });
      }
      if (path === '/usage') {
        const usage = await readUsage(env);
        if (!usage) return jsonResponse({ available: false });
        return jsonResponse({ available: true, ...usage });
      }

      const perMin = parseInt(env.RATE_LIMIT_PER_MINUTE || '20', 10);
      if (!limiter || limiter.limit !== perMin) limiter = new RateLimiter(perMin);
      limiter.check(request.headers.get('cf-connecting-ip') || 'unknown');

      if (path === '/generate') return await handleGenerate(request, env);
      if (path === '/edit') return await handleEdit(request, env);
      return await handleEnhance(request, env);
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
