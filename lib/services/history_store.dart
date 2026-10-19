import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/gen_types.dart';

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
  });

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
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
        fileName: j['fileName'] as String,
        note: j['note'] as String?,
      );
}

/// Generated images live in app storage: `docs/history/ID.ext`, with an
/// index.json listing prompts, provider and date.
class HistoryStore {
  final Directory dir;
  List<HistoryItem> items = [];
  HistoryStore(this.dir);

  File get _index => File('${dir.path}/index.json');
  File fileFor(HistoryItem i) => File('${dir.path}/${i.fileName}');

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

  Future<void> _save() async {
    final tmp = File('${_index.path}.tmp');
    await tmp.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
    await tmp.rename(_index.path);
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
  }) async {
    final now = DateTime.now();
    final id = '${now.millisecondsSinceEpoch}_${seed % 100000}';
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
    );
    await fileFor(item).writeAsBytes(bytes, flush: true);
    items.insert(0, item);
    await _save();
    return item;
  }

  Future<void> delete(HistoryItem item) async {
    items.removeWhere((e) => e.id == item.id);
    try {
      await fileFor(item).delete();
    } catch (_) {}
    await _save();
  }

  Future<void> clear() async {
    for (final i in List.of(items)) {
      try {
        await fileFor(i).delete();
      } catch (_) {}
    }
    items = [];
    await _save();
  }
}
