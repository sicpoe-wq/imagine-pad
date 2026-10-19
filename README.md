# Imagine Pad

Free AI image generator for Android (Flutter). Type a prompt, pick a style and shape, tap **Generate**.

## Download (v0.3.0)
Two APKs are attached to every release. Same app, same features; they differ only in how they are built and signed. Package `com.tim.imagine_pad` (sideload; allow installs from unknown sources).

| File | Size | Installs over your current app? | Notes |
|---|---|---|---|
| [**ImaginePad-debug.apk**](https://github.com/sicpoe-wq/imagine-pad/releases/latest/download/ImaginePad-debug.apk) | ~150 MB | **Yes** (same debug key as v0.1/v0.2) | Unoptimized debug build. |
| [**ImaginePad.apk**](https://github.com/sicpoe-wq/imagine-pad/releases/latest/download/ImaginePad.apk) | ~35 MB | **No, one-time uninstall needed** | Optimized release build (R8 shrinking, AOT-compiled Dart): smaller, starts and scrolls faster. Signed with Imagine Pad's own release key; future release builds install over it. ARM phones (32 and 64-bit). |

Android refuses to install an app over one signed with a different key, so moving from the debug app to the release app needs one uninstall, and uninstalling deletes History. **Back up first:**

1. In the current app, update to **ImaginePad-debug.apk** (v0.3.0 or later; installs over v0.2).
2. **Settings → Backup & restore History → Back up to a file** (pick Downloads) or **Back up and share** (Drive, email…). You get `ImaginePad-backup-YYYYMMDD-HHMM.zip` with every image, prompt, favorite and edit.
3. Uninstall Imagine Pad.
4. Install **ImaginePad.apk**.
5. **Settings → Restore from a backup** and pick the zip. Restoring twice is safe; images you already have are skipped.

Paid keys (xAI/OpenAI/Stability) are stored in the Android Keystore and are not in the backup; paste them again after switching.

## What's new in 0.3.0
- **Edit tab (image-to-image):** pick a photo from the gallery, camera, or History, describe the change ("make it night", "turn this into anime"), set **How much to change** (subtle / balanced / bold) and tap **Apply edit**. Uses Cloudflare **FLUX.2 [klein] 4B** (`@cf/black-forest-labs/flux-2-klein-4b`). The photo is shrunk to ≤512 px first (the model's limit for reference images); the result is up to 1024 px and keeps the photo's shape. Before/After toggle; "Edit this result" chains edits. FLUX.2 klein has no exact denoising-strength input, so the slider is turned into an instruction for the model (a guide, not a precise dial). Editing needs Cloudflare; Pollinations can't edit, and the app says so when Cloudflare is off or out of free images. No inpainting/masking.
- **Enhance:** turns a short idea into a detailed prompt with `@cf/meta/llama-3.1-8b-instruct-fp8` (falls back to `@cf/meta/llama-3.2-3b-instruct`). Shows the original, with **Undo** and **Keep**. About 3–4 neurons each.
- **Batch:** make 1–4 images per tap. Cloudflare runs them all at once (~3–4 s for 4); Pollinations goes one at a time with its 45 s gap. Results show in a grid: star favorites, tap to zoom, **Save all** / **Save favorites**.
- **Daily free counter:** "X Cloudflare images used today · resets 8:00 PM" with a neuron bar on Create, Edit, Settings and the status sheet. The Worker counts every generate/edit/enhance per UTC day in a Durable Object (shared by all phones using it). Image neurons are **estimates** from Cloudflare's price list (FLUX.1 schnell 1024² @4 steps ≈ 57.6; FLUX.2 klein edit ≈ 110); text-model neurons are the values Workers AI reports. Cloudflare's dashboard is the exact source. If the Worker can't report, the app falls back to counting its own Cloudflare images.
- **History:** star favorites (grid, detail, results), Favorites filter, search by prompt words, newest/oldest sort; edits remember their original for before/after.
- **Upscale 2× (basic):** on-device bicubic 2× resize plus an unsharp mask (1024 → 2048 px), saved as a new History item. **This is not AI super-resolution.** Workers AI has no upscaler model, and an on-device ESRGAN would add ~tens of MB and native code for modest gains.
- **Backup / restore** History as a .zip (see above).
- **Release build** (see Download).

## Status
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
- `POST /edit` JSON `{prompt (≤1500), image: <base64 JPEG/PNG/WebP, ≤512×512, ≤1.5 MB>, strength? 0–1 (default 0.5), seed?}` → `{image, mime, model, width, height, strength, seed, usage}`. Runs `@cf/black-forest-labs/flux-2-klein-4b` with multipart `prompt`, `input_image_0`, `width`, `height` (`seed`). Output keeps the input aspect, long side 1024. Oversize input → `413 image_too_large`.
- `POST /enhance` JSON `{idea (≤600), style?}` → `{prompt, original, model, usage}`. Refusals → `content_filtered`.
- `GET /usage` → `{available, day, images, generate, edit, enhance, neurons, neuronsEstimated, freeNeurons:10000, resetsAt}` for the current UTC day. Every image/enhance response also carries `usage`. Counter: Durable Object `UsageCounter` (SQLite-backed, free plan), keeps 8 days.
- `POST /generate` JSON `{prompt (1–2048 chars), steps? (1–8, default 4), seed? (int)}` + header `X-App-Secret` → `{image: <base64 jpeg>, mime, model, steps, seed, width:1024, height:1024}`. Send `Accept: image/jpeg` to get raw bytes instead. `width`/`height` are accepted but ignored (noted in the response).
- `GET /health` (needs the secret) → `{ok:true}`.
- Errors: `{error:{code, message, ...}}` with codes `bad_request` 400, `unauthorized` 401, `not_found` 404, `method_not_allowed` 405, `rate_limited` 429 (+`Retry-After`), **`quota` 429** (Workers AI error 4006 "daily free allocation", + `resetsAt`), `content_filtered` 400, `upstream` 502/503, `upstream_timeout` 504, `not_configured`/`internal` 500.
- Per-IP limit: `RATE_LIMIT_PER_MINUTE` (20, room for a 4-image batch plus edits) across generate/edit/enhance, in memory per isolate — best effort only.
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
D="--dart-define=WORKER_URL=https://imagine-pad.sicpoe.workers.dev --dart-define=APP_SHARED_SECRET=... --dart-define=APP_VERSION=0.3.0"
flutter build apk --debug $D                                                   # ImaginePad-debug.apk
flutter build apk --release --target-platform android-arm,android-arm64 $D     # ImaginePad.apk
dart run tool/live_pollinations.dart   # live Pollinations proof via the app's client
WORKER_URL=... APP_SHARED_SECRET=... dart run tool/live_features.dart   # enhance, batch, edit, upscale, usage
```

### Release signing
`android/app/build.gradle.kts` reads `android/key.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`). That file and all `*.jks` are gitignored; on the build box it is a symlink to a file kept outside the repo. Without it, release builds fall back to the debug key. R8 minify + resource shrinking are on for release (`android/app/proguard-rules.pro`). **Keep the keystore and its passwords safe: losing them means future release builds can't install over this one.**
