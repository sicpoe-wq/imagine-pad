import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/gen_types.dart';
import '../core/prompt_presets.dart';
import '../services/app_state.dart';
import '../services/history_store.dart';
import '../services/image_actions.dart';
import '../widgets/common.dart';
import '../widgets/item_actions.dart';

class HistoryScreen extends StatefulWidget {
  final AppState state;
  const HistoryScreen({super.key, required this.state});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  AppState get state => widget.state;
  final _search = TextEditingController();
  bool _favoritesOnly = false;
  HistorySort _sort = HistorySort.newest;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final all = state.history.items;
        final items = queryHistory(
          all,
          text: _search.text,
          favoritesOnly: _favoritesOnly,
          sort: _sort,
        );
        final favCount = all.where((e) => e.favorite).length;
        final filtered = _search.text.trim().isNotEmpty || _favoritesOnly;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              filtered
                  ? 'History (${items.length} of ${all.length})'
                  : 'History (${all.length})',
            ),
            actions: [
              IconButton(
                tooltip: _sort == HistorySort.newest
                    ? 'Newest first'
                    : 'Oldest first',
                icon: Icon(
                  _sort == HistorySort.newest
                      ? Icons.arrow_downward
                      : Icons.arrow_upward,
                ),
                onPressed: () => setState(
                  () => _sort = _sort == HistorySort.newest
                      ? HistorySort.oldest
                      : HistorySort.newest,
                ),
              ),
              if (all.isNotEmpty)
                IconButton(
                  tooltip: 'Delete all',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: () async {
                    final ok = await _confirm(
                      context,
                      'Delete all ${all.length} images?',
                      'They are removed from Imagine Pad. Copies you saved to the gallery stay.',
                    );
                    if (ok) await state.clearHistory();
                  },
                ),
            ],
          ),
          body: all.isEmpty
              ? const _Empty()
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                      child: TextField(
                        controller: _search,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Search prompts',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () => setState(_search.clear),
                                ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                      child: Row(
                        children: [
                          FilterChip(
                            avatar: Icon(
                              Icons.star,
                              size: 18,
                              color: _favoritesOnly ? Colors.amber : null,
                            ),
                            label: Text('Favorites ($favCount)'),
                            selected: _favoritesOnly,
                            onSelected: (v) =>
                                setState(() => _favoritesOnly = v),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _sort == HistorySort.newest
                                ? 'Newest first'
                                : 'Oldest first',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: items.isEmpty
                          ? Center(
                              child: Text(
                                _favoritesOnly && _search.text.isEmpty
                                    ? 'No favorites yet. Tap the star on an image.'
                                    : 'No images match.',
                              ),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.all(12),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 2,
                                    mainAxisSpacing: 10,
                                    crossAxisSpacing: 10,
                                  ),
                              itemCount: items.length,
                              itemBuilder: (context, i) {
                                final it = items[i];
                                final tag = 'hist-${it.id}';
                                return GestureDetector(
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => HistoryDetail(
                                        state: state,
                                        item: it,
                                        heroTag: tag,
                                      ),
                                    ),
                                  ),
                                  onLongPress: () async {
                                    if (await _confirm(
                                      context,
                                      'Delete this image?',
                                      it.basePrompt,
                                    )) {
                                      await state.deleteHistory(it);
                                    }
                                  },
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Hero(
                                          tag: tag,
                                          child: Image.file(
                                            state.history.fileFor(it),
                                            fit: BoxFit.cover,
                                            cacheWidth: 400,
                                          ),
                                        ),
                                        Positioned(
                                          left: 6,
                                          top: 6,
                                          child: it.kind == HistoryKind.generate
                                              ? ProviderBadge(
                                                  it.provider,
                                                  dense: true,
                                                )
                                              : _KindBadge(
                                                  ItemActions.kindBadge(it),
                                                ),
                                        ),
                                        Positioned(
                                          right: 0,
                                          top: 0,
                                          child: IconButton(
                                            visualDensity:
                                                VisualDensity.compact,
                                            tooltip: it.favorite
                                                ? 'Unstar'
                                                : 'Star',
                                            icon: Icon(
                                              it.favorite
                                                  ? Icons.star
                                                  : Icons.star_border,
                                              color: it.favorite
                                                  ? Colors.amber
                                                  : Colors.white70,
                                            ),
                                            onPressed: () =>
                                                state.toggleFavorite(it),
                                          ),
                                        ),
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: 0,
                                          child: Container(
                                            padding: const EdgeInsets.fromLTRB(
                                              8,
                                              18,
                                              8,
                                              6,
                                            ),
                                            decoration: const BoxDecoration(
                                              gradient: LinearGradient(
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                                colors: [
                                                  Colors.transparent,
                                                  Colors.black87,
                                                ],
                                              ),
                                            ),
                                            child: Text(
                                              it.basePrompt,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
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
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return r ?? false;
}

class _KindBadge extends StatelessWidget {
  final String text;
  const _KindBadge(this.text);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 10, color: Colors.white),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.photo_library_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          const Text(
            'Images you generate show up here.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class HistoryDetail extends StatelessWidget {
  final AppState state;
  final HistoryItem item0;
  final String heroTag;
  const HistoryDetail({
    super.key,
    required this.state,
    required HistoryItem item,
    required this.heroTag,
  }) : item0 = item;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) =>
          _detail(context, state.history.byId(item0.id) ?? item0),
    );
  }

  Widget _detail(BuildContext context, HistoryItem item) {
    final file = state.history.fileFor(item);
    final source = state.history.sourceFileFor(item);
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final style = presetById(item.style);
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: item.favorite
                ? 'Remove from favorites'
                : 'Add to favorites',
            icon: Icon(
              item.favorite ? Icons.star : Icons.star_border,
              color: item.favorite ? Colors.amber : null,
            ),
            onPressed: () => state.toggleFavorite(item),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await _confirm(
                context,
                'Delete this image?',
                item.basePrompt,
              )) {
                await state.deleteHistory(item);
                if (context.mounted) Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          GestureDetector(
            onTap: () => ZoomViewer.open(context, file, '$heroTag-z'),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Hero(
                tag: heroTag,
                child: Image.file(file, fit: BoxFit.contain),
              ),
            ),
          ),
          if (source != null) ...[
            const SizedBox(height: 10),
            Text(
              'Original (before the edit)',
              style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: Image.file(source, fit: BoxFit.contain),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              if (item.kind != HistoryKind.generate) ...[
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(item.kind.label),
                ),
                const SizedBox(width: 8),
              ],
              ProviderBadge(item.provider),
              const Spacer(),
              Text(
                DateFormat.yMMMd().add_jm().format(item.createdAt),
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
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
              child: Text(
                item.note!,
                style: t.bodySmall?.copyWith(color: Colors.amber),
              ),
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => ImageActions.saveToGallery(context, file),
                icon: const Icon(Icons.download),
                label: const Text('Save to gallery'),
              ),
              FilledButton.tonalIcon(
                onPressed: () =>
                    ImageActions.share(context, file, item.basePrompt),
                icon: const Icon(Icons.share),
                label: const Text('Share'),
              ),
              OutlinedButton.icon(
                onPressed: () => ImageActions.copyPrompt(context, item.prompt),
                icon: const Icon(Icons.copy),
                label: const Text('Copy prompt'),
              ),
              FilledButton.tonalIcon(
                onPressed: () {
                  state.openEditor(item);
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Edit this image'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => ItemActions.upscale(context, state, item),
                icon: const Icon(Icons.open_in_full),
                label: const Text('Upscale 2× (basic)'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  state.reusePrompt(item);
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.edit_note),
                label: const Text('Use this prompt'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
