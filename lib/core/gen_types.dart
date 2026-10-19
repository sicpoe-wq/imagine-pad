import 'dart:typed_data';

/// Which backend produced (or should produce) an image.
enum ProviderId { cloudflare, pollinations, xai, openai, stability }

extension ProviderIdInfo on ProviderId {
  String get label => switch (this) {
    ProviderId.cloudflare => 'Cloudflare FLUX',
    ProviderId.pollinations => 'Pollinations',
    ProviderId.xai => 'xAI Grok Imagine',
    ProviderId.openai => 'OpenAI',
    ProviderId.stability => 'Stability AI',
  };

  String get shortLabel => switch (this) {
    ProviderId.cloudflare => 'Cloudflare',
    ProviderId.pollinations => 'Pollinations',
    ProviderId.xai => 'xAI',
    ProviderId.openai => 'OpenAI',
    ProviderId.stability => 'Stability',
  };

  bool get isPaid =>
      this == ProviderId.xai ||
      this == ProviderId.openai ||
      this == ProviderId.stability;

  static ProviderId parse(String? s) => ProviderId.values.firstWhere(
    (p) => p.name == s,
    orElse: () => ProviderId.pollinations,
  );
}

/// How the app picks a provider.
enum ProviderMode {
  auto,
  cloudflareOnly,
  pollinationsOnly,
  xai,
  openai,
  stability,
}

extension ProviderModeInfo on ProviderMode {
  String get label => switch (this) {
    ProviderMode.auto => 'Auto (Cloudflare, then Pollinations)',
    ProviderMode.cloudflareOnly => 'Cloudflare only',
    ProviderMode.pollinationsOnly => 'Pollinations only',
    ProviderMode.xai => 'xAI Grok Imagine (paid, your key)',
    ProviderMode.openai => 'OpenAI (paid, your key)',
    ProviderMode.stability => 'Stability AI (paid, your key)',
  };

  String get chipLabel => switch (this) {
    ProviderMode.auto => 'Auto',
    ProviderMode.cloudflareOnly => 'Cloudflare',
    ProviderMode.pollinationsOnly => 'Pollinations',
    ProviderMode.xai => 'xAI',
    ProviderMode.openai => 'OpenAI',
    ProviderMode.stability => 'Stability',
  };

  static ProviderMode parse(String? s) => ProviderMode.values.firstWhere(
    (m) => m.name == s,
    orElse: () => ProviderMode.auto,
  );
}

enum ImageAspect { square, portrait, landscape }

extension AspectInfo on ImageAspect {
  String get label => switch (this) {
    ImageAspect.square => 'Square',
    ImageAspect.portrait => 'Portrait',
    ImageAspect.landscape => 'Landscape',
  };

  /// Ratio string used by xAI / Stability.
  String get ratio => switch (this) {
    ImageAspect.square => '1:1',
    ImageAspect.portrait => '2:3',
    ImageAspect.landscape => '3:2',
  };

  double get value => switch (this) {
    ImageAspect.square => 1,
    ImageAspect.portrait => 2 / 3,
    ImageAspect.landscape => 3 / 2,
  };

  static ImageAspect parse(String? s) => ImageAspect.values.firstWhere(
    (a) => a.name == s,
    orElse: () => ImageAspect.square,
  );
}

class GenRequest {
  /// Final prompt sent to the provider (style already appended).
  final String prompt;
  final ImageAspect aspect;
  final int seed;
  final int steps;

  const GenRequest({
    required this.prompt,
    this.aspect = ImageAspect.square,
    required this.seed,
    this.steps = 4,
  });

  GenRequest copyWith({int? seed}) => GenRequest(
    prompt: prompt,
    aspect: aspect,
    seed: seed ?? this.seed,
    steps: steps,
  );
}

class GenImage {
  final Uint8List bytes;
  final String mime;
  final ProviderId provider;
  final String model;
  final int seed;

  /// Human-readable note, e.g. why a fallback happened.
  final String? note;

  const GenImage({
    required this.bytes,
    required this.mime,
    required this.provider,
    required this.model,
    required this.seed,
    this.note,
  });

  GenImage withNote(String? n) => GenImage(
    bytes: bytes,
    mime: mime,
    provider: provider,
    model: model,
    seed: seed,
    note: n,
  );
}

enum GenErrorCode {
  notConfigured,
  quota,
  rateLimited,
  server,
  timeout,
  network,
  auth,
  badRequest,
  contentFiltered,
  unknown,
}

class GenException implements Exception {
  final GenErrorCode code;
  final String message;
  final ProviderId provider;
  final Duration? retryAfter;
  final int? httpStatus;

  const GenException(
    this.code,
    this.message, {
    required this.provider,
    this.retryAfter,
    this.httpStatus,
  });

  /// Errors after which Auto mode should try the next provider.
  bool get shouldFallBack => switch (code) {
    GenErrorCode.notConfigured ||
    GenErrorCode.quota ||
    GenErrorCode.rateLimited ||
    GenErrorCode.server ||
    GenErrorCode.timeout ||
    GenErrorCode.network ||
    GenErrorCode.auth ||
    GenErrorCode.unknown => true,
    GenErrorCode.badRequest || GenErrorCode.contentFiltered => false,
  };

  String get friendly => switch (code) {
    GenErrorCode.notConfigured => '${provider.shortLabel} is not set up yet.',
    GenErrorCode.quota =>
      '${provider.shortLabel} has used up today\'s free images.',
    GenErrorCode.rateLimited =>
      retryAfter != null
          ? '${provider.shortLabel} is busy. Next free slot in ${retryAfter!.inSeconds}s.'
          : '${provider.shortLabel} is busy right now.',
    GenErrorCode.server => '${provider.shortLabel} had a server problem.',
    GenErrorCode.timeout => '${provider.shortLabel} took too long to answer.',
    GenErrorCode.network =>
      'Couldn\'t reach ${provider.shortLabel}. Check your connection.',
    GenErrorCode.auth => '${provider.shortLabel} rejected the key or secret.',
    GenErrorCode.badRequest => message,
    GenErrorCode.contentFiltered =>
      '${provider.shortLabel} refused this prompt (safety filter).',
    GenErrorCode.unknown => '${provider.shortLabel}: $message',
  };

  @override
  String toString() => 'GenException(${provider.name}, ${code.name}, $message)';
}

abstract class ImageGenerator {
  ProviderId get id;
  bool get isConfigured;
  Future<GenImage> generate(GenRequest req);
}

/// Sniff the image type from magic bytes.
String sniffMime(List<int> b, {String fallback = 'image/jpeg'}) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  return fallback;
}

bool looksLikeImage(List<int> b) => sniffMime(b, fallback: '') != '';

String extForMime(String mime) => switch (mime) {
  'image/png' => 'png',
  'image/webp' => 'webp',
  _ => 'jpg',
};

/// Parse a Retry-After header (seconds or HTTP date).
Duration? parseRetryAfter(String? v, {DateTime? now}) {
  if (v == null || v.trim().isEmpty) return null;
  final secs = int.tryParse(v.trim());
  if (secs != null) return Duration(seconds: secs.clamp(0, 3600));
  try {
    final d = HttpDateLite.parse(v.trim());
    final diff = d.difference((now ?? DateTime.now()).toUtc());
    return diff.isNegative ? Duration.zero : diff;
  } catch (_) {
    return null;
  }
}

/// Minimal RFC 1123 date parser (avoids dart:io so this file stays portable).
class HttpDateLite {
  static const _months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };
  static DateTime parse(String s) {
    final m = RegExp(
      r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(s);
    if (m == null) throw FormatException('bad date', s);
    return DateTime.utc(
      int.parse(m[3]!),
      _months[m[2]!]!,
      int.parse(m[1]!),
      int.parse(m[4]!),
      int.parse(m[5]!),
      int.parse(m[6]!),
    );
  }
}
