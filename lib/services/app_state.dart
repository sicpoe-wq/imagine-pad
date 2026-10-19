import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/build_config.dart';
import '../core/gen_types.dart';
import '../core/usage.dart';
import '../providers/cloudflare_client.dart';
import '../providers/generation_service.dart';
import '../providers/paid_clients.dart';
import '../providers/pollinations_client.dart';
import 'backup.dart';
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
    final s = AppState(
      SettingsStore(prefs, secure),
      HistoryStore(Directory('${docs.path}/history')),
      http.Client(),
    );
    await s._load();
    return s;
  }

  Future<void> _load() async {
    await history.load();
    _workerSecretOverride = await settings.readSecret(
      SettingsStore.sWorkerSecret,
    );
    xaiKey = await settings.readSecret(SettingsStore.sXai);
    openAiKey = await settings.readSecret(SettingsStore.sOpenAi);
    stabilityKey = await settings.readSecret(SettingsStore.sStability);
    _loadUsageCache();
  }

  // ---- Cloudflare config (Settings override wins over build-time value) ----
  String get workerUrl => settings.workerUrlOverride.isNotEmpty
      ? settings.workerUrlOverride
      : BuildConfig.workerUrl;
  bool get workerUrlFromBuild =>
      settings.workerUrlOverride.isEmpty && BuildConfig.workerUrl.isNotEmpty;
  String get workerSecret => _workerSecretOverride.isNotEmpty
      ? _workerSecretOverride
      : BuildConfig.appSharedSecret;
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

  CloudflareClient get cloudflareClient => CloudflareClient(
    httpClient,
    workerUrl: workerUrl,
    sharedSecret: workerSecret,
    onUsage: _setUsage,
  );

  // ---- Daily Cloudflare usage counter ----
  UsageInfo? _usage;

  /// Today's usage: the Worker's shared count when known, else this phone's count.
  UsageInfo get usage {
    final now = DateTime.now();
    final w = _usage?.current(now);
    if (w != null && w.fromWorker) return w;
    return UsageInfo.local(settings.localCfCount(UsageInfo.utcDay(now)), now);
  }

  void _setUsage(UsageInfo u) {
    _usage = u;
    settings.usageCacheJson = jsonEncode({
      'day': u.day,
      'images': u.images,
      'generate': u.generate,
      'edit': u.edit,
      'enhance': u.enhance,
      'neurons': u.neurons,
      'neuronsEstimated': u.neuronsEstimated,
      'resetsAt': u.resetsAt.toIso8601String(),
    });
    notifyListeners();
  }

  /// Called after each Cloudflare image so the fallback counter stays right.
  void countCloudflareImage([int n = 1]) {
    settings.bumpLocalCf(UsageInfo.utcDay(DateTime.now()), n);
    notifyListeners();
  }

  bool _usageLoading = false;
  Future<void> refreshUsage() async {
    if (_usageLoading) return;
    _usageLoading = true;
    try {
      await cloudflareClient.fetchUsage();
    } finally {
      _usageLoading = false;
    }
  }

  void _loadUsageCache() {
    final raw = settings.usageCacheJson;
    if (raw == null) return;
    try {
      _usage = UsageInfo.fromWorkerJson(jsonDecode(raw));
    } catch (_) {}
  }

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
    ProviderMode.openai => OpenAiClient(
      httpClient,
      openAiKey,
      model: settings.openAiModel,
    ),
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
    tab.value = tabCreate;
  }

  /// Tabs: 0 Create, 1 Edit, 2 History, 3 Settings.
  static const tabCreate = 0, tabEdit = 1, tabHistory = 2, tabSettings = 3;

  /// Set by Create / History "Edit"; consumed by the Edit screen.
  final editSource = ValueNotifier<HistoryItem?>(null);

  void openEditor(HistoryItem item) {
    editSource.value = item;
    tab.value = tabEdit;
  }

  Future<HistoryItem> toggleFavorite(HistoryItem item) async {
    final u = await history.setFavorite(item, !item.favorite);
    notifyListeners();
    return u;
  }

  Future<void> deleteHistory(HistoryItem item) async {
    await history.delete(item);
    notifyListeners();
  }

  /// Writes a History backup zip into the app's cache and returns its path.
  Future<({String path, int count})> createBackupFile() async {
    final tmp = await getTemporaryDirectory();
    final path = '${tmp.path}/${HistoryBackup.suggestedName(DateTime.now())}';
    final f = File(path);
    if (await f.exists()) await f.delete();
    final n = await HistoryBackup.export(
      items: history.items,
      historyDir: history.dir,
      zipPath: path,
      appVersion: BuildConfig.appVersion,
    );
    return (path: path, count: n);
  }

  /// Restores a backup zip; returns (found in zip, newly added).
  Future<({int found, int added})> restoreBackup(String zipPath) async {
    final items = await HistoryBackup.readInto(
      zipPath: zipPath,
      historyDir: history.dir,
    );
    final added = await history.mergeRestored(items);
    notifyListeners();
    return (found: items.length, added: added);
  }

  Future<void> clearHistory() async {
    await history.clear();
    notifyListeners();
  }
}
