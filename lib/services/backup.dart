import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';

import 'history_store.dart';

/// History backup format (a plain .zip):
///   manifest.json  {app:"imagine_pad", format:1, exportedAt, appVersion, items:[HistoryItem json...]}
///   images/FILE_NAME (plus images/SOURCE_FILE_NAME for edits)
/// Images are stored uncompressed (JPEG/PNG are already compressed).
class HistoryBackup {
  static const app = 'imagine_pad';
  static const format = 1;

  /// Writes a backup of [items] (files from [historyDir]) to [zipPath].
  /// Returns the number of images written.
  static Future<int> export({
    required List<HistoryItem> items,
    required Directory historyDir,
    required String zipPath,
    String appVersion = '',
  }) async {
    final written = <Map<String, dynamic>>[];
    final enc = ZipFileEncoder()..create(zipPath, level: DeflateLevel.none);
    try {
      for (final i in items) {
        final f = File('${historyDir.path}/${i.fileName}');
        if (!await f.exists()) continue;
        await enc.addFile(f, 'images/${i.fileName}', DeflateLevel.none);
        if (i.sourceFileName != null) {
          final s = File('${historyDir.path}/${i.sourceFileName}');
          if (await s.exists()) {
            await enc.addFile(
              s,
              'images/${i.sourceFileName}',
              DeflateLevel.none,
            );
          }
        }
        written.add(i.toJson());
      }
      final manifest = utf8.encode(
        jsonEncode({
          'app': app,
          'format': format,
          'exportedAt': DateTime.now().toUtc().toIso8601String(),
          'appVersion': appVersion,
          'count': written.length,
          'items': written,
        }),
      );
      enc.addArchiveFile(ArchiveFile.bytes('manifest.json', manifest));
    } finally {
      await enc.close();
    }
    return written.length;
  }

  /// Reads a backup zip, copies images into [historyDir] and returns the items
  /// found (not yet merged). Throws [FormatException] for a non-Imagine-Pad zip.
  /// Skips entries with unsafe names.
  static Future<List<HistoryItem>> readInto({
    required String zipPath,
    required Directory historyDir,
  }) async {
    final input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final man = archive.findFile('manifest.json');
      if (man == null) {
        throw const FormatException(
          'Not an Imagine Pad backup (no manifest.json).',
        );
      }
      final j = jsonDecode(utf8.decode(man.readBytes() ?? const []));
      if (j is! Map || j['app'] != app) {
        throw const FormatException('Not an Imagine Pad backup.');
      }
      if ((j['format'] as num? ?? 0) > format) {
        throw const FormatException(
          'This backup was made by a newer Imagine Pad. Update the app first.',
        );
      }
      await historyDir.create(recursive: true);
      final out = <HistoryItem>[];
      for (final raw in (j['items'] as List? ?? const [])) {
        HistoryItem item;
        try {
          item = HistoryItem.fromJson(Map<String, dynamic>.from(raw as Map));
        } catch (_) {
          continue;
        }
        if (!_safeName(item.fileName)) continue;
        final entry = archive.findFile('images/${item.fileName}');
        final bytes = entry?.readBytes();
        if (bytes == null || bytes.isEmpty) continue;
        final dest = File('${historyDir.path}/${item.fileName}');
        if (!await dest.exists()) await dest.writeAsBytes(bytes, flush: true);
        final src = item.sourceFileName;
        if (src != null && _safeName(src)) {
          final sb = archive.findFile('images/$src')?.readBytes();
          final sd = File('${historyDir.path}/$src');
          if (sb != null && sb.isNotEmpty && !await sd.exists()) {
            await sd.writeAsBytes(sb, flush: true);
          }
        }
        out.add(item);
      }
      return out;
    } finally {
      await input.close();
    }
  }

  static bool _safeName(String n) =>
      n.isNotEmpty &&
      !n.contains('/') &&
      !n.contains('\\') &&
      !n.contains('..') &&
      n != 'index.json';

  static String suggestedName(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'ImaginePad-backup-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}.zip';
  }
}
