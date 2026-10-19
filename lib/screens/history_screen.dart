import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/gen_types.dart';
import '../core/prompt_presets.dart';
import '../services/app_state.dart';
import '../services/history_store.dart';
import '../services/image_actions.dart';
import '../widgets/common.dart';

class HistoryScreen extends StatelessWidget {
  final AppState state;
  const HistoryScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final items = state.history.items;
        return Scaffold(
          appBar: AppBar(
            title: Text('History (${items.length})'),
            actions: [
              if (items.isNotEmpty)
                IconButton(
                  tooltip: 'Delete all',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: () async {
                    final ok = await _confirm(context, 'Delete all ${items.length} images?',
                        'They are removed from Imagine Pad. Copies you saved to the gallery stay.');
                    if (ok) await state.clearHistory();
                  },
                ),
            ],
          ),
          body: items.isEmpty
              ? const _Empty()
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final it = items[i];
                    final tag = 'hist-${it.id}';
                    return GestureDetector(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => HistoryDetail(state: state, item: it, heroTag: tag))),
                      onLongPress: () async {
                        if (await _confirm(context, 'Delete this image?', it.basePrompt)) {
                          await state.deleteHistory(it);
                        }
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Stack(fit: StackFit.expand, children: [
                          Hero(
                            tag: tag,
                            child: Image.file(state.history.fileFor(it),
                                fit: BoxFit.cover, cacheWidth: 400),
                          ),
                          Positioned(left: 6, top: 6, child: ProviderBadge(it.provider, dense: true)),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(8, 18, 8, 6),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Colors.transparent, Colors.black87]),
                              ),
                              child: Text(it.basePrompt,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11, color: Colors.white)),
                            ),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String body) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body, maxLines: 4, overflow: TextOverflow.ellipsis),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
      ],
    ),
  );
  return r ?? false;
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.photo_library_outlined,
                size: 64, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            const Text('Images you generate show up here.', textAlign: TextAlign.center),
          ]),
        ),
      );
}

class HistoryDetail extends StatelessWidget {
  final AppState state;
  final HistoryItem item;
  final String heroTag;
  const HistoryDetail({super.key, required this.state, required this.item, required this.heroTag});

  @override
  Widget build(BuildContext context) {
    final file = state.history.fileFor(item);
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final style = presetById(item.style);
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await _confirm(context, 'Delete this image?', item.basePrompt)) {
                await state.deleteHistory(item);
                if (context.mounted) Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
        GestureDetector(
          onTap: () => ZoomViewer.open(context, file, '$heroTag-z'),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Hero(tag: heroTag, child: Image.file(file, fit: BoxFit.contain)),
          ),
        ),
        const SizedBox(height: 14),
        Row(children: [
          ProviderBadge(item.provider),
          const Spacer(),
          Text(DateFormat.yMMMd().add_jm().format(item.createdAt),
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ]),
        const SizedBox(height: 12),
        SelectableText(item.basePrompt, style: t.bodyLarge),
        const SizedBox(height: 8),
        Text(
          [
            if (style.id != 'none') 'Style: ${style.label}',
            'Shape: ${item.aspect.label}',
            'Seed: ${item.seed}',
            'Model: ${item.model}',
          ].join(' · '),
          style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        if (item.note != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(item.note!, style: t.bodySmall?.copyWith(color: Colors.amber)),
          ),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonalIcon(
              onPressed: () => ImageActions.saveToGallery(context, file),
              icon: const Icon(Icons.download),
              label: const Text('Save to gallery')),
          FilledButton.tonalIcon(
              onPressed: () => ImageActions.share(context, file, item.basePrompt),
              icon: const Icon(Icons.share),
              label: const Text('Share')),
          OutlinedButton.icon(
              onPressed: () => ImageActions.copyPrompt(context, item.prompt),
              icon: const Icon(Icons.copy),
              label: const Text('Copy prompt')),
          OutlinedButton.icon(
              onPressed: () {
                state.reusePrompt(item);
                Navigator.pop(context);
              },
              icon: const Icon(Icons.edit_note),
              label: const Text('Use this prompt')),
        ]),
      ]),
    );
  }
}
