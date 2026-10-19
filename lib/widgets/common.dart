import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/gen_types.dart';
import '../core/usage.dart';
import '../providers/pollinations_client.dart';
import '../services/app_state.dart';

Color providerColor(ProviderId p, ColorScheme s) => switch (p) {
  ProviderId.cloudflare => const Color(0xFFF6821F),
  ProviderId.pollinations => const Color(0xFF34D399),
  ProviderId.xai => const Color(0xFFE5E7EB),
  ProviderId.openai => const Color(0xFF10A37F),
  ProviderId.stability => const Color(0xFFA78BFA),
};

class ProviderBadge extends StatelessWidget {
  final ProviderId provider;
  final bool dense;
  const ProviderBadge(this.provider, {super.key, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final c = providerColor(provider, Theme.of(context).colorScheme);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 10,
        vertical: dense ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: dense ? 11 : 14, color: c),
          const SizedBox(width: 4),
          Text(
            provider.isPaid
                ? '${provider.shortLabel} · paid'
                : provider.shortLabel,
            style: TextStyle(
              fontSize: dense ? 10 : 12,
              color: c,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

String resetTimeLabel(DateTime utc) {
  final local = utc.toLocal();
  return '${DateFormat.jm().format(local)} (00:00 UTC)';
}

/// "12 used today · resets 8:00 PM" plus the neuron estimate.
String usageHeadline(UsageInfo u) =>
    '${u.images} Cloudflare image${u.images == 1 ? '' : 's'} used today · resets ${DateFormat.jm().format(u.resetsAt.toLocal())}';

String usageDetail(UsageInfo u) {
  final n = u.neuronsOrEstimate.round();
  final fmt = NumberFormat.decimalPattern();
  final est = (u.neurons == null || u.neuronsEstimated)
      ? 'estimated'
      : 'reported';
  final who = u.fromWorker
      ? 'counted by your Worker'
      : 'counted on this phone only';
  final extra = [
    if (u.edit > 0) '${u.edit} edit${u.edit == 1 ? '' : 's'}',
    if (u.enhance > 0) '${u.enhance} enhance${u.enhance == 1 ? '' : 's'}',
  ];
  return '~${fmt.format(n)} of ${fmt.format(UsageInfo.freeNeurons)} free neurons ($est, $who)'
      '${extra.isEmpty ? '' : ' · ${extra.join(', ')}'} · about ${u.imagesLeftEstimate} images left';
}

/// Compact daily-usage card shown on Create and Edit.
class UsageBar extends StatelessWidget {
  final AppState state;
  const UsageBar({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        if (state.cloudflareStatus == CloudflareStatus.notConfigured) {
          return const SizedBox.shrink();
        }
        final u = state.usage;
        final t = Theme.of(context).textTheme;
        final cs = Theme.of(context).colorScheme;
        final frac = u.fractionUsed;
        final color = frac > 0.9
            ? Colors.redAccent
            : (frac > 0.7 ? Colors.amber : const Color(0xFFF6821F));
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => showStatusSheet(context, state),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.data_usage, size: 16, color: color),
                    const SizedBox(width: 6),
                    Expanded(child: Text(usageHeadline(u), style: t.bodySmall)),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: frac,
                    minHeight: 4,
                    color: color,
                    backgroundColor: cs.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  usageDetail(u),
                  style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// App-bar chip: current mode + Cloudflare daily status. Tap for details.
class StatusChip extends StatelessWidget {
  final AppState state;
  const StatusChip({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final cf = state.cloudflareStatus;
        final mode = state.mode;
        final usesCf =
            mode == ProviderMode.auto || mode == ProviderMode.cloudflareOnly;
        IconData icon = Icons.bolt;
        Color color = const Color(0xFF34D399);
        String text = mode.chipLabel;
        if (usesCf) {
          switch (cf) {
            case CloudflareStatus.ready:
              color = const Color(0xFFF6821F);
              text = mode == ProviderMode.auto
                  ? 'Auto · Cloudflare'
                  : 'Cloudflare';
            case CloudflareStatus.notConfigured:
              icon = Icons.cloud_off;
              color = const Color(0xFF34D399);
              text = mode == ProviderMode.auto
                  ? 'Auto · Pollinations'
                  : 'Cloudflare not set up';
            case CloudflareStatus.quotaHit:
              icon = Icons.hourglass_bottom;
              color = Colors.amber;
              text =
                  'CF limit · resets ${DateFormat.jm().format(state.cfQuotaUntil!.toLocal())}';
          }
        } else if (mode.name == 'xai' ||
            mode.name == 'openai' ||
            mode.name == 'stability') {
          icon = Icons.payments_outlined;
          color = Colors.white70;
          text = '${mode.chipLabel} · paid';
        }
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ActionChip(
            avatar: Icon(icon, size: 16, color: color),
            label: Text(text, style: TextStyle(fontSize: 12, color: color)),
            side: BorderSide(color: color.withValues(alpha: 0.5)),
            onPressed: () => showStatusSheet(context, state),
          ),
        );
      },
    );
  }
}

void showStatusSheet(BuildContext context, AppState state) {
  state.refreshUsage();
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (context) => ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final cf = state.cloudflareStatus;
        final cooldown = PollinationsClient(
          state.httpClient,
        ).cooldownRemaining();
        final t = Theme.of(context).textTheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Provider status', style: t.titleLarge),
              const SizedBox(height: 4),
              Text('Mode: ${state.mode.label}', style: t.bodyMedium),
              const Divider(height: 28),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.cloud, color: Color(0xFFF6821F)),
                title: const Text(
                  'Cloudflare FLUX.1 schnell (free daily allowance)',
                ),
                subtitle: Text(switch (cf) {
                  CloudflareStatus.notConfigured =>
                    'Not set up yet. Add the Worker URL in Settings to turn it on.',
                  CloudflareStatus.ready =>
                    'Ready. Square images, about 2–5 s each.',
                  CloudflareStatus.quotaHit =>
                    'Daily free images used up. Resets at ${resetTimeLabel(state.cfQuotaUntil!)}.',
                }),
              ),
              if (cf != CloudflareStatus.notConfigured)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.data_usage),
                  title: Text(usageHeadline(state.usage)),
                  subtitle: Text(
                    '${usageDetail(state.usage)}. '
                    'Cloudflare\'s dashboard is the exact source; image neurons are estimated from its price list.',
                  ),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.local_florist,
                  color: Color(0xFF34D399),
                ),
                title: const Text('Pollinations (free backup, no account)'),
                subtitle: Text(
                  cooldown > Duration.zero
                      ? 'Next free slot in ${cooldown.inSeconds}s (one image every 45 s).'
                      : 'Ready. One image every 45 s; small logo in the corner.',
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// Full-screen pinch-to-zoom viewer.
class ZoomViewer extends StatelessWidget {
  final File file;
  final String heroTag;
  const ZoomViewer({super.key, required this.file, required this.heroTag});

  static Future<void> open(BuildContext context, File file, String heroTag) =>
      Navigator.of(context).push(
        PageRouteBuilder(
          opaque: false,
          barrierColor: Colors.black,
          pageBuilder: (_, _, _) => ZoomViewer(file: file, heroTag: heroTag),
          transitionsBuilder: (_, a, _, c) =>
              FadeTransition(opacity: a, child: c),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: InteractiveViewer(
        minScale: 1,
        maxScale: 6,
        child: Center(
          child: Hero(
            tag: heroTag,
            child: Image.file(file, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}

/// Ticks every [interval] while mounted; used for timers and countdowns.
class Ticker extends StatefulWidget {
  final Duration interval;
  final WidgetBuilder builder;
  const Ticker({
    super.key,
    this.interval = const Duration(milliseconds: 100),
    required this.builder,
  });
  @override
  State<Ticker> createState() => _TickerState();
}

class _TickerState extends State<Ticker> {
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(widget.interval, (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
