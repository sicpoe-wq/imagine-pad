import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:imagine_pad/core/gen_types.dart';
import 'package:imagine_pad/core/prompt_presets.dart';
import 'package:imagine_pad/providers/cloudflare_client.dart';
import 'package:imagine_pad/providers/generation_service.dart';
import 'package:imagine_pad/providers/paid_clients.dart';
import 'package:imagine_pad/providers/pollinations_client.dart';

final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 1, 2, 3]);
final png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
]);
const req = GenRequest(prompt: 'a red fox', seed: 7, steps: 4);

class FakeGen implements ImageGenerator {
  @override
  final ProviderId id;
  @override
  final bool isConfigured;
  final List<Object> script; // GenImage-producing marker or GenException
  int calls = 0;
  FakeGen(this.id, {this.isConfigured = true, this.script = const []});

  @override
  Future<GenImage> generate(GenRequest r) async {
    final step = script.isEmpty
        ? 'ok'
        : script[calls.clamp(0, script.length - 1)];
    calls++;
    if (step is GenException) throw step;
    return GenImage(
      bytes: jpeg,
      mime: 'image/jpeg',
      provider: id,
      model: 'm',
      seed: r.seed,
    );
  }
}

GenException err(ProviderId p, GenErrorCode c) =>
    GenException(c, 'x', provider: p);

void main() {
  setUp(PollinationsClient.resetLimiter);

  group('Pollinations URL building', () {
    test('encodes prompt as one path segment with size, seed, nologo', () {
      final u = PollinationsClient.buildUri(
        'cat & dog / 100% fun?',
        aspect: ImageAspect.square,
        seed: 42,
      );
      expect(
        u.toString(),
        startsWith(
          'https://image.pollinations.ai/prompt/cat%20%26%20dog%20%2F%20100%25%20fun%3F?',
        ),
      );
      expect(u.pathSegments.length, 2);
      expect(u.queryParameters, {
        'width': '768',
        'height': '768',
        'seed': '42',
        'nologo': 'true',
      });
    });

    test('sizes stay within the 768x768 area cap', () {
      for (final a in ImageAspect.values) {
        final (w, h) = PollinationsClient.sizeFor(a);
        expect(w * h, lessThanOrEqualTo(768 * 768));
      }
      expect(PollinationsClient.sizeFor(ImageAspect.portrait), (624, 936));
      expect(PollinationsClient.sizeFor(ImageAspect.landscape), (936, 624));
    });

    test('trims whitespace', () {
      final u = PollinationsClient.buildUri(
        '  hi  ',
        aspect: ImageAspect.square,
        seed: 1,
      );
      expect(u.path, '/prompt/hi');
    });
  });

  group('Pollinations client', () {
    test('returns image bytes on 200', () async {
      late Uri seen;
      final c = PollinationsClient(
        MockClient((r) async {
          seen = r.url;
          return http.Response.bytes(
            jpeg,
            200,
            headers: {'content-type': 'image/jpeg'},
          );
        }),
      );
      final img = await c.generate(req);
      expect(img.provider, ProviderId.pollinations);
      expect(img.bytes, jpeg);
      expect(seen.queryParameters['seed'], '7');
    });

    test(
      '402 maps to rateLimited with Retry-After, then local cooldown',
      () async {
        var now = DateTime(2026, 10, 19, 10);
        final c = PollinationsClient(
          MockClient(
            (_) async => http.Response(
              '{"error":"Queue full"}',
              402,
              headers: {'retry-after': '30'},
            ),
          ),
          now: () => now,
        );
        await expectLater(
          c.generate(req),
          throwsA(
            isA<GenException>()
                .having((e) => e.code, 'code', GenErrorCode.rateLimited)
                .having(
                  (e) => e.retryAfter,
                  'retryAfter',
                  const Duration(seconds: 45),
                ),
          ),
        );
        // Local 45 s gap dominates the 30 s Retry-After.
        now = now.add(const Duration(seconds: 40));
        expect(c.cooldownRemaining(), const Duration(seconds: 5));
        now = now.add(const Duration(seconds: 6));
        expect(c.cooldownRemaining(), Duration.zero);
      },
    );

    test(
      '503 is "at limit" too; 500 is server; 200 non-image is server',
      () async {
        for (final (status, body, code) in [
          (503, 'busy', GenErrorCode.rateLimited),
          (500, 'x', GenErrorCode.server),
          (200, '<html>', GenErrorCode.server),
          (400, 'bad', GenErrorCode.badRequest),
        ]) {
          PollinationsClient.resetLimiter();
          final c = PollinationsClient(
            MockClient((_) async => http.Response(body, status)),
          );
          await expectLater(
            c.generate(req),
            throwsA(isA<GenException>().having((e) => e.code, 'code', code)),
            reason: '$status',
          );
        }
      },
    );

    test(
      'second request within 45 s is refused locally without a network call',
      () async {
        var calls = 0;
        final c = PollinationsClient(
          MockClient((_) async {
            calls++;
            return http.Response.bytes(jpeg, 200);
          }),
        );
        await c.generate(req);
        await expectLater(
          c.generate(req),
          throwsA(
            isA<GenException>().having(
              (e) => e.code,
              'code',
              GenErrorCode.rateLimited,
            ),
          ),
        );
        expect(calls, 1);
      },
    );
  });

  group('Cloudflare worker client', () {
    CloudflareClient cf(
      MockClientHandler h, {
      String url = 'https://w.example.dev',
    }) =>
        CloudflareClient(MockClient(h), workerUrl: url, sharedSecret: 's3cret');

    test('URL normalisation', () {
      expect(CloudflareClient.normalizeBase(''), isNull);
      expect(
        CloudflareClient.normalizeBase('w.example.dev').toString(),
        'https://w.example.dev',
      );
      expect(
        CloudflareClient.normalizeBase(
          'https://w.example.dev/generate/',
        ).toString(),
        'https://w.example.dev',
      );
      final c = cf(
        (_) async => http.Response('', 200),
        url: 'https://w.example.dev/',
      );
      expect(c.generateUri.toString(), 'https://w.example.dev/generate');
      expect(c.healthUri.toString(), 'https://w.example.dev/health');
    });

    test('sends secret header + body and parses base64 JSON', () async {
      late http.Request seen;
      final c = cf((r) async {
        seen = r;
        return http.Response(
          jsonEncode({'image': base64Encode(jpeg), 'seed': 7, 'model': 'flux'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final img = await c.generate(req);
      expect(seen.headers['X-App-Secret'], 's3cret');
      expect(jsonDecode(seen.body), {
        'prompt': 'a red fox',
        'steps': 4,
        'seed': 7,
      });
      expect(img.bytes, jpeg);
      expect(img.provider, ProviderId.cloudflare);
      expect(img.model, 'flux');
    });

    test('parses data URI and raw image/jpeg responses', () async {
      final a = await cf(
        (_) async => http.Response(
          jsonEncode({'image': 'data:image/png;base64,${base64Encode(png)}'}),
          200,
        ),
      ).generate(req);
      expect(a.mime, 'image/png');
      final b = await cf(
        (_) async => http.Response.bytes(
          jpeg,
          200,
          headers: {'content-type': 'image/jpeg'},
        ),
      ).generate(req);
      expect(b.bytes, jpeg);
    });

    test('maps worker error codes', () async {
      final cases = {
        (429, 'quota'): GenErrorCode.quota,
        (429, 'rate_limited'): GenErrorCode.rateLimited,
        (401, 'unauthorized'): GenErrorCode.auth,
        (400, 'bad_request'): GenErrorCode.badRequest,
        (400, 'content_filtered'): GenErrorCode.contentFiltered,
        (504, 'upstream_timeout'): GenErrorCode.timeout,
        (502, 'upstream'): GenErrorCode.server,
        (503, ''): GenErrorCode.server,
        (404, ''): GenErrorCode.notConfigured,
      };
      for (final MapEntry(key: (status, code), value: expected)
          in cases.entries) {
        final c = cf(
          (_) async => http.Response(
            jsonEncode({
              'error': {'code': code, 'message': 'm', 'retryAfter': 5},
            }),
            status,
          ),
        );
        await expectLater(
          c.generate(req),
          throwsA(
            isA<GenException>()
                .having((e) => e.code, 'code', expected)
                .having((e) => e.httpStatus, 'status', status),
          ),
          reason: '$status $code',
        );
      }
    });

    test(
      'garbage 200 body is a server error; unconfigured throws notConfigured',
      () async {
        await expectLater(
          cf((_) async => http.Response('{"image":"!!"}', 200)).generate(req),
          throwsA(
            isA<GenException>().having(
              (e) => e.code,
              'code',
              GenErrorCode.server,
            ),
          ),
        );
        await expectLater(
          cf((_) async => http.Response('', 200), url: '').generate(req),
          throwsA(
            isA<GenException>().having(
              (e) => e.code,
              'code',
              GenErrorCode.notConfigured,
            ),
          ),
        );
      },
    );

    test('network failure maps to network', () async {
      await expectLater(
        cf((_) async => throw http.ClientException('down')).generate(req),
        throwsA(
          isA<GenException>().having(
            (e) => e.code,
            'code',
            GenErrorCode.network,
          ),
        ),
      );
    });
  });

  group('Provider selection and fallback', () {
    final now = DateTime.utc(2026, 10, 19, 14);

    test('auto: Cloudflare first when configured', () async {
      final cf = FakeGen(ProviderId.cloudflare);
      final po = FakeGen(ProviderId.pollinations);
      final out = await GenerationService(
        mode: ProviderMode.auto,
        cloudflare: cf,
        pollinations: po,
        now: () => now,
      ).generate(req);
      expect(out.image.provider, ProviderId.cloudflare);
      expect(out.usedFallback, isFalse);
      expect(out.image.note, isNull);
      expect(po.calls, 0);
    });

    test('auto: unconfigured Cloudflare is skipped', () async {
      final cf = FakeGen(ProviderId.cloudflare, isConfigured: false);
      final po = FakeGen(ProviderId.pollinations);
      final out = await GenerationService(
        mode: ProviderMode.auto,
        cloudflare: cf,
        pollinations: po,
        now: () => now,
      ).generate(req);
      expect(out.image.provider, ProviderId.pollinations);
      expect(cf.calls, 0);
      expect(out.attempts.single.skipped, isTrue);
      expect(out.image.note, contains('not set up'));
    });

    for (final code in [
      GenErrorCode.quota,
      GenErrorCode.server,
      GenErrorCode.timeout,
      GenErrorCode.network,
      GenErrorCode.rateLimited,
      GenErrorCode.auth,
    ]) {
      test(
        'auto: Cloudflare ${code.name} falls back to Pollinations',
        () async {
          final cf = FakeGen(
            ProviderId.cloudflare,
            script: [err(ProviderId.cloudflare, code)],
          );
          final po = FakeGen(ProviderId.pollinations);
          final out = await GenerationService(
            mode: ProviderMode.auto,
            cloudflare: cf,
            pollinations: po,
            now: () => now,
          ).generate(req);
          expect(out.image.provider, ProviderId.pollinations);
          expect(out.attempts.single.error!.code, code);
        },
      );
    }

    test('auto: content filter / bad request do NOT fall back', () async {
      for (final code in [
        GenErrorCode.contentFiltered,
        GenErrorCode.badRequest,
      ]) {
        final cf = FakeGen(
          ProviderId.cloudflare,
          script: [err(ProviderId.cloudflare, code)],
        );
        final po = FakeGen(ProviderId.pollinations);
        await expectLater(
          GenerationService(
            mode: ProviderMode.auto,
            cloudflare: cf,
            pollinations: po,
            now: () => now,
          ).generate(req),
          throwsA(isA<AllProvidersFailed>()),
        );
        expect(po.calls, 0);
      }
    });

    test(
      'quota hit is remembered until 00:00 UTC and Cloudflare skipped',
      () async {
        DateTime? saved;
        final cf = FakeGen(
          ProviderId.cloudflare,
          script: [err(ProviderId.cloudflare, GenErrorCode.quota), 'ok'],
        );
        final po = FakeGen(ProviderId.pollinations);
        final svc = GenerationService(
          mode: ProviderMode.auto,
          cloudflare: cf,
          pollinations: po,
          now: () => now,
          onCloudflareQuota: (d) => saved = d,
        );
        await svc.generate(req);
        expect(saved, DateTime.utc(2026, 10, 20));
        expect(svc.cloudflareQuotaHit, isTrue);
        final second = await svc.generate(req);
        expect(cf.calls, 1, reason: 'skipped while quota is hit');
        expect(second.image.note, contains('daily free limit'));

        // After reset, Cloudflare is tried again and the flag clears.
        final later = GenerationService(
          mode: ProviderMode.auto,
          cloudflare: cf,
          pollinations: po,
          cloudflareQuotaUntil: saved,
          now: () => DateTime.utc(2026, 10, 20, 0, 1),
          onCloudflareQuota: (d) => saved = d,
        );
        final third = await later.generate(req);
        expect(third.image.provider, ProviderId.cloudflare);
        expect(saved, isNull);
      },
    );

    test(
      'auto: both fail -> AllProvidersFailed with Pollinations error last',
      () async {
        final cf = FakeGen(
          ProviderId.cloudflare,
          script: [err(ProviderId.cloudflare, GenErrorCode.server)],
        );
        final po = FakeGen(
          ProviderId.pollinations,
          script: [err(ProviderId.pollinations, GenErrorCode.rateLimited)],
        );
        try {
          await GenerationService(
            mode: ProviderMode.auto,
            cloudflare: cf,
            pollinations: po,
            now: () => now,
          ).generate(req);
          fail('should throw');
        } on AllProvidersFailed catch (e) {
          expect(e.attempts.length, 2);
          expect(e.last.provider, ProviderId.pollinations);
          expect(e.last.code, GenErrorCode.rateLimited);
        }
      },
    );

    test('Cloudflare only: no fallback, even when unconfigured', () async {
      final cf = FakeGen(
        ProviderId.cloudflare,
        script: [err(ProviderId.cloudflare, GenErrorCode.notConfigured)],
      );
      final po = FakeGen(ProviderId.pollinations);
      await expectLater(
        GenerationService(
          mode: ProviderMode.cloudflareOnly,
          cloudflare: cf,
          pollinations: po,
          now: () => now,
        ).generate(req),
        throwsA(isA<AllProvidersFailed>()),
      );
      expect(po.calls, 0);
    });

    test('Pollinations only never calls Cloudflare', () async {
      final cf = FakeGen(ProviderId.cloudflare);
      final po = FakeGen(ProviderId.pollinations);
      final out = await GenerationService(
        mode: ProviderMode.pollinationsOnly,
        cloudflare: cf,
        pollinations: po,
        now: () => now,
      ).generate(req);
      expect(out.image.provider, ProviderId.pollinations);
      expect(cf.calls, 0);
    });

    test('paid mode uses the paid provider only', () async {
      final cf = FakeGen(ProviderId.cloudflare);
      final po = FakeGen(ProviderId.pollinations);
      final paid = FakeGen(ProviderId.xai);
      final out = await GenerationService(
        mode: ProviderMode.xai,
        cloudflare: cf,
        pollinations: po,
        paid: paid,
        now: () => now,
      ).generate(req);
      expect(out.image.provider, ProviderId.xai);
      expect(cf.calls + po.calls, 0);
    });

    test('nextUtcMidnight', () {
      expect(
        nextUtcMidnight(DateTime.utc(2026, 10, 19, 23, 59)),
        DateTime.utc(2026, 10, 20),
      );
      expect(
        nextUtcMidnight(DateTime.utc(2026, 12, 31, 1)),
        DateTime.utc(2027, 1, 1),
      );
    });
  });

  group('Paid clients (mocked)', () {
    test('xAI request shape and b64 parsing; key only in header', () async {
      late http.Request seen;
      final c = XaiClient(
        MockClient((r) async {
          seen = r;
          return http.Response(
            jsonEncode({
              'data': [
                {'b64_json': base64Encode(jpeg)},
              ],
            }),
            200,
          );
        }),
        'xai-KEY',
      );
      final img = await c.generate(
        const GenRequest(prompt: 'p', seed: 1, aspect: ImageAspect.portrait),
      );
      expect(seen.url.toString(), 'https://api.x.ai/v1/images/generations');
      expect(seen.url.toString(), isNot(contains('KEY')));
      expect(seen.headers['Authorization'], 'Bearer xai-KEY');
      final body = jsonDecode(seen.body);
      expect(body['model'], XaiClient.defaultModel);
      expect(body['aspect_ratio'], '2:3');
      expect(body['response_format'], 'b64_json');
      expect(img.provider, ProviderId.xai);
    });

    test('OpenAI sizes and quota mapping', () async {
      late Map body;
      final c = OpenAiClient(
        MockClient((r) async {
          body = jsonDecode(r.body);
          return http.Response(
            jsonEncode({
              'error': {
                'message': 'You exceeded your current quota',
                'code': 'insufficient_quota',
              },
            }),
            429,
          );
        }),
        'sk-x',
        model: 'gpt-image-2',
      );
      await expectLater(
        c.generate(
          const GenRequest(prompt: 'p', seed: 1, aspect: ImageAspect.landscape),
        ),
        throwsA(
          isA<GenException>().having((e) => e.code, 'code', GenErrorCode.quota),
        ),
      );
      expect(body['size'], '1536x1024');
      expect(body['model'], 'gpt-image-2');
    });

    test('Stability multipart + 403 moderation + no key', () async {
      final c = StabilityClient(
        MockClient((r) async {
          expect(r.headers['Accept'], 'image/*');
          return http.Response(
            jsonEncode({
              'name': 'content_moderation',
              'errors': ['flagged'],
            }),
            403,
          );
        }),
        'sk-st',
      );
      await expectLater(
        c.generate(req),
        throwsA(
          isA<GenException>().having(
            (e) => e.code,
            'code',
            GenErrorCode.contentFiltered,
          ),
        ),
      );
      await expectLater(
        StabilityClient(
          MockClient((_) async => http.Response('', 200)),
          '',
        ).generate(req),
        throwsA(
          isA<GenException>().having(
            (e) => e.code,
            'code',
            GenErrorCode.notConfigured,
          ),
        ),
      );
    });

    test('401 maps to auth', () {
      final e = mapPaidError(
        ProviderId.openai,
        http.Response('{"error":{"message":"bad key"}}', 401),
      );
      expect(e.code, GenErrorCode.auth);
      expect(e.message, 'bad key');
    });
  });

  group('Misc', () {
    test('composePrompt appends style', () {
      expect(composePrompt('a cat', presetById('none')), 'a cat');
      expect(
        composePrompt('a cat', presetById('pixel')),
        startsWith('a cat, pixel art'),
      );
      expect(
        composePrompt('a cat.', presetById('anime')),
        startsWith('a cat. anime'),
      );
    });
    test('sniffMime / Retry-After parsing', () {
      expect(sniffMime(jpeg), 'image/jpeg');
      expect(sniffMime(png), 'image/png');
      expect(looksLikeImage(utf8.encode('<html>')), isFalse);
      expect(parseRetryAfter('12'), const Duration(seconds: 12));
      expect(
        parseRetryAfter(
          'Mon, 19 Oct 2026 14:00:30 GMT',
          now: DateTime.utc(2026, 10, 19, 14),
        ),
        const Duration(seconds: 30),
      );
      expect(parseRetryAfter(null), isNull);
    });
  });
}
