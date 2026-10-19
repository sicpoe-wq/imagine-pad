import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/build_config.dart';
import '../core/gen_types.dart';
import '../providers/cloudflare_client.dart';
import '../providers/generation_service.dart';
import '../providers/paid_clients.dart';
import '../providers/pollinations_client.dart';
import 'history_store.dart';
import 'settings_store.dart';

enum CloudflareStatus { notConfigured, ready, quotaHit }

class AppState extends ChangeNotifier {
  final SettingsStore settings;
  final HistoryStore history;
  final http.Client httpClient;
  final _rng = Random.secure();

  String _workerSecretOverride = '';
  String xaiKey = '';
  String openAiKey = '';
  String stabilityKey = '';

  AppState(this.settings, this.history, this.httpClient);

  static Future<AppState> create() async {
    final prefs = await SharedPreferences.getInstance();
    const secure = FlutterSecureStorage();
    final docs = await getApplicationDocumentsDirectory();
    final s = AppState(SettingsStore(prefs, secure),
        HistoryStore(Directory('${docs.path}/history')), http.Client());
    await s._load();
    return s;
  }

  Future<void> _load() async {
    await history.load();
    _workerSecretOverride = await settings.readSecret(SettingsStore.sWorkerSecret);
    xaiKey = await settings.readSecret(SettingsStore.sXai);
    openAiKey = await settings.readSecret(SettingsStore.sOpenAi);
    stabilityKey = await settings.readSecret(SettingsStore.sStability);
  }

  // ---- Cloudflare config (Settings override wins over build-time value) ----
  String get workerUrl => settings.workerUrlOverride.isNotEmpty
      ? settings.workerUrlOverride
      : BuildConfig.workerUrl;
  bool get workerUrlFromBuild =>
      settings.workerUrlOverride.isEmpty && BuildConfig.workerUrl.isNotEmpty;
  String get workerSecret =>
      _workerSecretOverride.isNotEmpty ? _workerSecretOverride : BuildConfig.appSharedSecret;
  bool get hasSecretOverride => _workerSecretOverride.isNotEmpty;

  Future<void> setWorkerConfig({required String url, String? secret}) async {
    settings.workerUrlOverride = url;
    if (secret != null) {
      await settings.writeSecret(SettingsStore.sWorkerSecret, secret);
      _workerSecretOverride = secret.trim();
    }
    settings.cfQuotaUntil = null;
    notifyListeners();
  }

  Future<void> setKey(ProviderId p, String value) async {
    final v = value.trim();
    switch (p) {
      case ProviderId.xai:
        await settings.writeSecret(SettingsStore.sXai, v);
        xaiKey = v;
      case ProviderId.openai:
        await settings.writeSecret(SettingsStore.sOpenAi, v);
        openAiKey = v;
      case ProviderId.stability:
        await settings.writeSecret(SettingsStore.sStability, v);
        stabilityKey = v;
      default:
        break;
    }
    notifyListeners();
  }

  bool hasKey(ProviderId p) => switch (p) {
        ProviderId.xai => xaiKey.isNotEmpty,
        ProviderId.openai => openAiKey.isNotEmpty,
        ProviderId.stability => stabilityKey.isNotEmpty,
        _ => true,
      };

  ProviderMode get mode => settings.mode;
  set mode(ProviderMode m) {
    settings.mode = m;
    notifyListeners();
  }

  void touch() => notifyListeners();

  CloudflareClient get cloudflareClient => CloudflareClient(httpClient,
      workerUrl: workerUrl, sharedSecret: workerSecret);

  PollinationsClient get pollinationsClient => PollinationsClient(httpClient);

  DateTime? get cfQuotaUntil {
    final d = settings.cfQuotaUntil;
    if (d != null && DateTime.now().isAfter(d)) {
      settings.cfQuotaUntil = null;
      return null;
    }
    return d;
  }

  CloudflareStatus get cloudflareStatus {
    if (!cloudflareClient.isConfigured) return CloudflareStatus.notConfigured;
    if (cfQuotaUntil != null) return CloudflareStatus.quotaHit;
    return CloudflareStatus.ready;
  }

  ImageGenerator? _paidFor(ProviderMode m) => switch (m) {
        ProviderMode.xai => XaiClient(httpClient, xaiKey, model: settings.xaiModel),
        ProviderMode.openai => OpenAiClient(httpClient, openAiKey, model: settings.openAiModel),
        ProviderMode.stability => StabilityClient(httpClient, stabilityKey),
        _ => null,
      };

  GenerationService buildService() => GenerationService(
        mode: mode,
        cloudflare: cloudflareClient,
        pollinations: pollinationsClient,
        paid: _paidFor(mode),
        cloudflareQuotaUntil: cfQuotaUntil,
        onCloudflareQuota: (d) {
          settings.cfQuotaUntil = d;
          notifyListeners();
        },
      );

  int randomSeed() => _rng.nextInt(1 << 31);

  /// Set by History "Use prompt"; consumed by the Create screen.
  final reuse = ValueNotifier<HistoryItem?>(null);
  final tab = ValueNotifier<int>(0);

  void reusePrompt(HistoryItem item) {
    reuse.value = item;
    tab.value = 0;
  }

  Future<void> deleteHistory(HistoryItem item) async {
    await history.delete(item);
    notifyListeners();
  }

  Future<void> clearHistory() async {
    await history.clear();
    notifyListeners();
  }
}
