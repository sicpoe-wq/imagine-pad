import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/gen_types.dart';
import '../core/prompt_presets.dart';
import '../providers/generation_service.dart';
import '../services/app_state.dart';
import '../services/history_store.dart';
import '../services/image_actions.dart';
import '../widgets/common.dart';

class CreateScreen extends StatefulWidget {
  final AppState state;
  const CreateScreen({super.key, required this.state});
  @override
  State<CreateScreen> createState() => _CreateScreenState();
}

class _CreateScreenState extends State<CreateScreen> {
  AppState get s => widget.state;
  final _prompt = TextEditingController();
  final _seed = TextEditingController();
  late String _style = s.settings.lastStyle;
  late ImageAspect _aspect = s.settings.lastAspect;
  bool _fixedSeed = false;

  bool _busy = false;
  ProviderId? _trying;
  final _watch = Stopwatch();

  HistoryItem? _result;
  GenException? _error;
  List<Attempt> _attempts = const [];

  // Pollinations cooldown auto-retry.
  Timer? _countdown;
  int _countdownLeft = 0;
  GenRequest? _pendingReq;
  int _autoRetries = 0;

  @override
  void initState() {
    super.initState();
    s.reuse.addListener(_onReuse);
  }

  @override
  void dispose() {
    s.reuse.removeListener(_onReuse);
    _countdown?.cancel();
    _prompt.dispose();
    _seed.dispose();
    super.dispose();
  }

  void _onReuse() {
    final item = s.reuse.value;
    if (item == null) return;
    setState(() {
      _prompt.text = item.basePrompt;
      _style = item.style;
      _aspect = item.aspect;
      _fixedSeed = true;
      _seed.text = '${item.seed}';
    });
    s.reuse.value = null;
  }

  GenRequest? _buildRequest({int? seed}) {
    final base = _prompt.text.trim();
    if (base.isEmpty) return null;
    final st = presetById(_style);
    final seedVal = seed ??
        (_fixedSeed ? int.tryParse(_seed.text.trim()) ?? s.randomSeed() : s.randomSeed());
    return GenRequest(
      prompt: composePrompt(base, st),
      aspect: _aspect,
      seed: seedVal,
      steps: s.settings.steps,
    );
  }

  Future<void> _generate({int? seed, GenRequest? req, bool isAutoRetry = false}) async {
    FocusScope.of(context).unfocus();
    final r = req ?? _buildRequest(seed: seed);
    if (r == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Type a prompt first')));
      return;
    }
    if (!isAutoRetry) _autoRetries = 0;
    _cancelCountdown();
    s.settings.lastStyle = _style;
    s.settings.lastAspect = _aspect;
    final base = _prompt.text.trim();
    final style = _style;
    setState(() {
      _busy = true;
      _error = null;
      _attempts = const [];
      _trying = null;
    });
    _watch
      ..reset()
      ..start();
    try {
      final out = await s.buildService().generate(r, onTrying: (p) {
        if (mounted) setState(() => _trying = p);
      });
      final item = await s.history.add(
        bytes: out.image.bytes,
        mime: out.image.mime,
        prompt: r.prompt,
        basePrompt: base,
        style: style,
        aspect: r.aspect,
        seed: out.image.seed,
        provider: out.image.provider,
        model: out.image.model,
        note: out.image.note,
      );
      s.touch();
      if (!mounted) return;
      setState(() {
        _result = item;
        _attempts = out.attempts;
      });
    } on AllProvidersFailed catch (e) {
      if (!mounted) return;
      final last = e.last;
      setState(() {
        _error = last;
        _attempts = e.attempts;
      });
      if (last.code == GenErrorCode.rateLimited &&
          last.retryAfter != null &&
          last.retryAfter! <= const Duration(minutes: 3) &&
          _autoRetries < 3) {
        _startCountdown(r, last.retryAfter!);
      }
    } finally {
      _watch.stop();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startCountdown(GenRequest r, Duration d) {
    _pendingReq = r;
    _countdownLeft = d.inSeconds.clamp(1, 600);
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _countdownLeft--);
      if (_countdownLeft <= 0) {
        t.cancel();
        _autoRetries++;
        _generate(req: _pendingReq, isAutoRetry: true);
      }
    });
    setState(() {});
  }

  void _cancelCountdown() {
    _countdown?.cancel();
    _countdown = null;
    _countdownLeft = 0;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Icon(Icons.auto_awesome, color: cs.primary),
          const SizedBox(width: 8),
          const Text('Imagine Pad', style: TextStyle(fontWeight: FontWeight.w700)),
        ]),
        actions: [StatusChip(state: s)],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          TextField(
            controller: _prompt,
            minLines: 3,
            maxLines: 6,
            maxLength: 1500,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: 'Describe the image you want…',
              counterText: '',
              suffixIcon: _prompt.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(_prompt.clear)),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: examplePrompts.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => ActionChip(
                avatar: const Icon(Icons.lightbulb_outline, size: 16),
                label: Text(examplePrompts[i], overflow: TextOverflow.ellipsis),
                onPressed: () => setState(() => _prompt.text = examplePrompts[i]),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text('Style', style: t.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in stylePresets)
              ChoiceChip(
                label: Text(p.label),
                selected: _style == p.id,
                onSelected: (_) => setState(() => _style = p.id),
              ),
          ]),
          const SizedBox(height: 18),
          Text('Shape', style: t.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ImageAspect>(
            segments: const [
              ButtonSegment(
                  value: ImageAspect.square, label: Text('Square'), icon: Icon(Icons.crop_square)),
              ButtonSegment(
                  value: ImageAspect.portrait,
                  label: Text('Portrait'),
                  icon: Icon(Icons.crop_portrait)),
              ButtonSegment(
                  value: ImageAspect.landscape,
                  label: Text('Landscape'),
                  icon: Icon(Icons.crop_landscape)),
            ],
            selected: {_aspect},
            onSelectionChanged: (v) => setState(() => _aspect = v.first),
          ),
          if (_aspect != ImageAspect.square && _cfLikely)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Cloudflare FLUX makes square images only; other providers follow the shape.',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
          const SizedBox(height: 8),
          Row(children: [
            Switch(value: _fixedSeed, onChanged: (v) => setState(() => _fixedSeed = v)),
            const SizedBox(width: 6),
            const Text('Fixed seed'),
            const SizedBox(width: 12),
            if (_fixedSeed)
              Expanded(
                child: TextField(
                  controller: _seed,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'e.g. 42',
                    suffixIcon: IconButton(
                      tooltip: 'Random',
                      icon: const Icon(Icons.casino_outlined),
                      onPressed: () => setState(() => _seed.text = '${s.randomSeed()}'),
                    ),
                  ),
                ),
              )
            else
              Text('random each time', style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ]),
          const SizedBox(height: 14),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              onPressed: _busy ? null : () => _generate(),
              icon: _busy
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                  : const Icon(Icons.auto_awesome),
              label: Text(_busy ? 'Generating…' : 'Generate',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            ),
          ),
          if (_busy) _progress(t, cs),
          if (_countdown != null && !_busy) _countdownCard(t, cs),
          if (_error != null && !_busy && _countdown == null) _errorCard(t, cs),
          if (_result != null) ...[
            const SizedBox(height: 18),
            ResultCard(
              state: s,
              item: _result!,
              busy: _busy,
              onVariation: () => _generate(seed: s.randomSeed()),
              onRegenerate: () => _generate(seed: _result!.seed),
            ),
          ],
        ],
      ),
    );
  }

  bool get _cfLikely =>
      (s.mode == ProviderMode.auto || s.mode == ProviderMode.cloudflareOnly) &&
      s.cloudflareStatus == CloudflareStatus.ready;

  Widget _progress(TextTheme t, ColorScheme cs) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Ticker(builder: (_) {
          final secs = (_watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
          final who = _trying?.label ?? 'provider';
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: const LinearProgressIndicator(minHeight: 6)),
            const SizedBox(height: 8),
            Text('Generating with $who… ${secs}s',
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            if (_trying == ProviderId.pollinations)
              Text('Pollinations is free and can take 10–60 s.',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ]);
        }),
      );

  Widget _countdownCard(TextTheme t, ColorScheme cs) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Card(
          color: cs.secondaryContainer.withValues(alpha: 0.5),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              SizedBox(
                width: 46,
                height: 46,
                child: Stack(alignment: Alignment.center, children: [
                  CircularProgressIndicator(
                      value: _countdownLeft / 45.0 > 1 ? 1 : _countdownLeft / 45.0),
                  Text('$_countdownLeft', style: t.titleMedium),
                ]),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Waiting for a free slot', style: t.titleSmall),
                  Text(
                      '${_error?.friendly ?? 'The free service is busy.'} '
                      'It will try again automatically.',
                      style: t.bodySmall),
                ]),
              ),
              TextButton(
                  onPressed: () => setState(_cancelCountdown), child: const Text('Cancel')),
            ]),
          ),
        ),
      );

  Widget _errorCard(TextTheme t, ColorScheme cs) {
    final e = _error!;
    final tried = _attempts
        .where((a) => a.error != null)
        .map((a) => '${a.provider.shortLabel}: ${a.skipped ? 'skipped – ' : ''}${a.error!.friendly}')
        .toList();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Card(
        color: cs.errorContainer.withValues(alpha: 0.35),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.error_outline, color: cs.error),
              const SizedBox(width: 8),
              Expanded(child: Text(e.friendly, style: t.titleSmall)),
            ]),
            if (tried.length > 1) ...[
              const SizedBox(height: 8),
              for (final l in tried) Text('• $l', style: t.bodySmall),
            ],
            if (e.code == GenErrorCode.notConfigured && e.provider.isPaid)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Add your key in Settings, or switch the provider back to Auto.',
                    style: t.bodySmall),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                  onPressed: () => _generate(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again')),
            ),
          ]),
        ),
      ),
    );
  }
}

class ResultCard extends StatelessWidget {
  final AppState state;
  final HistoryItem item;
  final bool busy;
  final VoidCallback onVariation;
  final VoidCallback onRegenerate;
  const ResultCard(
      {super.key,
      required this.state,
      required this.item,
      required this.busy,
      required this.onVariation,
      required this.onRegenerate});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final file = state.history.fileFor(item);
    final tag = 'result-${item.id}';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GestureDetector(
          onTap: () => ZoomViewer.open(context, file, tag),
          child: Stack(children: [
            Hero(
              tag: tag,
              child: Image.file(file, fit: BoxFit.cover, gaplessPlayback: true),
            ),
            Positioned(left: 10, top: 10, child: ProviderBadge(item.provider)),
            const Positioned(
              right: 10,
              top: 10,
              child: CircleAvatar(
                  radius: 16,
                  backgroundColor: Colors.black54,
                  child: Icon(Icons.zoom_out_map, size: 18, color: Colors.white)),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.basePrompt, maxLines: 3, overflow: TextOverflow.ellipsis, style: t.bodyMedium),
            const SizedBox(height: 4),
            Text('${item.provider.label} · seed ${item.seed}',
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            if (item.note != null)
              Text(item.note!, style: t.bodySmall?.copyWith(color: Colors.amber)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
          child: Wrap(alignment: WrapAlignment.spaceEvenly, children: [
            _Act(Icons.download, 'Save', () => ImageActions.saveToGallery(context, file)),
            _Act(Icons.share, 'Share', () => ImageActions.share(context, file, item.basePrompt)),
            _Act(Icons.shuffle, 'Variation', busy ? null : onVariation),
            _Act(Icons.refresh, 'Same seed', busy ? null : onRegenerate),
            _Act(Icons.copy, 'Copy prompt', () => ImageActions.copyPrompt(context, item.prompt)),
          ]),
        ),
      ]),
    );
  }
}

class _Act extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _Act(this.icon, this.label, this.onTap);
  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11)),
        ]),
      );
}
