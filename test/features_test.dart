import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:imagine_pad/core/gen_types.dart';
import 'package:imagine_pad/core/usage.dart';
import 'package:imagine_pad/providers/batch_runner.dart';
import 'package:imagine_pad/providers/cloudflare_client.dart';
import 'package:imagine_pad/providers/generation_service.dart';
import 'package:imagine_pad/services/backup.dart';
import 'package:imagine_pad/services/history_store.dart';
import 'package:imagine_pad/services/image_tools.dart';

Uint8List jpegBytes(int w, int h, {int r = 200}) {
  final im = img.Image(width: w, height: h);
  for (final p in im) {
    p
      ..r = r
      ..g = (p.x * 255 ~/ w)
      ..b = (p.y * 255 ~/ h);
  }
  return Uint8List.fromList(img.encodeJpg(im));
}

final tinyJpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 1, 2, 3]);

CloudflareClient client(http.Client c, {void Function(UsageInfo)? onUsage}) =>
    CloudflareClient(
      c,
      workerUrl: 'https://w.example',
      sharedSecret: 's',
      onUsage: onUsage,
    );

void main() {
  group('UsageInfo', () {
    test('parses the Worker usage object', () {
      final u = UsageInfo.fromWorkerJson({
        'day': '2026-10-19',
        'images': 7,
        'generate': 5,
        'edit': 2,
        'enhance': 3,
        'neurons': 440,
        'neuronsEstimated': true,
        'resetsAt': '2026-10-20T00:00:00.000Z',
      })!;
      expect(u.images, 7);
      expect(u.edit, 2);
      expect(u.neurons, 440);
      expect(u.fromWorker, true);
      expect(u.resetsAt, DateTime.utc(2026, 10, 20));
      expect(u.imagesLeftEstimate, ((10000 - 440) / 57.6).floor());
      expect(UsageInfo.fromWorkerJson({'available': false}), isNull);
      expect(UsageInfo.fromWorkerJson('x'), isNull);
    });

    test(
      'local fallback estimates neurons and resets at the next 00:00 UTC',
      () {
        final now = DateTime.utc(2026, 10, 19, 15);
        final u = UsageInfo.local(10, now);
        expect(u.fromWorker, false);
        expect(u.neurons, isNull);
        expect(u.neuronsOrEstimate, closeTo(576, 0.01));
        expect(u.resetsAt, DateTime.utc(2026, 10, 20));
        expect(UsageInfo.local(174, now).imagesLeftEstimate, 0);
        expect(UsageInfo.local(500, now).fractionUsed, 1.0);
      },
    );

    test('a stale day shows zero for today', () {
      final u = UsageInfo.fromWorkerJson({
        'day': '2026-10-18',
        'images': 50,
        'neurons': 2880,
      })!;
      final cur = u.current(DateTime.utc(2026, 10, 19, 1));
      expect(cur.images, 0);
      expect(cur.neurons, 0);
      expect(cur.day, '2026-10-19');
    });
  });

  group('Cloudflare client: edit / enhance / usage', () {
    test(
      'edit posts base64 image + strength to /edit and parses result + usage',
      () async {
        late http.Request seen;
        UsageInfo? gotUsage;
        final c = client(
          MockClient((r) async {
            seen = r;
            return http.Response(
              jsonEncode({
                'image': base64Encode(tinyJpeg),
                'model': CloudflareClient.editModel,
                'seed': 9,
                'usage': {
                  'day': '2026-10-19',
                  'images': 1,
                  'edit': 1,
                  'neurons': 110,
                  'resetsAt': '2026-10-20T00:00:00Z',
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
          onUsage: (u) => gotUsage = u,
        );
        final out = await c.edit(
          EditRequest(prompt: 'night', image: tinyJpeg, strength: 0.3, seed: 9),
        );
        expect(seen.url.path, '/edit');
        expect(seen.headers['X-App-Secret'], 's');
        final b = jsonDecode(seen.body) as Map;
        expect(b['prompt'], 'night');
        expect(base64Decode(b['image'] as String), tinyJpeg);
        expect(b['strength'], 0.3);
        expect(b['seed'], 9);
        expect(out.bytes, tinyJpeg);
        expect(out.model, CloudflareClient.editModel);
        expect(gotUsage?.edit, 1);
      },
    );

    test('edit maps quota, too-large and unreachable errors', () async {
      for (final (status, code, expected) in [
        (429, 'quota', GenErrorCode.quota),
        (413, 'image_too_large', GenErrorCode.badRequest),
        (401, 'unauthorized', GenErrorCode.auth),
      ]) {
        final c = client(
          MockClient(
            (_) async => http.Response(
              jsonEncode({
                'error': {'code': code, 'message': 'm'},
              }),
              status,
            ),
          ),
        );
        await expectLater(
          c.edit(EditRequest(prompt: 'x', image: tinyJpeg)),
          throwsA(isA<GenException>().having((e) => e.code, 'code', expected)),
        );
      }
      final down = client(
        MockClient((_) async => throw http.ClientException('offline')),
      );
      await expectLater(
        down.edit(EditRequest(prompt: 'x', image: tinyJpeg)),
        throwsA(
          isA<GenException>().having(
            (e) => e.code,
            'code',
            GenErrorCode.network,
          ),
        ),
      );
    });

    test('enhance returns before/after and rejects empty prompts', () async {
      late http.Request seen;
      final c = client(
        MockClient((r) async {
          seen = r;
          return http.Response(
            jsonEncode({
              'prompt': ' A chrome robot dog. ',
              'original': 'robot dog',
              'model': 'm',
            }),
            200,
          );
        }),
      );
      final r = await c.enhance('robot dog', style: 'cinematic');
      expect(seen.url.path, '/enhance');
      expect(jsonDecode(seen.body), {
        'idea': 'robot dog',
        'style': 'cinematic',
      });
      expect(r.original, 'robot dog');
      expect(r.prompt, 'A chrome robot dog.');
      final bad = client(
        MockClient((_) async => http.Response(jsonEncode({'prompt': ''}), 200)),
      );
      await expectLater(bad.enhance('x'), throwsA(isA<GenException>()));
    });

    test('fetchUsage returns null on errors and reports good data', () async {
      final ok = client(
        MockClient((r) async {
          expect(r.url.path, '/usage');
          return http.Response(
            jsonEncode({
              'available': true,
              'day': '2026-10-19',
              'images': 3,
              'neurons': 170,
            }),
            200,
          );
        }),
      );
      expect((await ok.fetchUsage())?.images, 3);
      final no = client(MockClient((_) async => http.Response('nope', 500)));
      expect(await no.fetchUsage(), isNull);
    });

    test('generate responses with usage are reported', () async {
      UsageInfo? u;
      final c = client(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'image': base64Encode(tinyJpeg),
              'usage': {'day': '2026-10-19', 'images': 4, 'neurons': 230},
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
        onUsage: (x) => u = x,
      );
      await c.generate(const GenRequest(prompt: 'p', seed: 1));
      expect(u?.images, 4);
    });
  });

  group('BatchRunner', () {
    GenerationService svc(
      ProviderMode mode,
      ImageGenerator cf,
      ImageGenerator pol, {
      DateTime Function()? now,
    }) => GenerationService(
      mode: mode,
      cloudflare: cf,
      pollinations: pol,
      now: now,
    );

    test(
      'Cloudflare first: all requests start together and all succeed',
      () async {
        final cf = _Fake(
          ProviderId.cloudflare,
          latency: const Duration(milliseconds: 30),
        );
        final pol = _Fake(ProviderId.pollinations);
        final runner = BatchRunner(
          service: svc(ProviderMode.auto, cf, pol),
          pollinationsCooldown: () => Duration.zero,
        );
        final sw = Stopwatch()..start();
        final slots = await runner.run(
          List.generate(4, (i) => GenRequest(prompt: 'p$i', seed: i)),
        );
        expect(slots.every((s) => s.outcome != null), true);
        expect(cf.maxConcurrent, 4);
        expect(
          sw.elapsedMilliseconds,
          lessThan(110),
        ); // not 4 x 30 ms sequentially
        expect(pol.calls, 0);
      },
    );

    test(
      'Pollinations only: strictly sequential, waits out the cooldown between images',
      () async {
        final pol = _Fake(
          ProviderId.pollinations,
          latency: const Duration(milliseconds: 5),
        );
        final waits = <Duration>[];
        var cooldown = Duration.zero;
        final runner = BatchRunner(
          service: svc(
            ProviderMode.pollinationsOnly,
            _Fake(ProviderId.cloudflare),
            pol,
          ),
          pollinationsCooldown: () => cooldown,
          delay: (d) async {
            waits.add(d);
            cooldown = Duration.zero;
          },
        );
        // After each image Pollinations imposes its 45 s gap.
        pol.onCall = () => cooldown = const Duration(seconds: 45);
        final slots = await runner.run(
          List.generate(3, (i) => GenRequest(prompt: 'p$i', seed: i)),
        );
        expect(slots.every((s) => s.outcome != null), true);
        expect(pol.maxConcurrent, 1);
        expect(waits.length, 2);
        expect(waits.every((w) => w == const Duration(seconds: 45)), true);
      },
    );

    test(
      'Cloudflare quota mid-batch: falls back per image; Pollinations-limited ones are retried in sequence',
      () async {
        final cf = _Fake(
          ProviderId.cloudflare,
          script: [
            const GenException(
              GenErrorCode.quota,
              'q',
              provider: ProviderId.cloudflare,
            ),
          ],
        );
        var cooldown = Duration.zero;
        final pol = _Fake(
          ProviderId.pollinations,
          script: [
            null,
            GenException(
              GenErrorCode.rateLimited,
              'busy',
              provider: ProviderId.pollinations,
              retryAfter: const Duration(seconds: 45),
            ),
            null,
          ],
        );
        pol.onCall = () => cooldown = const Duration(seconds: 45);
        final delays = <Duration>[];
        final runner = BatchRunner(
          service: svc(ProviderMode.auto, cf, pol),
          pollinationsCooldown: () => cooldown,
          delay: (d) async {
            delays.add(d);
            cooldown = Duration.zero;
          },
        );
        final slots = await runner.run(
          List.generate(2, (i) => GenRequest(prompt: 'p$i', seed: i)),
        );
        expect(slots.where((s) => s.outcome != null).length, 2);
        expect(
          slots
              .where(
                (s) => s.outcome!.image.provider == ProviderId.pollinations,
              )
              .length,
          2,
        );
        expect(delays, isNotEmpty);
      },
    );

    test(
      'hard failures are reported per slot and cancellation stops waiting',
      () async {
        final cf = _Fake(
          ProviderId.cloudflare,
          script: [
            const GenException(
              GenErrorCode.contentFiltered,
              'no',
              provider: ProviderId.cloudflare,
            ),
            null,
          ],
        );
        final runner = BatchRunner(
          service: svc(
            ProviderMode.cloudflareOnly,
            cf,
            _Fake(ProviderId.pollinations),
          ),
          pollinationsCooldown: () => Duration.zero,
        );
        final slots = await runner.run(
          List.generate(2, (i) => GenRequest(prompt: 'p$i', seed: i)),
        );
        expect(slots.where((s) => s.failure != null).length, 1);
        expect(slots.where((s) => s.outcome != null).length, 1);

        final pol = _Fake(ProviderId.pollinations);
        final r2 = BatchRunner(
          service: svc(
            ProviderMode.pollinationsOnly,
            _Fake(ProviderId.cloudflare),
            pol,
          ),
          pollinationsCooldown: () => const Duration(seconds: 30),
          delay: (_) async {},
        );
        final s2 = await r2.run([
          const GenRequest(prompt: 'p', seed: 1),
        ], isCancelled: () => true);
        expect(s2.first.done, false);
        expect(pol.calls, 0);
      },
    );

    test('parallelFor / firstProvider', () {
      expect(BatchRunner.parallelFor(ProviderId.cloudflare), true);
      expect(BatchRunner.parallelFor(ProviderId.xai), true);
      expect(BatchRunner.parallelFor(ProviderId.pollinations), false);
      final cf = _Fake(ProviderId.cloudflare);
      final pol = _Fake(ProviderId.pollinations);
      expect(
        svc(ProviderMode.auto, cf, pol).firstProvider,
        ProviderId.cloudflare,
      );
      expect(
        svc(
          ProviderMode.auto,
          _Fake(ProviderId.cloudflare, configured: false),
          pol,
        ).firstProvider,
        ProviderId.pollinations,
      );
      final quota = GenerationService(
        mode: ProviderMode.auto,
        cloudflare: cf,
        pollinations: pol,
        cloudflareQuotaUntil: DateTime.now().add(const Duration(hours: 1)),
      );
      expect(quota.firstProvider, ProviderId.pollinations);
    });
  });

  group('History: favorites, search, sort', () {
    HistoryItem item(
      String id,
      String prompt,
      DateTime t, {
      bool fav = false,
      HistoryKind kind = HistoryKind.generate,
    }) => HistoryItem(
      id: id,
      prompt: '$prompt, cinematic',
      basePrompt: prompt,
      style: 'cinematic',
      aspect: ImageAspect.square,
      seed: 1,
      provider: ProviderId.cloudflare,
      model: 'm',
      createdAt: t,
      fileName: '$id.jpg',
      favorite: fav,
      kind: kind,
    );

    final a = item('a', 'A red fox in snow', DateTime(2026, 10, 1), fav: true);
    final b = item('b', 'Robot dog on Mars', DateTime(2026, 10, 3));
    final c = item(
      'c',
      'Fox robot',
      DateTime(2026, 10, 2),
      kind: HistoryKind.edit,
    );
    final all = [a, b, c];

    test('search is case-insensitive and matches all words', () {
      expect(queryHistory(all, text: 'FOX').map((e) => e.id), ['c', 'a']);
      expect(queryHistory(all, text: 'fox robot').map((e) => e.id), ['c']);
      expect(queryHistory(all, text: 'mars dog').map((e) => e.id), ['b']);
      expect(queryHistory(all, text: 'zebra'), isEmpty);
      expect(
        queryHistory(all, text: 'cinematic').length,
        3,
      ); // full prompt is searched too
    });

    test('favorites filter and date sort', () {
      expect(queryHistory(all, favoritesOnly: true).map((e) => e.id), ['a']);
      expect(queryHistory(all).map((e) => e.id), ['b', 'c', 'a']);
      expect(queryHistory(all, sort: HistorySort.oldest).map((e) => e.id), [
        'a',
        'c',
        'b',
      ]);
    });

    test(
      'JSON round trip keeps favorite/kind/parent/batch; old entries still load',
      () {
        final it = HistoryItem.fromJson(
          item(
            'z',
            'x',
            DateTime(2026, 1, 1),
            fav: true,
            kind: HistoryKind.upscale,
          ).copyWith().toJson(),
        );
        expect(it.favorite, true);
        expect(it.kind, HistoryKind.upscale);
        final old = HistoryItem.fromJson({
          'id': 'o',
          'fileName': 'o.jpg',
          'prompt': 'p',
        });
        expect(old.favorite, false);
        expect(old.kind, HistoryKind.generate);
      },
    );

    test(
      'store: add, favorite persists across reload, delete removes files',
      () async {
        final dir = await Directory.systemTemp.createTemp('hist');
        addTearDown(() => dir.delete(recursive: true));
        final s = HistoryStore(dir);
        await s.load();
        final i1 = await s.add(
          bytes: jpegBytes(8, 8),
          mime: 'image/jpeg',
          prompt: 'p',
          basePrompt: 'p',
          style: 'none',
          aspect: ImageAspect.square,
          seed: 1,
          provider: ProviderId.cloudflare,
          model: 'm',
          kind: HistoryKind.edit,
          sourceBytes: jpegBytes(4, 4),
          batchId: 'b1',
        );
        final i2 = await s.add(
          bytes: jpegBytes(8, 8),
          mime: 'image/jpeg',
          prompt: 'q',
          basePrompt: 'q',
          style: 'none',
          aspect: ImageAspect.square,
          seed: 1,
          provider: ProviderId.cloudflare,
          model: 'm',
        );
        expect(i1.id == i2.id, false); // same seed + same ms must not collide
        expect(s.sourceFileFor(i1), isNotNull);
        await s.setFavorite(i1, true);
        final s2 = HistoryStore(dir);
        await s2.load();
        expect(s2.byId(i1.id)!.favorite, true);
        expect(s2.byId(i1.id)!.batchId, 'b1');
        await s2.delete(i1);
        expect(File('${dir.path}/${i1.fileName}').existsSync(), false);
        expect(File('${dir.path}/${i1.sourceFileName}').existsSync(), false);
      },
    );
  });

  group('Backup / restore', () {
    test(
      'round trip: export -> wipe -> restore keeps files, prompts, favorites; merge skips duplicates',
      () async {
        final root = await Directory.systemTemp.createTemp('bk');
        addTearDown(() => root.delete(recursive: true));
        final d1 = Directory('${root.path}/a')..createSync();
        final s1 = HistoryStore(d1);
        await s1.load();
        final bytes1 = jpegBytes(16, 16, r: 10);
        final bytes2 = jpegBytes(16, 16, r: 240);
        final e = await s1.add(
          bytes: bytes1,
          mime: 'image/jpeg',
          prompt: 'full',
          basePrompt: 'fox',
          style: 'anime',
          aspect: ImageAspect.portrait,
          seed: 5,
          provider: ProviderId.pollinations,
          model: 'mm',
          kind: HistoryKind.edit,
          sourceBytes: jpegBytes(8, 8),
        );
        final g = await s1.add(
          bytes: bytes2,
          mime: 'image/png',
          prompt: 'p2',
          basePrompt: 'robot',
          style: 'none',
          aspect: ImageAspect.square,
          seed: 6,
          provider: ProviderId.cloudflare,
          model: 'm',
        );
        await s1.setFavorite(g, true);
        final zip = '${root.path}/backup.zip';
        final n = await HistoryBackup.export(
          items: s1.items,
          historyDir: d1,
          zipPath: zip,
          appVersion: '0.3.0',
        );
        expect(n, 2);
        expect(
          File(zip).lengthSync(),
          greaterThan(bytes1.length + bytes2.length),
        );

        final d2 = Directory('${root.path}/b')..createSync();
        final s2 = HistoryStore(d2);
        await s2.load();
        final found = await HistoryBackup.readInto(
          zipPath: zip,
          historyDir: d2,
        );
        expect(found.length, 2);
        expect(await s2.mergeRestored(found), 2);
        expect(await s2.mergeRestored(found), 0); // idempotent
        final re = s2.byId(e.id)!;
        expect(re.basePrompt, 'fox');
        expect(re.kind, HistoryKind.edit);
        expect(re.seed, 5);
        expect(s2.fileFor(re).readAsBytesSync(), bytes1);
        expect(s2.sourceFileFor(re), isNotNull);
        expect(s2.byId(g.id)!.favorite, true);
        expect(s2.fileFor(s2.byId(g.id)!).readAsBytesSync(), bytes2);

        // survives an app restart
        final s3 = HistoryStore(d2);
        await s3.load();
        expect(s3.items.length, 2);
      },
    );

    test('rejects foreign zips and ignores path-traversal names', () async {
      final root = await Directory.systemTemp.createTemp('bk2');
      addTearDown(() => root.delete(recursive: true));
      final hist = Directory('${root.path}/h')..createSync();
      // not a backup
      final enc = ZipFileEncoderShim.make('${root.path}/other.zip', {
        'readme.txt': utf8.encode('hi'),
      });
      await expectLater(
        HistoryBackup.readInto(zipPath: enc, historyDir: hist),
        throwsFormatException,
      );
      // evil manifest entry
      final evil = ZipFileEncoderShim.make('${root.path}/evil.zip', {
        'manifest.json': utf8.encode(
          jsonEncode({
            'app': 'imagine_pad',
            'format': 1,
            'items': [
              {'id': 'x', 'fileName': '../escape.jpg'},
              {'id': 'y', 'fileName': 'ok.jpg'},
            ],
          }),
        ),
        'images/../escape.jpg': [1, 2, 3],
        'images/ok.jpg': [4, 5, 6],
      });
      final items = await HistoryBackup.readInto(
        zipPath: evil,
        historyDir: hist,
      );
      expect(items.map((e) => e.id), ['y']);
      expect(File('${root.path}/escape.jpg').existsSync(), false);
      expect(File('${hist.path}/ok.jpg').existsSync(), true);
      final newer = ZipFileEncoderShim.make('${root.path}/new.zip', {
        'manifest.json': utf8.encode(
          jsonEncode({'app': 'imagine_pad', 'format': 99, 'items': []}),
        ),
      });
      await expectLater(
        HistoryBackup.readInto(zipPath: newer, historyDir: hist),
        throwsFormatException,
      );
    });

    test('suggested file name', () {
      expect(
        HistoryBackup.suggestedName(DateTime(2026, 10, 9, 7, 5)),
        'ImaginePad-backup-20261009-0705.zip',
      );
    });
  });

  group('ImageTools', () {
    test('prepareForEdit shrinks to <=512, keeps aspect, outputs JPEG', () {
      final out = ImageTools.prepareForEditSync(jpegBytes(2000, 1000));
      final d = img.decodeJpg(out)!;
      expect(d.width, 512);
      expect(d.height, 256);
      final small = ImageTools.prepareForEditSync(jpegBytes(300, 200));
      expect(img.decodeJpg(small)!.width, 300);
      expect(
        () => ImageTools.prepareForEditSync(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
    });

    test('PNG with transparency is flattened to JPEG', () {
      final im = img.Image(width: 20, height: 20, numChannels: 4);
      final png = Uint8List.fromList(img.encodePng(im));
      final out = ImageTools.prepareForEditSync(png);
      expect(out[0], 0xFF);
      expect(out[1], 0xD8);
    });

    test('upscale2x doubles dimensions, sharpens, and refuses huge images', () {
      final src = jpegBytes(120, 80);
      final out = ImageTools.upscale2xSync(src);
      final d = img.decodeJpg(out)!;
      expect((d.width, d.height), (240, 160));
      expect(ImageTools.sizeOf(out)!.width, 240);
      expect(
        () => ImageTools.upscale2xSync(jpegBytes(2100, 10)),
        throwsFormatException,
      );
    });

    test('unsharp mask raises local contrast and leaves flat areas alone', () {
      final orig = img.Image(width: 4, height: 1)
        ..clear(img.ColorRgb8(100, 100, 100));
      orig.setPixelRgb(2, 0, 140, 140, 140);
      final blur = img.Image(width: 4, height: 1)
        ..clear(img.ColorRgb8(110, 110, 110));
      final out = ImageTools.unsharp(orig, blur, amount: 1.0, threshold: 3);
      expect(out.getPixel(2, 0).r, greaterThan(140));
      expect(
        out.getPixel(0, 0).r,
        lessThan(100),
      ); // darker next to the bright pixel
      final flat = ImageTools.unsharp(orig, orig, amount: 1.0, threshold: 3);
      expect(flat.getPixel(0, 0).r, 100);
    });
  });
}

class ZipFileEncoderShim {
  static String make(String path, Map<String, List<int>> files) {
    // Use the archive package directly (tests only).
    final a = _zip(files);
    File(path).writeAsBytesSync(a);
    return path;
  }
}

List<int> _zip(Map<String, List<int>> files) {
  final a = Archive();
  files.forEach((name, data) => a.add(ArchiveFile.bytes(name, data)));
  return ZipEncoder().encode(a);
}

class _Fake implements ImageGenerator {
  @override
  final ProviderId id;
  final bool configured;
  final Duration latency;
  final List<GenException?> script;
  void Function()? onCall;
  int calls = 0;
  int _running = 0;
  int maxConcurrent = 0;
  _Fake(
    this.id, {
    this.configured = true,
    this.latency = Duration.zero,
    this.script = const [],
  });

  @override
  bool get isConfigured => configured;

  @override
  Future<GenImage> generate(GenRequest r) async {
    final step = script.isEmpty
        ? null
        : script[calls.clamp(0, script.length - 1)];
    calls++;
    _running++;
    if (_running > maxConcurrent) maxConcurrent = _running;
    try {
      if (latency > Duration.zero) await Future<void>.delayed(latency);
      onCall?.call();
      if (step != null) throw step;
      return GenImage(
        bytes: tinyJpeg,
        mime: 'image/jpeg',
        provider: id,
        model: 'm',
        seed: r.seed,
      );
    } finally {
      _running--;
    }
  }
}
