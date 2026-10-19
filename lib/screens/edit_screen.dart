import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/gen_types.dart';
import '../core/usage.dart';
import '../providers/cloudflare_client.dart';
import '../services/app_state.dart';
import '../services/history_store.dart';
import '../services/image_actions.dart';
import '../services/image_tools.dart';
import '../widgets/common.dart';

/// Image-to-image editing with Cloudflare FLUX.2 [klein] 4B.
class EditScreen extends StatefulWidget {
  final AppState state;
  const EditScreen({super.key, required this.state});
  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  AppState get s => widget.state;
  final _prompt = TextEditingController();
  final _picker = ImagePicker();

  Uint8List? _source; // prepared, <= 512x512 JPEG
  String? _sourceLabel;
  String? _parentId;
  double _strength = 0.5;

  bool _preparing = false;
  bool _busy = false;
  final _watch = Stopwatch();
  HistoryItem? _result;
  String? _error;
  bool _showBefore = false;

  static const ideas = [
    'Make it nighttime with stars',
    'Turn this into an anime illustration',
    'Make it a watercolor painting',
    'Add snow and winter light',
    'Make it look like a vintage photo',
    'Change the background to a beach at sunset',
  ];

  @override
  void initState() {
    super.initState();
    s.editSource.addListener(_onSource);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onSource());
  }

  @override
  void dispose() {
    s.editSource.removeListener(_onSource);
    _prompt.dispose();
    super.dispose();
  }

  void _onSource() {
    final item = s.editSource.value;
    if (item == null) return;
    s.editSource.value = null;
    _loadFile(
      s.history.fileFor(item),
      label: 'From History',
      parentId: item.id,
    );
  }

  Future<void> _loadFile(
    File f, {
    required String label,
    String? parentId,
  }) async {
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      final prepared = await ImageTools.prepareForEdit(await f.readAsBytes());
      if (!mounted) return;
      setState(() {
        _source = prepared;
        _sourceLabel = label;
        _parentId = parentId;
        _result = null;
        _showBefore = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open that image: $e');
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _pick(ImageSource src) async {
    try {
      // The picker downsizes natively first so big camera photos stay fast.
      final x = await _picker.pickImage(
        source: src,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 92,
      );
      if (x == null) return;
      await _loadFile(
        File(x.path),
        label: src == ImageSource.camera ? 'Camera photo' : 'Gallery photo',
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not get a photo: $e');
    }
  }

  Future<void> _pickHistory() async {
    final items = s.history.items;
    if (items.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No images in History yet')));
      return;
    }
    final chosen = await showModalBottomSheet<HistoryItem>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => SizedBox(
        height: MediaQuery.of(c).size.height * 0.7,
        child: GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: items.length,
          itemBuilder: (_, i) => GestureDetector(
            onTap: () => Navigator.pop(c, items[i]),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                s.history.fileFor(items[i]),
                fit: BoxFit.cover,
                cacheWidth: 300,
              ),
            ),
          ),
        ),
      ),
    );
    if (chosen != null) {
      await _loadFile(
        s.history.fileFor(chosen),
        label: 'From History',
        parentId: chosen.id,
      );
    }
  }

  String? get _unavailableReason => switch (s.cloudflareStatus) {
    CloudflareStatus.notConfigured =>
      'Editing needs Cloudflare, which is not set up in this version. Add the Worker in Settings.',
    CloudflareStatus.quotaHit =>
      'Cloudflare\'s free allowance for today is used up, so editing is unavailable until '
          '${resetTimeLabel(s.cfQuotaUntil!)}. (Pollinations can\'t edit photos.)',
    CloudflareStatus.ready => null,
  };

  Future<void> _run() async {
    FocusScope.of(context).unfocus();
    final src = _source;
    final p = _prompt.text.trim();
    if (src == null || p.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            src == null ? 'Pick a photo first' : 'Describe the edit first',
          ),
        ),
      );
      return;
    }
    final why = _unavailableReason;
    if (why != null) {
      setState(() => _error = why);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    _watch
      ..reset()
      ..start();
    try {
      final out = await s.cloudflareClient.edit(
        EditRequest(
          prompt: p,
          image: src,
          strength: _strength,
          seed: s.randomSeed(),
        ),
      );
      s.countCloudflareImage();
      final size = ImageTools.sizeOf(out.bytes);
      final aspect = size == null || (size.width - size.height).abs() < 32
          ? ImageAspect.square
          : (size.width > size.height
                ? ImageAspect.landscape
                : ImageAspect.portrait);
      final item = await s.history.add(
        bytes: out.bytes,
        mime: out.mime,
        prompt: p,
        basePrompt: p,
        style: 'none',
        aspect: aspect,
        seed: out.seed,
        provider: ProviderId.cloudflare,
        model: out.model,
        kind: HistoryKind.edit,
        parentId: _parentId,
        sourceBytes: src,
        note: 'Edit · change amount ${_strengthLabel(_strength)}',
      );
      s.touch();
      if (mounted) setState(() => _result = item);
    } on GenException catch (e) {
      if (e.code == GenErrorCode.quota) {
        s.settings.cfQuotaUntil = UsageInfo.nextReset(DateTime.now());
        s.touch();
      }
      if (mounted) setState(() => _error = e.friendly);
    } catch (e) {
      if (mounted) setState(() => _error = 'Edit failed: $e');
    } finally {
      _watch.stop();
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _strengthLabel(double v) =>
      v <= 0.35 ? 'subtle' : (v >= 0.75 ? 'bold' : 'balanced');

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final why = _unavailableReason;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Edit a photo'),
            actions: [StatusChip(state: s)],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              if (why != null)
                Card(
                  color: cs.errorContainer.withValues(alpha: 0.3),
                  child: ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(why),
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Gallery'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Camera'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _pickHistory,
                    icon: const Icon(Icons.history),
                    label: const Text('History'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _preview(t, cs),
              const SizedBox(height: 14),
              TextField(
                controller: _prompt,
                minLines: 2,
                maxLines: 4,
                maxLength: 600,
                decoration: const InputDecoration(
                  hintText: 'What should change? e.g. "make it night"',
                  counterText: '',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: ideas.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => ActionChip(
                    label: Text(ideas[i]),
                    onPressed: () => setState(() => _prompt.text = ideas[i]),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text('How much to change', style: t.titleSmall),
                  const Spacer(),
                  Text(
                    _strengthLabel(_strength),
                    style: t.bodyMedium?.copyWith(color: cs.primary),
                  ),
                ],
              ),
              Slider(
                value: _strength,
                divisions: 10,
                label: _strengthLabel(_strength),
                onChanged: _busy ? null : (v) => setState(() => _strength = v),
              ),
              Text(
                'Left keeps the photo close to the original; right lets the AI reimagine it. '
                'This model has no exact strength dial, so the slider guides it with instructions.',
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  onPressed: _busy || _preparing || why != null ? null : _run,
                  icon: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : const Icon(Icons.auto_fix_high),
                  label: Text(
                    _busy ? 'Editing…' : 'Apply edit',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (_busy)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Ticker(
                    builder: (_) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const LinearProgressIndicator(minHeight: 6),
                        const SizedBox(height: 6),
                        Text(
                          'Editing with Cloudflare FLUX.2 klein… '
                          '${(_watch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
                          style: t.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Card(
                    color: cs.errorContainer.withValues(alpha: 0.35),
                    child: ListTile(
                      leading: Icon(Icons.error_outline, color: cs.error),
                      title: Text(_error!),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              UsageBar(state: s),
            ],
          ),
        );
      },
    );
  }

  Widget _preview(TextTheme t, ColorScheme cs) {
    if (_preparing) {
      return const SizedBox(
        height: 220,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_source == null) {
      return Container(
        height: 200,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add_photo_alternate_outlined,
                size: 48,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(height: 8),
              Text('Pick a photo or one of your images', style: t.bodyMedium),
            ],
          ),
        ),
      );
    }
    final result = _result;
    final showAfter = result != null && !_showBefore;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: GestureDetector(
            onTap: result == null
                ? null
                : () => ZoomViewer.open(
                    context,
                    s.history.fileFor(result),
                    'edit-${result.id}',
                  ),
            child: Stack(
              children: [
                showAfter
                    ? Image.file(
                        s.history.fileFor(result),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      )
                    : Image.memory(
                        _source!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                Positioned(
                  left: 10,
                  top: 10,
                  child: Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      showAfter ? 'After' : 'Before · ${_sourceLabel ?? ''}',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (result != null) ...[
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: true,
                label: Text('Before'),
                icon: Icon(Icons.history_toggle_off),
              ),
              ButtonSegment(
                value: false,
                label: Text('After'),
                icon: Icon(Icons.auto_fix_high),
              ),
            ],
            selected: {_showBefore},
            onSelectionChanged: (v) => setState(() => _showBefore = v.first),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.spaceEvenly,
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: () => ImageActions.saveToGallery(
                  context,
                  s.history.fileFor(result),
                ),
                icon: const Icon(Icons.download),
                label: const Text('Save'),
              ),
              TextButton.icon(
                onPressed: () => ImageActions.share(
                  context,
                  s.history.fileFor(result),
                  result.basePrompt,
                ),
                icon: const Icon(Icons.share),
                label: const Text('Share'),
              ),
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () => _loadFile(
                        s.history.fileFor(result),
                        label: 'Previous edit',
                        parentId: result.id,
                      ),
                icon: const Icon(Icons.layers_outlined),
                label: const Text('Edit this result'),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _run,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Photos are shrunk to 512 px before upload (a model limit); the result comes back at up to 1024 px.',
            style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
