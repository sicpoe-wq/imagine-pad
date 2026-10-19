# Imagine Pad

Free AI image generator for Android (Flutter). Type a prompt, pick a style and shape, tap **Generate**.

**Download the latest APK:** https://github.com/sicpoe-wq/imagine-pad/releases/latest/download/ImaginePad-debug.apk
(sideload; allow installs from unknown sources). Package `com.tim.imagine_pad`.

## Status (v0.2.0)
**Cloudflare is live.** Release builds talk to the Worker at `https://imagine-pad.sicpoe.workers.dev` (URL and shared secret are injected at build time with `--dart-define`; the secret is not in this repo). Auto mode uses Cloudflare FLUX first and falls back to Pollinations. Note: Workers AI's FLUX schnell does not accept a seed, so on Cloudflare "same seed" / fixed seed does not reproduce an image (the Worker drops the seed); Pollinations still honors seeds.

## Providers
| Provider | Cost | Notes |
|---|---|---|
| **Cloudflare Workers AI – FLUX.1 [schnell]** (main) | Free daily allowance (10,000 neurons/day on the Workers Free plan, resets 00:00 UTC = 8 PM EDT / 7 PM EST) | Called through our own Worker in [`worker/`](worker/), so no Cloudflare token is in the app. Output is 1024×1024 (the model has no width/height input). |
| **Pollinations Classic** (backup) | Free, no account | `https://image.pollinations.ai/prompt/{prompt}?width&height&seed`. One image at a time per IP, ≥45 s apart; 402/503 when at limit (app shows a countdown and retries). Max 768×768 area; small logo in the corner. |
| xAI Grok Imagine, OpenAI, Stability AI | **Paid**, your own key | Optional, in Settings. Keys are stored with `flutter_secure_storage` (Android Keystore) and sent only to that provider in the `Authorization` header. |

**Settings → Image provider:** Auto (Cloudflare, then Pollinations) · Cloudflare only · Pollinations only · xAI / OpenAI / Stability (paid).

Auto falls back to Pollinations when Cloudflare is not configured, out of free images (`quota`), rate limited, timing out, unreachable, returns a server error, or rejects the secret. It does **not** fall back on a safety-filter refusal or invalid prompt. After a `quota` error Cloudflare is skipped until the next 00:00 UTC. Each image shows which provider made it.

### Paid endpoints used
- xAI: `POST https://api.x.ai/v1/images/generations` `{model: grok-imagine-image-2.0, prompt, n:1, response_format: b64_json, aspect_ratio}` (model editable in Settings)
- OpenAI: `POST https://api.openai.com/v1/images/generations` `{model: gpt-image-2.5-flare, prompt, n:1, size: 1024x1024|1024x1536|1536x1024}` → `data[0].b64_json` (model editable)
- Stability: `POST https://api.stability.ai/v2beta/stable-image/generate/core` multipart `{prompt, aspect_ratio, seed, output_format: jpeg}`, `Accept: image/*`

## Features
Prompt box with example chips · 12 style presets (appended to the prompt) · Square / Portrait (2:3) / Landscape (3:2) · optional fixed seed · Generate with progress bar and elapsed timer · result with pinch zoom · save to gallery (`gal`, "Imagine Pad" album; no permission needed on Android 10+) · share · variation (new seed) · same seed · copy prompt · History grid (stored in app storage with prompt, style, seed, provider, model, date; delete / delete all / reuse prompt) · status chip showing provider and Cloudflare daily status.

## Turning Cloudflare on (no code change)
1. Deploy the Worker (below) and note its URL, e.g. `https://imagine-pad.<subdomain>.workers.dev`.
2. Either enter the URL and shared secret in **Settings → Cloudflare** ("Save & test" calls `/health`), or bake them into a build:
   `flutter build apk --dart-define=WORKER_URL=https://... --dart-define=APP_SHARED_SECRET=...`
   Settings values override build-time values.

## Worker (`worker/`)
- `POST /generate` JSON `{prompt (1–2048 chars), steps? (1–8, default 4), seed? (int)}` + header `X-App-Secret` → `{image: <base64 jpeg>, mime, model, steps, seed, width:1024, height:1024}`. Send `Accept: image/jpeg` to get raw bytes instead. `width`/`height` are accepted but ignored (noted in the response).
- `GET /health` (needs the secret) → `{ok:true}`.
- Errors: `{error:{code, message, ...}}` with codes `bad_request` 400, `unauthorized` 401, `not_found` 404, `method_not_allowed` 405, `rate_limited` 429 (+`Retry-After`), **`quota` 429** (Workers AI error 4006 "daily free allocation", + `resetsAt`), `content_filtered` 400, `upstream` 502/503, `upstream_timeout` 504, `not_configured`/`internal` 500.
- Per-IP limit: `RATE_LIMIT_PER_MINUTE` (default 6) in memory per isolate — best effort only.
- **The shared secret is a light deterrent.** It ships inside the APK and can be extracted; it only stops casual use of the URL. The real cost cap is Cloudflare's free daily allowance (on the Free plan, requests simply fail with `quota` after it is used — no charges).

### Deploy
Needs a Cloudflare account (free plan is fine) and an **account API token** with **Account → Workers Scripts: Edit** and **Account → Workers AI: Read** (Edit also fine), plus your **Account ID** (dashboard → Workers & Pages → right sidebar). A workers.dev subdomain must exist (created the first time you open Workers & Pages).
```bash
cd worker
export CLOUDFLARE_API_TOKEN=...  CLOUDFLARE_ACCOUNT_ID=...
export APP_SHARED_SECRET=$(openssl rand -hex 24)
./deploy.sh          # runs unit tests, wrangler deploy, sets the secret
```
Tests: `cd worker && node --test test/`.

## Development
```bash
flutter analyze && flutter test
flutter build apk --debug
dart run tool/live_pollinations.dart   # live Pollinations proof via the app's client
```
