import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/gen_types.dart';
import '../core/prompt_presets.dart';
import '../providers/batch_runner.dart';
import '../providers/cloudflare_client.dart';
import '../providers/generation_service.dart';
import '../providers/pollinations_client.dart';
import '../services/app_state.dart';
import '../services/history_store.dart';
import '../services/image_actions.dart';
import '../widgets/common.dart';
import '../widgets/item_actions.dart';

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

  // Prompt enhancer.
  bool _enhancing = false;
  EnhanceResult? _enhanced;
  String? _enhanceError;

  // Batch.
  late int _count = s.settings.batchCount;
  List<HistoryItem?> _batch = const [];
  List<GenException?> _batchErrors = const [];
  List<bool> _batchRunning = const [];
  String? _batchStatus;
  bool _batchCancel = false;

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
    final seedVal =
        seed ??
        (_fixedSeed
            ? int.tryParse(_seed.text.trim()) ?? s.randomSeed()
            : s.randomSeed());
    return GenRequest(
      prompt: composePrompt(base, st),
      aspect: _aspect,
      seed: seedVal,
      steps: s.settings.steps,
    );
  }

  Future<void> _onGeneratePressed() async {
    if (_count > 1) return _generateBatch();
    return _generate();
  }

  Future<void> _enhance() async {
    final idea = _prompt.text.trim();
    if (idea.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Type a short idea first')));
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _enhancing = true;
      _enhanceError = null;
    });
    try {
      final r = await s.cloudflareClient.enhance(idea);
      if (!mounted) return;
      setState(() {
        _enhanced = r;
        _prompt.text = r.prompt;
      });
    } on GenException catch (e) {
      if (mounted) setState(() => _enhanceError = e.friendly);
    } finally {
      if (mounted) setState(() => _enhancing = false);
    }
  }

  void _undoEnhance() {
    final e = _enhanced;
    if (e == null) return;
    setState(() {
      _prompt.text = e.original;
      _enhanced = null;
    });
  }

  Future<void> _generateBatch() async {
    FocusScope.of(context).unfocus();
    final base = _prompt.text.trim();
    if (base.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Type a prompt first')));
      return;
    }
    _cancelCountdown();
    s.settings.lastStyle = _style;
    s.settings.lastAspect = _aspect;
    final n = _count;
    final style = _style;
    final reqs = [
      for (var i = 0; i < n; i++)
        GenRequest(
          prompt: composePrompt(base, presetById(style)),
          aspect: _aspect,
          seed: s.randomSeed(),
          steps: s.settings.steps,
        ),
    ];
    final batchId = 'b${DateTime.now().millisecondsSinceEpoch}';
    final service = s.buildService();
    final parallel = BatchRunner.parallelFor(service.firstProvider);
    setState(() {
      _busy = true;
      _batchCancel = false;
      _result = null;
      _error = null;
      _attempts = const [];
      _batch = List.filled(n, null);
      _batchErrors = List.filled(n, null);
      _batchRunning = List.filled(n, false);
      _batchStatus = parallel
          ? 'Making $n images at once…'
          : 'Pollinations makes one image every 45 s, so this takes a few minutes…';
    });
    _watch
      ..reset()
      ..start();
    final runner = BatchRunner(
      service: service,
      pollinationsCooldown: () =>
          PollinationsClient(s.httpClient).cooldownRemaining(),
    );
    try {
      await runner.run(
        reqs,
        isCancelled: () => _batchCancel || !mounted,
        onWaiting: (d, i) {
          if (mounted) {
            setState(
              () => _batchStatus =
                  'Image ${i + 1} of $n: Pollinations\' next free slot in ${d.inSeconds}s…',
            );
          }
        },
        onUpdate: (slot) async {
          if (!mounted) return;
          final o = slot.outcome;
          if (o != null && _batch[slot.index] == null) {
            final item = await s.history.add(
              bytes: o.image.bytes,
              mime: o.image.mime,
              prompt: reqs[slot.index].prompt,
              basePrompt: base,
              style: style,
              aspect: reqs[slot.index].aspect,
              seed: o.image.seed,
              provider: o.image.provider,
              model: o.image.model,
              note: o.image.note,
              batchId: batchId,
            );
            if (o.image.provider == ProviderId.cloudflare) {
              s.countCloudflareImage();
            }
            s.touch();
            if (!mounted) return;
            setState(() => _batch = [..._batch]..[slot.index] = item);
          }
          setState(() {
            _batchRunning = [..._batchRunning]..[slot.index] = slot.running;
            _batchErrors = [..._batchErrors]..[slot.index] = slot.failure?.last;
            final done = _batch.where((e) => e != null).length;
            _batchStatus = '$done of $n done';
          });
        },
      );
    } finally {
      _watch.stop();
      if (mounted) {
        setState(() {
          _busy = false;
          final done = _batch.where((e) => e != null).length;
          final failed = n - done;
          _batchStatus = _batchCancel
              ? 'Stopped: $done of $n made'
              : (failed == 0
                    ? '$n images in ${(_watch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s'
                    : '$done of $n made · $failed failed');
        });
      }
    }
  }

  Future<void> _generate({
    int? seed,
    GenRequest? req,
    bool isAutoRetry = false,
  }) async {
    FocusScope.of(context).unfocus();
    final r = req ?? _buildRequest(seed: seed);
    if (r == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Type a prompt first')));
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
      final out = await s.buildService().generate(
        r,
        onTrying: (p) {
          if (mounted) setState(() => _trying = p);
        },
      );
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
      if (out.image.provider == ProviderId.cloudflare) s.countCloudflareImage();
      s.touch();
      if (!mounted) return;
      setState(() {
        _result = item;
        _batch = const [];
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
        title: Row(
          children: [
            Icon(Icons.auto_awesome, color: cs.primary),
            const SizedBox(width: 8),
            const Text(
              'Imagine Pad',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
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
                      onPressed: () => setState(_prompt.clear),
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          _enhanceRow(t, cs),
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
                onPressed: () =>
                    setState(() => _prompt.text = examplePrompts[i]),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text('Style', style: t.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in stylePresets)
                ChoiceChip(
                  label: Text(p.label),
                  selected: _style == p.id,
                  onSelected: (_) => setState(() => _style = p.id),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text('Shape', style: t.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ImageAspect>(
            segments: const [
              ButtonSegment(
                value: ImageAspect.square,
                label: Text('Square'),
                icon: Icon(Icons.crop_square),
              ),
              ButtonSegment(
                value: ImageAspect.portrait,
                label: Text('Portrait'),
                icon: Icon(Icons.crop_portrait),
              ),
              ButtonSegment(
                value: ImageAspect.landscape,
                label: Text('Landscape'),
                icon: Icon(Icons.crop_landscape),
              ),
            ],
            selected: {_aspect},
            onSelectionChanged: (v) => setState(() => _aspect = v.first),
          ),
          if (_aspect != ImageAspect.square && _cfLikely)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Cloudflare FLUX makes square images only; other providers follow the shape.',
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Switch(
                value: _fixedSeed,
                onChanged: (v) => setState(() => _fixedSeed = v),
              ),
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
                        onPressed: () =>
                            setState(() => _seed.text = '${s.randomSeed()}'),
                      ),
                    ),
                  ),
                )
              else
                Text(
                  'random each time',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('Images', style: t.titleSmall),
              const SizedBox(width: 12),
              Expanded(
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1')),
                    ButtonSegment(value: 2, label: Text('2')),
                    ButtonSegment(value: 3, label: Text('3')),
                    ButtonSegment(value: 4, label: Text('4')),
                  ],
                  selected: {_count},
                  onSelectionChanged: _busy
                      ? null
                      : (v) => setState(() {
                          _count = v.first;
                          s.settings.batchCount = _count;
                        }),
                ),
              ),
            ],
          ),
          if (_count > 1 && !_cfLikely)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Pollinations makes one image every 45 s, so a batch of $_count takes about ${(_count - 1) * 45 ~/ 60 + 1} min.',
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 14),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              onPressed: _busy ? null : _onGeneratePressed,
              icon: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(
                _busy
                    ? 'Generating…'
                    : (_count > 1 ? 'Generate $_count' : 'Generate'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          UsageBar(state: s),
          if (_busy && _batch.isEmpty) _progress(t, cs),
          if (_countdown != null && !_busy) _countdownCard(t, cs),
          if (_error != null && !_busy && _countdown == null) _errorCard(t, cs),
          if (_batch.isNotEmpty) _batchView(t, cs),
          if (_result != null && _batch.isEmpty) ...[
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

  Widget _enhanceRow(TextTheme t, ColorScheme cs) {
    final cfOk = s.cloudflareStatus == CloudflareStatus.ready;
    final e = _enhanced;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed:
                  _enhancing || _busy || !cfOk || _prompt.text.trim().isEmpty
                  ? null
                  : _enhance,
              icon: _enhancing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_fix_normal, size: 18),
              label: Text(_enhancing ? 'Enhancing…' : 'Enhance'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                cfOk
                    ? 'Turns a short idea into a detailed prompt'
                    : 'Enhance needs Cloudflare',
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ],
        ),
        if (_enhanceError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _enhanceError!,
              style: t.bodySmall?.copyWith(color: cs.error),
            ),
          ),
        if (e != null)
          Card(
            margin: const EdgeInsets.only(top: 8),
            color: cs.primaryContainer.withValues(alpha: 0.25),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 6, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Enhanced. Before:',
                    style: t.labelMedium?.copyWith(color: cs.primary),
                  ),
                  const SizedBox(height: 2),
                  Text(e.original, style: t.bodySmall),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        onPressed: _undoEnhance,
                        icon: const Icon(Icons.undo),
                        label: const Text('Undo'),
                      ),
                      TextButton.icon(
                        onPressed: () => setState(() => _enhanced = null),
                        icon: const Icon(Icons.check),
                        label: const Text('Keep'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _batchView(TextTheme t, ColorScheme cs) {
    final made = _batch.whereType<HistoryItem>().toList();
    final favs = made.where((i) => i.favorite).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(_batchStatus ?? '', style: t.titleSmall)),
              if (_busy)
                TextButton(
                  onPressed: () => setState(() => _batchCancel = true),
                  child: const Text('Stop'),
                ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 4),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: _batch.length,
            itemBuilder: (_, i) => _batchTile(i, t, cs),
          ),
          const SizedBox(height: 8),
          if (made.isNotEmpty)
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _saveMany(made),
                  icon: const Icon(Icons.download),
                  label: Text('Save all (${made.length})'),
                ),
                OutlinedButton.icon(
                  onPressed: favs.isEmpty ? null : () => _saveMany(favs),
                  icon: const Icon(Icons.star),
                  label: Text('Save favorites (${favs.length})'),
                ),
              ],
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Tap the star to mark favorites; tap an image to see it full screen. All images are in History.',
              textAlign: TextAlign.center,
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _batchTile(int i, TextTheme t, ColorScheme cs) {
    final item = _batch[i];
    final err = _batchErrors.length > i ? _batchErrors[i] : null;
    final running = _batchRunning.length > i && _batchRunning[i];
    if (item == null) {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: cs.surfaceContainerHighest,
        ),
        padding: const EdgeInsets.all(10),
        child: Center(
          child: err != null && !running
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, color: cs.error),
                    const SizedBox(height: 4),
                    Text(
                      err.friendly,
                      textAlign: TextAlign.center,
                      style: t.bodySmall,
                      maxLines: 4,
                    ),
                  ],
                )
              : (_busy
                    ? const CircularProgressIndicator()
                    : Text('Not made', style: t.bodySmall)),
        ),
      );
    }
    final file = s.history.fileFor(item);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onTap: () => ZoomViewer.open(context, file, 'batch-${item.id}'),
            child: Hero(
              tag: 'batch-${item.id}',
              child: Image.file(file, fit: BoxFit.cover, cacheWidth: 500),
            ),
          ),
          Positioned(
            left: 6,
            top: 6,
            child: ProviderBadge(item.provider, dense: true),
          ),
          Positioned(
            right: 2,
            top: 2,
            child: IconButton(
              style: IconButton.styleFrom(backgroundColor: Colors.black45),
              icon: Icon(
                item.favorite ? Icons.star : Icons.star_border,
                color: item.favorite ? Colors.amber : Colors.white,
              ),
              onPressed: () async {
                final u = await s.toggleFavorite(item);
                if (mounted) setState(() => _batch = [..._batch]..[i] = u);
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveMany(List<HistoryItem> items) async {
    for (final i in items) {
      if (!mounted) return;
      await ImageActions.saveToGallery(
        context,
        s.history.fileFor(i),
        quiet: true,
      );
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved ${items.length} image${items.length == 1 ? '' : 's'} to your gallery',
          ),
        ),
      );
    }
  }

  bool get _cfLikely =>
      (s.mode == ProviderMode.auto || s.mode == ProviderMode.cloudflareOnly) &&
      s.cloudflareStatus == CloudflareStatus.ready;

  Widget _progress(TextTheme t, ColorScheme cs) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Ticker(
      builder: (_) {
        final secs = (_watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
        final who = _trying?.label ?? 'provider';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: const LinearProgressIndicator(minHeight: 6),
            ),
            const SizedBox(height: 8),
            Text(
              'Generating with $who… ${secs}s',
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (_trying == ProviderId.pollinations)
              Text(
                'Pollinations is free and can take 10–60 s.',
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
          ],
        );
      },
    ),
  );

  Widget _countdownCard(TextTheme t, ColorScheme cs) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Card(
      color: cs.secondaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox(
              width: 46,
              height: 46,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: _countdownLeft / 45.0 > 1
                        ? 1
                        : _countdownLeft / 45.0,
                  ),
                  Text('$_countdownLeft', style: t.titleMedium),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Waiting for a free slot', style: t.titleSmall),
                  Text(
                    '${_error?.friendly ?? 'The free service is busy.'} '
                    'It will try again automatically.',
                    style: t.bodySmall,
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => setState(_cancelCountdown),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _errorCard(TextTheme t, ColorScheme cs) {
    final e = _error!;
    final tried = _attempts
        .where((a) => a.error != null)
        .map(
          (a) =>
              '${a.provider.shortLabel}: ${a.skipped ? 'skipped – ' : ''}${a.error!.friendly}',
        )
        .toList();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Card(
        color: cs.errorContainer.withValues(alpha: 0.35),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.error_outline, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(e.friendly, style: t.titleSmall)),
                ],
              ),
              if (tried.length > 1) ...[
                const SizedBox(height: 8),
                for (final l in tried) Text('• $l', style: t.bodySmall),
              ],
              if (e.code == GenErrorCode.notConfigured && e.provider.isPaid)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Add your key in Settings, or switch the provider back to Auto.',
                    style: t.bodySmall,
                  ),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _generate(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ),
            ],
          ),
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
  const ResultCard({
    super.key,
    required this.state,
    required this.item,
    required this.busy,
    required this.onVariation,
    required this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final file = state.history.fileFor(item);
    final tag = 'result-${item.id}';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: () => ZoomViewer.open(context, file, tag),
            child: Stack(
              children: [
                Hero(
                  tag: tag,
                  child: Image.file(
                    file,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
                Positioned(
                  left: 10,
                  top: 10,
                  child: ProviderBadge(item.provider),
                ),
                Positioned(
                  right: 6,
                  top: 6,
                  child: ListenableBuilder(
                    listenable: state,
                    builder: (context, _) {
                      final cur = state.history.byId(item.id) ?? item;
                      return IconButton(
                        tooltip: cur.favorite ? 'Unstar' : 'Star',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black54,
                        ),
                        icon: Icon(
                          cur.favorite ? Icons.star : Icons.star_border,
                          color: cur.favorite ? Colors.amber : Colors.white,
                        ),
                        onPressed: () => state.toggleFavorite(cur),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.basePrompt,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${item.provider.label} · seed ${item.seed}',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                if (item.note != null)
                  Text(
                    item.note!,
                    style: t.bodySmall?.copyWith(color: Colors.amber),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Wrap(
              alignment: WrapAlignment.spaceEvenly,
              children: [
                _Act(
                  Icons.download,
                  'Save',
                  () => ImageActions.saveToGallery(context, file),
                ),
                _Act(
                  Icons.share,
                  'Share',
                  () => ImageActions.share(context, file, item.basePrompt),
                ),
                _Act(Icons.shuffle, 'Variation', busy ? null : onVariation),
                _Act(Icons.refresh, 'Same seed', busy ? null : onRegenerate),
                _Act(
                  Icons.copy,
                  'Copy prompt',
                  () => ImageActions.copyPrompt(context, item.prompt),
                ),
                _Act(
                  Icons.auto_fix_high,
                  'Edit',
                  busy ? null : () => state.openEditor(item),
                ),
                _Act(
                  Icons.open_in_full,
                  'Upscale 2×',
                  busy ? null : () => ItemActions.upscale(context, state, item),
                ),
              ],
            ),
          ),
        ],
      ),
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
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    ),
  );
}
