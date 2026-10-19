import 'dart:async';

import '../core/gen_types.dart';
import 'generation_service.dart';

/// Result slot for one image in a batch.
class BatchSlot {
  final int index;
  GenOutcome? outcome;
  AllProvidersFailed? failure;
  bool running = false;
  BatchSlot(this.index);
  bool get done => outcome != null || failure != null;
}

/// Runs 1–4 image requests.
///  * Cloudflare / paid first: all requests at once (parallel).
///  * Pollinations first: one at a time, waiting out its 45 s gap.
/// Any parallel request that fell back to Pollinations and hit its one-at-a-time
/// limit is retried afterwards in the sequential lane.
class BatchRunner {
  final GenerationService service;
  final Duration Function() pollinationsCooldown;
  final Future<void> Function(Duration) delay;

  /// Longest single wait we accept before giving up on a Pollinations slot.
  final Duration maxWait;
  final int maxRetriesPerSlot;

  BatchRunner({
    required this.service,
    required this.pollinationsCooldown,
    Future<void> Function(Duration)? delay,
    this.maxWait = const Duration(minutes: 3),
    this.maxRetriesPerSlot = 2,
  }) : delay = delay ?? Future<void>.delayed;

  static bool parallelFor(ProviderId? first) =>
      first != null && first != ProviderId.pollinations;

  Future<List<BatchSlot>> run(
    List<GenRequest> reqs, {
    void Function(BatchSlot slot)? onUpdate,
    void Function(Duration wait, int index)? onWaiting,
    bool Function()? isCancelled,
  }) async {
    final slots = [for (var i = 0; i < reqs.length; i++) BatchSlot(i)];
    bool cancelled() => isCancelled?.call() ?? false;

    Future<void> attempt(int i) async {
      final s = slots[i];
      s.running = true;
      s.failure = null;
      onUpdate?.call(s);
      try {
        s.outcome = await service.generate(reqs[i]);
      } on AllProvidersFailed catch (e) {
        s.failure = e;
      } finally {
        s.running = false;
        onUpdate?.call(s);
      }
    }

    final sequential = <int>[];
    if (parallelFor(service.firstProvider)) {
      await Future.wait([for (var i = 0; i < reqs.length; i++) attempt(i)]);
      for (final s in slots) {
        final last = s.failure?.last;
        if (last != null &&
            last.provider == ProviderId.pollinations &&
            last.code == GenErrorCode.rateLimited) {
          sequential.add(s.index);
        }
      }
    } else {
      sequential.addAll(List.generate(reqs.length, (i) => i));
    }

    for (final i in sequential) {
      var tries = 0;
      while (!cancelled()) {
        final wait = pollinationsCooldown();
        if (wait > Duration.zero) {
          if (wait > maxWait) break;
          onWaiting?.call(wait, i);
          await delay(wait);
          if (cancelled()) break;
        }
        await attempt(i);
        final last = slots[i].failure?.last;
        final retryable =
            last != null &&
            last.code == GenErrorCode.rateLimited &&
            (last.retryAfter ?? Duration.zero) <= maxWait;
        if (!retryable || tries >= maxRetriesPerSlot) break;
        tries++;
        final ra = last.retryAfter ?? const Duration(seconds: 45);
        final cd = pollinationsCooldown();
        if (cd < ra) {
          onWaiting?.call(ra, i);
          await delay(ra);
        }
      }
    }
    return slots;
  }
}
