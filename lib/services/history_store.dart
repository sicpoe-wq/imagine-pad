import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/gen_types.dart';

/// What produced a History entry.
enum HistoryKind { generate, edit, upscale }

extension HistoryKindInfo on HistoryKind {
  String get label => switch (this) {
    HistoryKind.generate => 'Generated',
    HistoryKind.edit => 'Edited',
    HistoryKind.upscale => 'Upscaled 2×',
  };
  static HistoryKind parse(String? s) => HistoryKind.values.firstWhere(
    (k) => k.name == s,
    orElse: () => HistoryKind.generate,
  );
}

class HistoryItem {
  final String id;
  final String prompt; // full prompt sent
  final String basePrompt; // what Tim typed
  final String style;
  final ImageAspect aspect;
  final int seed;
  final ProviderId provider;
  final String model;
  final DateTime createdAt;
  final String fileName;
  final String? note;
  final bool favorite;
  final HistoryKind kind;

  /// History id this was made from (edit / upscale), if any.
  final String? parentId;

  /// For edits: the (resized) input image, stored next to the result for before/after.
  final String? sourceFileName;

  /// Images made together in one batch share this id.
  final String? batchId;

  const HistoryItem({
    required this.id,
    required this.prompt,
    required this.basePrompt,
    required this.style,
    required this.aspect,
    required this.seed,
    required this.provider,
    required this.model,
    required this.createdAt,
    required this.fileName,
    this.note,
    this.favorite = false,
    this.kind = HistoryKind.generate,
    this.parentId,
    this.sourceFileName,
    this.batchId,
  });

  HistoryItem copyWith({bool? favorite}) => HistoryItem(
    id: id,
    prompt: prompt,
    basePrompt: basePrompt,
    style: style,
    aspect: aspect,
    seed: seed,
    provider: provider,
    model: model,
    createdAt: createdAt,
    fileName: fileName,
    note: note,
    favorite: favorite ?? this.favorite,
    kind: kind,
    parentId: parentId,
    sourceFileName: sourceFileName,
    batchId: batchId,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'prompt': prompt,
    'basePrompt': basePrompt,
    'style': style,
    'aspect': aspect.name,
    'seed': seed,
    'provider': provider.name,
    'model': model,
    'createdAt': createdAt.toIso8601String(),
    'fileName': fileName,
    if (note != null) 'note': note,
    if (favorite) 'favorite': true,
    if (kind != HistoryKind.generate) 'kind': kind.name,
    if (parentId != null) 'parentId': parentId,
    if (sourceFileName != null) 'sourceFileName': sourceFileName,
    if (batchId != null) 'batchId': batchId,
  };

  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(
    id: j['id'] as String,
    prompt: j['prompt'] as String? ?? '',
    basePrompt: j['basePrompt'] as String? ?? j['prompt'] as String? ?? '',
    style: j['style'] as String? ?? 'none',
    aspect: AspectInfo.parse(j['aspect'] as String?),
    seed: (j['seed'] as num?)?.toInt() ?? 0,
    provider: ProviderIdInfo.parse(j['provider'] as String?),
    model: j['model'] as String? ?? '',
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
    fileName: j['fileName'] as String,
    note: j['note'] as String?,
    favorite: j['favorite'] == true,
    kind: HistoryKindInfo.parse(j['kind'] as String?),
    parentId: j['parentId'] as String?,
    sourceFileName: j['sourceFileName'] as String?,
    batchId: j['batchId'] as String?,
  );
}

enum HistorySort { newest, oldest }

/// Pure filter used by the History screen: text search over prompts,
/// favorites-only and date sort.
List<HistoryItem> queryHistory(
  List<HistoryItem> items, {
  String text = '',
  bool favoritesOnly = false,
  HistorySort sort = HistorySort.newest,
}) {
  final words = text
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  final out = items.where((i) {
    if (favoritesOnly && !i.favorite) return false;
    if (words.isEmpty) return true;
    final hay = '${i.basePrompt} ${i.prompt} ${i.kind.label}'.toLowerCase();
    return words.every(hay.contains);
  }).toList();
  out.sort(
    (a, b) => sort == HistorySort.newest
        ? b.createdAt.compareTo(a.createdAt)
        : a.createdAt.compareTo(b.createdAt),
  );
  return out;
}

/// Generated images live in app storage: `docs/history/ID.ext`, with an
/// index.json listing prompts, provider and date.
class HistoryStore {
  final Directory dir;
  List<HistoryItem> items = [];
  HistoryStore(this.dir);

  File get _index => File('${dir.path}/index.json');
  File fileFor(HistoryItem i) => File('${dir.path}/${i.fileName}');
  File? sourceFileFor(HistoryItem i) {
    if (i.sourceFileName == null) return null;
    final f = File('${dir.path}/${i.sourceFileName}');
    return f.existsSync() ? f : null;
  }

  HistoryItem? byId(String? id) {
    if (id == null) return null;
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  Future<void> load() async {
    await dir.create(recursive: true);
    if (!await _index.exists()) return;
    try {
      final list = jsonDecode(await _index.readAsString()) as List;
      items = list
          .map((e) => HistoryItem.fromJson(e as Map<String, dynamic>))
          .where((i) => fileFor(i).existsSync())
          .toList();
    } catch (_) {
      items = [];
    }
  }

  Future<void> save() async {
    final tmp = File('${_index.path}.tmp');
    await tmp.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
    await tmp.rename(_index.path);
  }

  int _seq = 0;
  String _newId(int salt) {
    _seq = (_seq + 1) % 1000;
    return '${DateTime.now().millisecondsSinceEpoch}_${salt % 100000}_$_seq';
  }

  Future<HistoryItem> add({
    required Uint8List bytes,
    required String mime,
    required String prompt,
    required String basePrompt,
    required String style,
    required ImageAspect aspect,
    required int seed,
    required ProviderId provider,
    required String model,
    String? note,
    HistoryKind kind = HistoryKind.generate,
    String? parentId,
    Uint8List? sourceBytes,
    String? batchId,
  }) async {
    final now = DateTime.now();
    final id = _newId(seed);
    String? src;
    if (sourceBytes != null) {
      src = '${id}_src.${extForMime(sniffMime(sourceBytes))}';
      await File('${dir.path}/$src').writeAsBytes(sourceBytes, flush: true);
    }
    final item = HistoryItem(
      id: id,
      prompt: prompt,
      basePrompt: basePrompt,
      style: style,
      aspect: aspect,
      seed: seed,
      provider: provider,
      model: model,
      createdAt: now,
      fileName: '$id.${extForMime(mime)}',
      note: note,
      kind: kind,
      parentId: parentId,
      sourceFileName: src,
      batchId: batchId,
    );
    await fileFor(item).writeAsBytes(bytes, flush: true);
    items.insert(0, item);
    await save();
    return item;
  }

  Future<HistoryItem> setFavorite(HistoryItem item, bool fav) async {
    final idx = items.indexWhere((e) => e.id == item.id);
    final updated = item.copyWith(favorite: fav);
    if (idx >= 0) items[idx] = updated;
    await save();
    return updated;
  }

  Future<void> delete(HistoryItem item) async {
    items.removeWhere((e) => e.id == item.id);
    for (final f in [fileFor(item), sourceFileFor(item)]) {
      try {
        await f?.delete();
      } catch (_) {}
    }
    await save();
  }

  Future<void> clear() async {
    for (final i in List.of(items)) {
      for (final f in [fileFor(i), sourceFileFor(i)]) {
        try {
          await f?.delete();
        } catch (_) {}
      }
    }
    items = [];
    await save();
  }

  /// Merge restored items (files already copied into [dir]). Skips ids that exist.
  Future<int> mergeRestored(List<HistoryItem> restored) async {
    final have = items.map((e) => e.id).toSet();
    var added = 0;
    for (final r in restored) {
      if (have.contains(r.id) || !fileFor(r).existsSync()) continue;
      items.add(r);
      have.add(r.id);
      added++;
    }
    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await save();
    return added;
  }
}
