// Live proof: generates one image through the app's own PollinationsClient.
// Run: dart run tool/live_pollinations.dart [out.jpg]
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:imagine_pad/core/gen_types.dart';
import 'package:imagine_pad/core/prompt_presets.dart';
import 'package:imagine_pad/providers/generation_service.dart';
import 'package:imagine_pad/providers/cloudflare_client.dart';
import 'package:imagine_pad/providers/pollinations_client.dart';

Future<void> main(List<String> args) async {
  final out = args.isNotEmpty ? args.first : '/workspace/image_tests/imagine_pad_pollinations.jpg';
  final client = http.Client();
  // Auto mode with Cloudflare unconfigured => exercises the real fallback path.
  final svc = GenerationService(
    mode: ProviderMode.auto,
    cloudflare: CloudflareClient(client, workerUrl: '', sharedSecret: ''),
    pollinations: PollinationsClient(client),
  );
  final req = GenRequest(
    prompt: composePrompt('A Starship rocket lifting off at sunset over the Texas coast',
        presetById('cinematic')),
    aspect: ImageAspect.landscape,
    seed: DateTime.now().millisecondsSinceEpoch % 100000,
  );
  for (var attempt = 1; attempt <= 5; attempt++) {
    final sw = Stopwatch()..start();
    try {
      final r = await svc.generate(req);
      await File(out).create(recursive: true);
      await File(out).writeAsBytes(r.image.bytes);
      stdout.writeln('OK attempt $attempt in ${sw.elapsedMilliseconds} ms: '
          '${r.image.provider.label}, ${r.image.mime}, ${r.image.bytes.length} bytes, '
          'seed ${r.image.seed}, note: ${r.image.note}');
      stdout.writeln('Saved $out');
      client.close();
      return;
    } on AllProvidersFailed catch (e) {
      final last = e.last;
      final wait = (last.retryAfter ?? const Duration(seconds: 45)) + const Duration(seconds: 2);
      stdout.writeln('Attempt $attempt failed after ${sw.elapsedMilliseconds} ms: '
          '${last.code.name} (${last.httpStatus}) ${last.message}; waiting ${wait.inSeconds}s');
      await Future.delayed(wait);
    }
  }
  client.close();
  exitCode = 1;
}
