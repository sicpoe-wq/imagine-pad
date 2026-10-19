/// Build-time defaults. Pass with:
///   flutter build apk --dart-define=WORKER_URL=https://imagine-pad.YOU.workers.dev \
///                     --dart-define=APP_SHARED_SECRET=...
/// Settings can override both at runtime, so Cloudflare can be turned on later
/// without a new build.
class BuildConfig {
  static const workerUrl = String.fromEnvironment('WORKER_URL');
  static const appSharedSecret = String.fromEnvironment('APP_SHARED_SECRET');
  static const appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '0.3.0',
  );
}
