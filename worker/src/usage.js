// Daily usage counter for the free Workers AI allowance.
// One Durable Object instance ("global") keeps a small record per UTC day, so
// parallel batch requests are counted consistently (Workers KV allows only one
// write per second per key). Neurons for image models are ESTIMATES from the
// pricing page; text-model neurons are the values Workers AI reports.
import { FREE_NEURONS_PER_DAY, nextUtcMidnight, utcDay } from './lib.js';

export const KINDS = ['generate', 'edit', 'enhance'];
const KEEP_DAYS = 8;

export function emptyDay(day) {
  const r = { day, neurons: 0, neuronsReported: 0, neuronsEstimated: 0 };
  for (const k of KINDS) r[k] = 0;
  return r;
}

/** Pure: add one event to a day record. */
export function addEvent(rec, { kind, neurons = 0, reported = false }) {
  if (!KINDS.includes(kind)) throw new Error(`bad kind ${kind}`);
  const r = { ...rec };
  r[kind] = (r[kind] || 0) + 1;
  const n = Number.isFinite(neurons) && neurons > 0 ? neurons : 0;
  r.neurons = round2((r.neurons || 0) + n);
  if (reported) r.neuronsReported = round2((r.neuronsReported || 0) + n);
  else r.neuronsEstimated = round2((r.neuronsEstimated || 0) + n);
  return r;
}

/** Shape returned to the app. */
export function publicUsage(rec, now = new Date()) {
  const r = rec || emptyDay(utcDay(now));
  return {
    day: r.day,
    images: (r.generate || 0) + (r.edit || 0),
    generate: r.generate || 0,
    edit: r.edit || 0,
    enhance: r.enhance || 0,
    neurons: Math.round(r.neurons || 0),
    neuronsEstimated: (r.neuronsEstimated || 0) > 0,
    freeNeurons: FREE_NEURONS_PER_DAY,
    resetsAt: nextUtcMidnight(now).toISOString(),
    note: 'Counted by the Worker since 00:00 UTC. Image neurons are estimates from Cloudflare pricing; the dashboard is authoritative.',
  };
}

function round2(x) {
  return Math.round(x * 100) / 100;
}

export class UsageCounter {
  constructor(state) {
    this.storage = state.storage;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const day = url.searchParams.get('day') || utcDay();
    const key = `day:${day}`;
    if (request.method === 'POST') {
      const ev = await request.json();
      const cur = (await this.storage.get(key)) || emptyDay(day);
      const next = addEvent(cur, ev);
      await this.storage.put(key, next);
      await this.prune(day);
      return Response.json(next);
    }
    return Response.json((await this.storage.get(key)) || emptyDay(day));
  }

  async prune(today) {
    const all = await this.storage.list({ prefix: 'day:' });
    const cutoff = new Date(Date.parse(`${today}T00:00:00Z`) - KEEP_DAYS * 86400_000).toISOString().slice(0, 10);
    const old = [...all.keys()].filter((k) => k.slice(4) < cutoff);
    if (old.length) await this.storage.delete(old);
  }
}

/** Worker-side helpers. Never throw: usage is best-effort. */
function stub(env) {
  if (!env.USAGE) return null;
  return env.USAGE.get(env.USAGE.idFromName('global'));
}

export async function recordUsage(env, ev, now = new Date()) {
  const s = stub(env);
  if (!s) return null;
  try {
    const r = await s.fetch(`https://usage/?day=${utcDay(now)}`, {
      method: 'POST', body: JSON.stringify(ev), headers: { 'content-type': 'application/json' },
    });
    return publicUsage(await r.json(), now);
  } catch {
    return null;
  }
}

export async function readUsage(env, now = new Date()) {
  const s = stub(env);
  if (!s) return null;
  try {
    const r = await s.fetch(`https://usage/?day=${utcDay(now)}`);
    return publicUsage(await r.json(), now);
  } catch {
    return null;
  }
}
