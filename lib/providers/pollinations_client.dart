import 'dart:async';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../core/gen_types.dart';

/// Pollinations "Classic" keyless image API.
/// Docs: https://github.com/pollinations/pollinations/blob/master/APIDOCS.md
/// Free, anonymous, one image at a time per IP, at least 45 s apart.
/// Over the limit it answers 402 with a Retry-After header.
class PollinationsClient implements ImageGenerator {
  static const base = 'https://image.pollinations.ai/prompt/';
  static const minGap = Duration(seconds: 45);

  final http.Client _http;
  final Duration timeout;
  final DateTime Function() _now;

  /// Shared across instances: the limit is per device IP, not per object.
  static DateTime? lastRequestAt;
  static DateTime? blockedUntil;

  PollinationsClient(this._http,
      {this.timeout = const Duration(seconds: 120), DateTime Function()? now})
      : _now = now ?? DateTime.now;

  @override
  ProviderId get id => ProviderId.pollinations;

  @override
  bool get isConfigured => true;

  /// Pixel size for an aspect, kept within the documented 768×768 area cap.
  static (int, int) sizeFor(ImageAspect a) => switch (a) {
        ImageAspect.square => (768, 768),
        ImageAspect.portrait => (624, 936),
        ImageAspect.landscape => (936, 624),
      };

  static Uri buildUri(String prompt, {required ImageAspect aspect, required int seed}) {
    final (w, h) = sizeFor(aspect);
    // Encode the prompt as one path segment (spaces -> %20, '/' escaped).
    final encoded = Uri.encodeComponent(prompt.trim());
    return Uri.parse('$base$encoded').replace(queryParameters: {
      'width': '$w',
      'height': '$h',
      'seed': '$seed',
      'nologo': 'true',
    });
  }

  /// Time left before another anonymous request is allowed (client-side).
  Duration cooldownRemaining() {
    final now = _now();
    Duration left = Duration.zero;
    if (lastRequestAt != null) {
      final d = lastRequestAt!.add(minGap).difference(now);
      if (d > left) left = d;
    }
    if (blockedUntil != null) {
      final d = blockedUntil!.difference(now);
      if (d > left) left = d;
    }
    return left;
  }

  static void resetLimiter() {
    lastRequestAt = null;
    blockedUntil = null;
  }

  @override
  Future<GenImage> generate(GenRequest req) async {
    final wait = cooldownRemaining();
    if (wait > Duration.zero) {
      throw GenException(GenErrorCode.rateLimited,
          'Pollinations allows one free image every 45 seconds.',
          provider: id, retryAfter: _roundUp(wait));
    }
    final uri = buildUri(req.prompt, aspect: req.aspect, seed: req.seed);
    lastRequestAt = _now();
    http.Response res;
    try {
      res = await _http.get(uri, headers: {'Accept': 'image/*'}).timeout(timeout);
    } on TimeoutException {
      throw GenException(GenErrorCode.timeout, 'No answer in ${timeout.inSeconds}s',
          provider: id);
    } on SocketException catch (e) {
      throw GenException(GenErrorCode.network, e.message, provider: id);
    } on http.ClientException catch (e) {
      throw GenException(GenErrorCode.network, e.message, provider: id);
    }
    // The gap is measured from when the previous one finished.
    lastRequestAt = _now();
    return parseResponse(res, req);
  }

  GenImage parseResponse(http.Response res, GenRequest req) {
    final s = res.statusCode;
    if (s == 200 && looksLikeImage(res.bodyBytes)) {
      return GenImage(
        bytes: res.bodyBytes,
        mime: sniffMime(res.bodyBytes),
        provider: id,
        model: 'Pollinations Classic (flux)',
        seed: req.seed,
      );
    }
    if (s == 402 || s == 429 || s == 503) {
      final ra = parseRetryAfter(res.headers['retry-after']) ?? minGap;
      blockedUntil = _now().add(ra);
      // Report the real wait: the longer of Retry-After and our 45 s gap.
      final wait = cooldownRemaining();
      throw GenException(GenErrorCode.rateLimited,
          'Pollinations free tier is at its limit.',
          provider: id, retryAfter: _roundUp(wait > ra ? wait : ra), httpStatus: s);
    }
    if (s == 400) {
      throw GenException(GenErrorCode.badRequest, 'Pollinations rejected the prompt.',
          provider: id, httpStatus: s);
    }
    if (s == 403 || s == 451) {
      throw GenException(GenErrorCode.contentFiltered, 'Blocked by safety filter',
          provider: id, httpStatus: s);
    }
    if (s >= 500) {
      throw GenException(GenErrorCode.server, 'HTTP $s', provider: id, httpStatus: s);
    }
    if (s == 200) {
      throw GenException(GenErrorCode.server, 'Pollinations returned no image',
          provider: id, httpStatus: s);
    }
    throw GenException(GenErrorCode.unknown, 'HTTP $s', provider: id, httpStatus: s);
  }

  static Duration _roundUp(Duration d) =>
      Duration(seconds: (d.inMilliseconds / 1000).ceil());
}
