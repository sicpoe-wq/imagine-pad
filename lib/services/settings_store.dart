import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/gen_types.dart';

/// Non-secret settings in SharedPreferences; secrets in the Android Keystore
/// via flutter_secure_storage. Secrets are never logged.
class SettingsStore {
  final SharedPreferences prefs;
  final FlutterSecureStorage secure;
  SettingsStore(this.prefs, this.secure);

  static const _kMode = 'mode';
  static const _kWorkerUrl = 'worker_url_override';
  static const _kSteps = 'cf_steps';
  static const _kXaiModel = 'xai_model';
  static const _kOpenAiModel = 'openai_model';
  static const _kStyle = 'last_style';
  static const _kAspect = 'last_aspect';
  static const _kCfQuota = 'cf_quota_until';
  static const _kBatch = 'batch_count';
  static const _kLocalDay = 'local_cf_day';
  static const _kLocalCount = 'local_cf_count';
  static const _kUsageCache = 'usage_cache';

  static const sWorkerSecret = 'worker_secret_override';
  static const sXai = 'xai_key';
  static const sOpenAi = 'openai_key';
  static const sStability = 'stability_key';

  ProviderMode get mode => ProviderModeInfo.parse(prefs.getString(_kMode));
  set mode(ProviderMode m) => prefs.setString(_kMode, m.name);

  String get workerUrlOverride => prefs.getString(_kWorkerUrl) ?? '';
  set workerUrlOverride(String v) => prefs.setString(_kWorkerUrl, v.trim());

  int get steps => (prefs.getInt(_kSteps) ?? 4).clamp(1, 8);
  set steps(int v) => prefs.setInt(_kSteps, v.clamp(1, 8));

  String get xaiModel => prefs.getString(_kXaiModel) ?? '';
  set xaiModel(String v) => prefs.setString(_kXaiModel, v.trim());

  String get openAiModel => prefs.getString(_kOpenAiModel) ?? '';
  set openAiModel(String v) => prefs.setString(_kOpenAiModel, v.trim());

  String get lastStyle => prefs.getString(_kStyle) ?? 'none';
  set lastStyle(String v) => prefs.setString(_kStyle, v);

  ImageAspect get lastAspect => AspectInfo.parse(prefs.getString(_kAspect));
  set lastAspect(ImageAspect a) => prefs.setString(_kAspect, a.name);

  DateTime? get cfQuotaUntil {
    final ms = prefs.getInt(_kCfQuota);
    return ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  set cfQuotaUntil(DateTime? d) => d == null
      ? prefs.remove(_kCfQuota)
      : prefs.setInt(_kCfQuota, d.millisecondsSinceEpoch);

  int get batchCount => (prefs.getInt(_kBatch) ?? 1).clamp(1, 4);
  set batchCount(int v) => prefs.setInt(_kBatch, v.clamp(1, 4));

  /// App-side count of Cloudflare images per UTC day (fallback when the
  /// Worker can't report usage).
  int localCfCount(String utcDay) => prefs.getString(_kLocalDay) == utcDay
      ? (prefs.getInt(_kLocalCount) ?? 0)
      : 0;
  void bumpLocalCf(String utcDay, [int by = 1]) {
    final n = localCfCount(utcDay) + by;
    prefs.setString(_kLocalDay, utcDay);
    prefs.setInt(_kLocalCount, n);
  }

  String? get usageCacheJson => prefs.getString(_kUsageCache);
  set usageCacheJson(String? v) =>
      v == null ? prefs.remove(_kUsageCache) : prefs.setString(_kUsageCache, v);

  Future<String> readSecret(String k) async {
    try {
      return await secure.read(key: k) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> writeSecret(String k, String v) async {
    final t = v.trim();
    if (t.isEmpty) {
      await secure.delete(key: k);
    } else {
      await secure.write(key: k, value: t);
    }
  }
}
