import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/build_config.dart';
import '../core/gen_types.dart';
import '../providers/paid_clients.dart';
import '../services/app_state.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatelessWidget {
  final AppState state;
  const SettingsScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final cf = state.cloudflareStatus;
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              const _Header('Image provider'),
              RadioGroup<ProviderMode>(
                groupValue: state.mode,
                onChanged: (m) {
                  if (m != null) state.mode = m;
                },
                child: Column(
                  children: [
                    for (final m in ProviderMode.values)
                      RadioListTile<ProviderMode>(
                        value: m,
                        title: Text(m.label),
                        subtitle: Text(_modeSubtitle(m)),
                      ),
                  ],
                ),
              ),
              const _Header('Cloudflare (free, main)'),
              ListTile(
                leading: Icon(
                  Icons.cloud,
                  color: cf == CloudflareStatus.ready
                      ? const Color(0xFFF6821F)
                      : cs.outline,
                ),
                title: Text(switch (cf) {
                  CloudflareStatus.notConfigured => 'Not set up yet',
                  CloudflareStatus.ready => 'Ready',
                  CloudflareStatus.quotaHit => 'Daily free limit reached',
                }),
                subtitle: Text(switch (cf) {
                  CloudflareStatus.notConfigured =>
                    'Auto mode uses Pollinations until a Worker URL is added.',
                  CloudflareStatus.ready =>
                    state.workerUrlFromBuild
                        ? 'Using the Worker built into this version.'
                        : state.workerUrl,
                  CloudflareStatus.quotaHit =>
                    'Resets at ${resetTimeLabel(state.cfQuotaUntil!)}. Pollinations covers until then.',
                }),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _editWorker(context),
              ),
              if (cf != CloudflareStatus.notConfigured)
                ListTile(
                  leading: const Icon(Icons.data_usage),
                  title: Text(usageHeadline(state.usage)),
                  subtitle: Text(usageDetail(state.usage)),
                  trailing: IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh),
                    onPressed: state.refreshUsage,
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.speed),
                title: Text('FLUX steps: ${state.settings.steps}'),
                subtitle: Slider(
                  value: state.settings.steps.toDouble(),
                  min: 1,
                  max: 8,
                  divisions: 7,
                  label: '${state.settings.steps}',
                  onChanged: (v) {
                    state.settings.steps = v.round();
                    state.touch();
                  },
                ),
              ),
              const _Header('Backup & restore History'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(
                  'Saves every History image with its prompt, favorites and edits into one .zip. '
                  'Do this before uninstalling (needed once to switch between the debug and release app).',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.save_alt),
                title: const Text('Back up to a file'),
                subtitle: Text(
                  '${state.history.items.length} images · choose Downloads or any folder',
                ),
                onTap: state.history.items.isEmpty
                    ? null
                    : () => _backup(context, share: false),
              ),
              ListTile(
                leading: const Icon(Icons.ios_share),
                title: const Text('Back up and share'),
                subtitle: const Text(
                  'Send the .zip to Drive, email, another phone…',
                ),
                onTap: state.history.items.isEmpty
                    ? null
                    : () => _backup(context, share: true),
              ),
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('Restore from a backup'),
                subtitle: const Text(
                  'Adds images from an Imagine Pad .zip (skips ones you already have)',
                ),
                onTap: () => _restore(context),
              ),
              const _Header('Your own keys (paid)'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Optional. Each image is billed to your account with that company. '
                  'Keys are stored encrypted on this phone (Android Keystore) and sent only to that provider.',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
              for (final p in const [
                ProviderId.xai,
                ProviderId.openai,
                ProviderId.stability,
              ])
                ListTile(
                  leading: Icon(
                    Icons.key,
                    color: state.hasKey(p) ? Colors.greenAccent : cs.outline,
                  ),
                  title: Text('${p.label} · paid'),
                  subtitle: Text(state.hasKey(p) ? 'Key saved' : 'No key'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _editKey(context, p),
                ),
              const _Header('About'),
              ListTile(
                leading: const Icon(Icons.local_florist),
                title: const Text('Pollinations (free backup)'),
                subtitle: const Text(
                  'No account. One image every 45 seconds per network, max 768×768 area, small logo in the corner.',
                ),
                onTap: () => showStatusSheet(context, state),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Imagine Pad'),
                subtitle: Text(
                  'Version ${BuildConfig.appVersion} · images are stored only on this phone',
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _modeSubtitle(ProviderMode m) => switch (m) {
    ProviderMode.auto =>
      'Free. Falls back to Pollinations if Cloudflare is off, busy or out of free images.',
    ProviderMode.cloudflareOnly =>
      'Free daily allowance (FLUX.1 schnell, square).',
    ProviderMode.pollinationsOnly =>
      'Free, no account, slower, one image per 45 s.',
    ProviderMode.xai =>
      state.hasKey(ProviderId.xai) ? 'Key saved' : 'Needs your xAI key',
    ProviderMode.openai =>
      state.hasKey(ProviderId.openai) ? 'Key saved' : 'Needs your OpenAI key',
    ProviderMode.stability =>
      state.hasKey(ProviderId.stability)
          ? 'Key saved'
          : 'Needs your Stability key',
  };

  Future<void> _backup(BuildContext context, {required bool share}) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Creating backup…'),
        duration: Duration(seconds: 2),
      ),
    );
    try {
      final b = await state.createBackupFile();
      if (share) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(b.path, mimeType: 'application/zip')],
            text: 'Imagine Pad backup',
          ),
        );
        return;
      }
      final saved = await FilePicker.saveFile(
        dialogTitle: 'Save Imagine Pad backup',
        fileName: b.path.split('/').last,
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        bytes: await File(b.path).readAsBytes(),
      );
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            saved == null
                ? 'Backup cancelled'
                : 'Saved ${b.count} images to a backup file',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    }
  }

  Future<void> _restore(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await FilePicker.pickFiles(type: FileType.any, withData: false);
      final path = r?.files.single.path;
      if (path == null) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Restoring…'),
          duration: Duration(seconds: 3),
        ),
      );
      final res = await state.restoreBackup(path);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            res.found == 0
                ? 'No images found in that file'
                : 'Restored ${res.added} new images (${res.found - res.added} already here)',
          ),
        ),
      );
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    }
  }

  Future<void> _editWorker(BuildContext context) async {
    final url = TextEditingController(text: state.settings.workerUrlOverride);
    final secret = TextEditingController();
    String? testResult;
    bool testing = false;
    await showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: const Text('Cloudflare Worker'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: url,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'Worker URL',
                    hintText: BuildConfig.workerUrl.isNotEmpty
                        ? BuildConfig.workerUrl
                        : 'https://imagine-pad.<name>.workers.dev',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: secret,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'Shared secret',
                    hintText: state.hasSecretOverride
                        ? '•••• saved (leave blank to keep)'
                        : 'APP_SHARED_SECRET',
                  ),
                ),
                const SizedBox(height: 10),
                if (testResult != null) Text(testResult!),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: testing
                  ? null
                  : () async {
                      setD(() => testing = true);
                      await state.setWorkerConfig(
                        url: url.text,
                        secret: secret.text.isEmpty ? null : secret.text,
                      );
                      final err = await state.cloudflareClient.checkHealth();
                      setD(() {
                        testing = false;
                        testResult = err == null
                            ? '✅ Worker reachable and secret accepted'
                            : '⚠️ $err';
                      });
                    },
              child: Text(testing ? 'Testing…' : 'Save & test'),
            ),
            TextButton(
              onPressed: () async {
                await state.setWorkerConfig(url: '', secret: '');
                if (c.mounted) Navigator.pop(c);
              },
              child: const Text('Clear'),
            ),
            FilledButton(
              onPressed: () async {
                await state.setWorkerConfig(
                  url: url.text,
                  secret: secret.text.isEmpty ? null : secret.text,
                );
                if (c.mounted) Navigator.pop(c);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editKey(BuildContext context, ProviderId p) async {
    final key = TextEditingController();
    final model = TextEditingController(
      text: switch (p) {
        ProviderId.xai => state.settings.xaiModel,
        ProviderId.openai => state.settings.openAiModel,
        _ => '',
      },
    );
    final defaultModel = switch (p) {
      ProviderId.xai => XaiClient.defaultModel,
      ProviderId.openai => OpenAiClient.defaultModel,
      _ => 'stable-image-core',
    };
    await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${p.label} key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Paid: each image is charged to your ${p.shortLabel} account.',
              style: Theme.of(c).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API key',
                hintText: state.hasKey(p)
                    ? '•••• saved (leave blank to keep)'
                    : 'Paste key',
              ),
            ),
            if (p != ProviderId.stability) ...[
              const SizedBox(height: 10),
              TextField(
                controller: model,
                decoration: InputDecoration(
                  labelText: 'Model',
                  hintText: defaultModel,
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (state.hasKey(p))
            TextButton(
              onPressed: () async {
                await state.setKey(p, '');
                if (c.mounted) Navigator.pop(c);
              },
              child: const Text('Remove key'),
            ),
          FilledButton(
            onPressed: () async {
              if (key.text.trim().isNotEmpty) await state.setKey(p, key.text);
              if (p == ProviderId.xai) state.settings.xaiModel = model.text;
              if (p == ProviderId.openai) {
                state.settings.openAiModel = model.text;
              }
              state.touch();
              if (c.mounted) Navigator.pop(c);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}
