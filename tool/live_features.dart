// Live proof for v0.3.0 features through the app's own Dart code.
// Run: WORKER_URL=... APP_SHARED_SECRET=... dart run tool/live_features.dart [outDir]
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:imagine_pad/core/gen_types.dart';
import 'package:imagine_pad/core/usage.dart';
import 'package:imagine_pad/providers/batch_runner.dart';
import 'package:imagine_pad/providers/cloudflare_client.dart';
import 'package:imagine_pad/providers/generation_service.dart';
import 'package:imagine_pad/providers/pollinations_client.dart';
import 'package:imagine_pad/services/image_tools.dart';

Future<void> main(List<String> args) async {
  final out = args.isNotEmpty ? args.first : '/workspace/image_tests';
  await Directory(out).create(recursive: true);
  final http.Client c = http.Client();
  UsageInfo? last;
  final cf = CloudflareClient(c,
      workerUrl: Platform.environment['WORKER_URL'] ?? '',
      sharedSecret: Platform.environment['APP_SHARED_SECRET'] ?? '',
      onUsage: (u) => last = u);

  // 1. Prompt enhancer
  var sw = Stopwatch()..start();
  final enh = await cf.enhance('robot dog');
  stdout.writeln('ENHANCE ${sw.elapsedMilliseconds} ms\n  before: ${enh.original}\n  after:  ${enh.prompt}');

  // 2. Batch of 4 on Cloudflare (parallel)
  final svc = GenerationService(mode: ProviderMode.auto, cloudflare: cf, pollinations: PollinationsClient(c));
  final reqs = List.generate(4, (i) => GenRequest(prompt: enh.prompt, seed: i));
  sw = Stopwatch()..start();
  final slots = await BatchRunner(service: svc, pollinationsCooldown: () => Duration.zero).run(reqs);
  final ms = sw.elapsedMilliseconds;
  for (final s in slots) {
    if (s.outcome != null) {
      await File('$out/batch_${s.index + 1}.jpg').writeAsBytes(s.outcome!.image.bytes);
    }
  }
  stdout.writeln('BATCH 4 in $ms ms (parallel=${BatchRunner.parallelFor(svc.firstProvider)}): '
      '${slots.map((s) => s.outcome?.image.provider.shortLabel ?? 'FAILED ${s.failure?.last}').join(', ')}');

  // 3. Edit: batch_1 -> prepare (<=512) -> /edit
  final src = await File('$out/batch_1.jpg').readAsBytes();
  final prepared = await ImageTools.prepareForEdit(src);
  await File('$out/edit_before.jpg').writeAsBytes(prepared);
  sw = Stopwatch()..start();
  final edited = await cf.edit(EditRequest(
      prompt: 'Turn it into a snowy winter night with northern lights', image: prepared, strength: 0.5));
  await File('$out/edit_after.jpg').writeAsBytes(edited.bytes);
  stdout.writeln('EDIT ${sw.elapsedMilliseconds} ms: in ${ImageTools.sizeOf(prepared)} -> out ${ImageTools.sizeOf(edited.bytes)}, ${edited.model}');

  // 4. Basic upscale 2x of batch_2 (on-device code path)
  final up = await File('$out/batch_2.jpg').readAsBytes();
  sw = Stopwatch()..start();
  final big = await ImageTools.upscale2x(up);
  await File('$out/upscale_before.jpg').writeAsBytes(up);
  await File('$out/upscale_2x.jpg').writeAsBytes(big);
  stdout.writeln('UPSCALE ${sw.elapsedMilliseconds} ms (box CPU): ${ImageTools.sizeOf(up)} -> ${ImageTools.sizeOf(big)}');

  // 5. Usage counter
  final u = await cf.fetchUsage() ?? last;
  stdout.writeln('USAGE day=${u?.day} images=${u?.images} generate=${u?.generate} edit=${u?.edit} '
      'enhance=${u?.enhance} neurons~${u?.neurons} resets=${u?.resetsAt.toLocal()} left~${u?.imagesLeftEstimate}');
  c.close();
}
