import '../core/gen_types.dart';

/// Next Cloudflare Workers AI free-allocation reset: 00:00 UTC
/// (8 PM Eastern during daylight time, 7 PM in winter).
DateTime nextUtcMidnight(DateTime now) {
  final u = now.toUtc();
  return DateTime.utc(u.year, u.month, u.day).add(const Duration(days: 1));
}

/// One attempt that was skipped or failed before the final result.
class Attempt {
  final ProviderId provider;
  final GenException? error;
  final bool skipped;
  const Attempt(this.provider, {this.error, this.skipped = false});
}

class GenOutcome {
  final GenImage image;
  final List<Attempt> attempts;
  const GenOutcome(this.image, this.attempts);
  bool get usedFallback => attempts.isNotEmpty;
}

/// Thrown when every provider in the chain failed. [last] is the most
/// useful error to show (e.g. Pollinations rate limit with a countdown).
class AllProvidersFailed implements Exception {
  final List<Attempt> attempts;
  const AllProvidersFailed(this.attempts);
  GenException get last => attempts.lastWhere((a) => a.error != null).error!;
  @override
  String toString() =>
      'AllProvidersFailed(${attempts.map((a) => a.error).join(', ')})';
}

/// Picks providers for a mode and handles automatic fallback.
class GenerationService {
  final ProviderMode mode;
  final ImageGenerator cloudflare;
  final ImageGenerator pollinations;
  final ImageGenerator? paid;
  final DateTime Function() now;

  /// When Cloudflare said the daily free allocation is gone, until when.
  DateTime? cloudflareQuotaUntil;

  /// Called when the Cloudflare quota state changes, so it can be persisted.
  final void Function(DateTime? until)? onCloudflareQuota;

  GenerationService({
    required this.mode,
    required this.cloudflare,
    required this.pollinations,
    this.paid,
    this.cloudflareQuotaUntil,
    this.onCloudflareQuota,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  bool get cloudflareQuotaHit =>
      cloudflareQuotaUntil != null && now().isBefore(cloudflareQuotaUntil!);

  /// The provider a new request will actually start with (skips an
  /// unconfigured or out-of-quota Cloudflare in Auto mode).
  ProviderId? get firstProvider {
    final c = chain();
    for (var i = 0; i < c.length; i++) {
      final p = c[i];
      final isLast = i == c.length - 1;
      if (mode == ProviderMode.auto && !isLast) {
        if (!p.isConfigured) continue;
        if (p.id == ProviderId.cloudflare && cloudflareQuotaHit) continue;
      }
      return p.id;
    }
    return null;
  }

  /// Ordered list of providers to try for the current mode.
  List<ImageGenerator> chain() => switch (mode) {
    ProviderMode.auto => [cloudflare, pollinations],
    ProviderMode.cloudflareOnly => [cloudflare],
    ProviderMode.pollinationsOnly => [pollinations],
    ProviderMode.xai ||
    ProviderMode.openai ||
    ProviderMode.stability => [if (paid != null) paid!],
  };

  Future<GenOutcome> generate(
    GenRequest req, {
    void Function(ProviderId provider)? onTrying,
  }) async {
    final attempts = <Attempt>[];
    final providers = chain();
    if (providers.isEmpty) {
      throw AllProvidersFailed([
        Attempt(
          ProviderId.xai,
          error: const GenException(
            GenErrorCode.notConfigured,
            'No paid provider',
            provider: ProviderId.xai,
          ),
        ),
      ]);
    }
    final auto = mode == ProviderMode.auto;
    for (var i = 0; i < providers.length; i++) {
      final p = providers[i];
      final isLast = i == providers.length - 1;
      if (auto && !isLast) {
        if (!p.isConfigured) {
          attempts.add(
            Attempt(
              p.id,
              skipped: true,
              error: GenException(
                GenErrorCode.notConfigured,
                'Not set up',
                provider: p.id,
              ),
            ),
          );
          continue;
        }
        if (p.id == ProviderId.cloudflare && cloudflareQuotaHit) {
          attempts.add(
            Attempt(
              p.id,
              skipped: true,
              error: GenException(
                GenErrorCode.quota,
                'Daily free allocation used',
                provider: p.id,
              ),
            ),
          );
          continue;
        }
      }
      try {
        onTrying?.call(p.id);
        final img = await p.generate(req);
        if (p.id == ProviderId.cloudflare && cloudflareQuotaUntil != null) {
          cloudflareQuotaUntil = null;
          onCloudflareQuota?.call(null);
        }
        return GenOutcome(img.withNote(_note(attempts)), attempts);
      } on GenException catch (e) {
        if (p.id == ProviderId.cloudflare && e.code == GenErrorCode.quota) {
          cloudflareQuotaUntil = nextUtcMidnight(now());
          onCloudflareQuota?.call(cloudflareQuotaUntil);
        }
        attempts.add(Attempt(p.id, error: e));
        if (!auto || isLast || !e.shouldFallBack) {
          throw AllProvidersFailed(attempts);
        }
      }
    }
    throw AllProvidersFailed(attempts);
  }

  static String? _note(List<Attempt> attempts) {
    if (attempts.isEmpty) return null;
    final a = attempts.last;
    final why = switch (a.error?.code) {
      GenErrorCode.notConfigured => 'not set up',
      GenErrorCode.quota => 'daily free limit reached',
      GenErrorCode.timeout => 'timed out',
      GenErrorCode.rateLimited => 'busy',
      GenErrorCode.server => 'server error',
      GenErrorCode.network => 'unreachable',
      GenErrorCode.auth => 'secret rejected',
      _ => 'failed',
    };
    return 'Used backup: ${a.provider.shortLabel} $why';
  }
}
