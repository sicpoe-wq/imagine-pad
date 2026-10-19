/// Today's Cloudflare free-allowance usage, as counted by the Worker
/// (shared by every phone using it) or, if the Worker can't say, by this app.
class UsageInfo {
  static const freeNeurons = 10000;

  /// Estimated neurons for one FLUX.1 schnell 1024x1024 image at 4 steps
  /// (4 tiles x 4.8 + 4 steps x 9.6, Cloudflare pricing page).
  static const neuronsPerImage = 57.6;

  final String day; // UTC yyyy-mm-dd
  final int images;
  final int generate;
  final int edit;
  final int enhance;
  final int? neurons; // null when only counted locally
  final bool neuronsEstimated;
  final DateTime resetsAt; // UTC
  final bool fromWorker;

  const UsageInfo({
    required this.day,
    required this.images,
    this.generate = 0,
    this.edit = 0,
    this.enhance = 0,
    this.neurons,
    this.neuronsEstimated = true,
    required this.resetsAt,
    required this.fromWorker,
  });

  static String utcDay(DateTime now) =>
      now.toUtc().toIso8601String().substring(0, 10);

  static DateTime nextReset(DateTime now) {
    final u = now.toUtc();
    return DateTime.utc(u.year, u.month, u.day).add(const Duration(days: 1));
  }

  /// Parse the Worker's `usage` object (from /usage or any image response).
  static UsageInfo? fromWorkerJson(Object? j) {
    if (j is! Map) return null;
    if (j['available'] == false) return null;
    final day = j['day'];
    if (day is! String) return null;
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return UsageInfo(
      day: day,
      images: n('images'),
      generate: n('generate'),
      edit: n('edit'),
      enhance: n('enhance'),
      neurons: (j['neurons'] as num?)?.round(),
      neuronsEstimated: j['neuronsEstimated'] != false,
      resetsAt:
          DateTime.tryParse(j['resetsAt'] as String? ?? '')?.toUtc() ??
          nextReset(DateTime.parse('${day}T12:00:00Z')),
      fromWorker: true,
    );
  }

  factory UsageInfo.local(int images, DateTime now) => UsageInfo(
    day: utcDay(now),
    images: images,
    generate: images,
    resetsAt: nextReset(now),
    fromWorker: false,
  );

  /// A record from a previous UTC day is stale: show zero for today.
  UsageInfo current(DateTime now) {
    if (day == utcDay(now)) return this;
    return UsageInfo(
      day: utcDay(now),
      images: 0,
      neurons: fromWorker ? 0 : null,
      resetsAt: nextReset(now),
      fromWorker: fromWorker,
    );
  }

  /// Neurons used, estimated from the image count when the Worker didn't say.
  double get neuronsOrEstimate =>
      neurons?.toDouble() ?? images * neuronsPerImage;

  /// Rough number of standard images left today.
  int get imagesLeftEstimate =>
      ((freeNeurons - neuronsOrEstimate) / neuronsPerImage).floor().clamp(
        0,
        9999,
      );

  double get fractionUsed => (neuronsOrEstimate / freeNeurons).clamp(0.0, 1.0);
}
