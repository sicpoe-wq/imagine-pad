// Live proof: Auto mode through the app's GenerationService with the Worker configured.
// Run: WORKER_URL=... APP_SHARED_SECRET=... dart run tool/live_cloudflare.dart [out.jpg]
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:imagine_pad/core/gen_types.dart';
import 'package:imagine_pad/core/prompt_presets.dart';
import 'package:imagine_pad/providers/generation_service.dart';
import 'package:imagine_pad/providers/cloudflare_client.dart';
import 'package:imagine_pad/providers/pollinations_client.dart';

Future<void> main(List<String> args) async {
  final out = args.isNotEmpty ? args.first : '/workspace/image_tests/imagine_pad_cf_auto.jpg';
  final url = Platform.environment['WORKER_URL'] ?? '';
  final secret = Platform.environment['APP_SHARED_SECRET'] ?? '';
  final client = http.Client();
  final svc = GenerationService(
    mode: ProviderMode.auto,
    cloudflare: CloudflareClient(client, workerUrl: url, sharedSecret: secret),
    pollinations: PollinationsClient(client),
  );
  final req = GenRequest(
    prompt: composePrompt('A humanoid robot watching a Starship launch at sunset',
        presetById('cinematic')),
    aspect: ImageAspect.square,
    seed: DateTime.now().millisecondsSinceEpoch % 100000,
  );
  final sw = Stopwatch()..start();
  final r = await svc.generate(req);
  await File(out).create(recursive: true);
  await File(out).writeAsBytes(r.image.bytes);
  stdout.writeln('OK in ${sw.elapsedMilliseconds} ms: provider=${r.image.provider.label}, '
      '${r.image.mime}, ${r.image.bytes.length} bytes, note: ${r.image.note}');
  client.close();
}
