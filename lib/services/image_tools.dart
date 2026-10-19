import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// On-device image helpers (pure Dart, run off the UI thread).
class ImageTools {
  /// FLUX.2 klein on Workers AI needs reference images no larger than 512x512.
  static const editMaxSide = 512;

  /// Largest input the basic upscaler accepts (output is 2x this).
  static const upscaleMaxSide = 2048;

  /// Decode, fix EXIF rotation, shrink so the long side is <= [maxSide], JPEG-encode.
  static Future<Uint8List> prepareForEdit(
    Uint8List bytes, {
    int maxSide = editMaxSide,
  }) => Isolate.run(() => prepareForEditSync(bytes, maxSide: maxSide));

  static Uint8List prepareForEditSync(
    Uint8List bytes, {
    int maxSide = editMaxSide,
  }) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('Could not read that image.');
    }
    var im = img.bakeOrientation(decoded);
    if (im.width > maxSide || im.height > maxSide) {
      final s = maxSide / math.max(im.width, im.height);
      im = img.copyResize(
        im,
        width: math.max(1, (im.width * s).floor()),
        height: math.max(1, (im.height * s).floor()),
        interpolation: img.Interpolation.average,
      );
    }
    if (im.hasAlpha || im.numChannels == 4) {
      // JPEG has no alpha: flatten on white.
      final bg = img.Image(width: im.width, height: im.height)
        ..clear(img.ColorRgb8(255, 255, 255));
      im = img.compositeImage(bg, im);
    }
    return Uint8List.fromList(img.encodeJpg(im, quality: 90));
  }

  static ({int width, int height})? sizeOf(Uint8List bytes) {
    final d = img.findDecoderForData(bytes);
    final info = d?.startDecode(bytes);
    if (info == null) return null;
    return (width: info.width, height: info.height);
  }

  /// "Basic upscale": 2x bicubic resize followed by an unsharp mask.
  /// This is NOT AI super-resolution; it makes images bigger and crisper but
  /// cannot invent real new detail.
  static Future<Uint8List> upscale2x(
    Uint8List bytes, {
    double amount = 0.6,
    int threshold = 3,
  }) => Isolate.run(
    () => upscale2xSync(bytes, amount: amount, threshold: threshold),
  );

  static Uint8List upscale2xSync(
    Uint8List bytes, {
    double amount = 0.6,
    int threshold = 3,
  }) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('Could not read that image.');
    }
    final src = img.bakeOrientation(decoded);
    if (math.max(src.width, src.height) > upscaleMaxSide) {
      throw FormatException(
        'Image is already ${src.width}×${src.height}; '
        'basic upscale works on images up to $upscaleMaxSide px.',
      );
    }
    final big = img.copyResize(
      src.convert(numChannels: 3),
      width: src.width * 2,
      height: src.height * 2,
      interpolation: img.Interpolation.cubic,
    );
    final blurred = img.gaussianBlur(big.clone(), radius: 2);
    final out = unsharp(big, blurred, amount: amount, threshold: threshold);
    return Uint8List.fromList(img.encodeJpg(out, quality: 92));
  }

  /// out = orig + amount * (orig - blur) where the difference exceeds [threshold].
  static img.Image unsharp(
    img.Image orig,
    img.Image blur, {
    required double amount,
    required int threshold,
  }) {
    final o = orig.getBytes(order: img.ChannelOrder.rgb);
    final b = blur.getBytes(order: img.ChannelOrder.rgb);
    final r = Uint8List(o.length);
    for (var i = 0; i < o.length; i++) {
      final d = o[i] - b[i];
      if (d.abs() < threshold) {
        r[i] = o[i];
      } else {
        final v = (o[i] + amount * d).round();
        r[i] = v < 0 ? 0 : (v > 255 ? 255 : v);
      }
    }
    return img.Image.fromBytes(
      width: orig.width,
      height: orig.height,
      bytes: r.buffer,
      order: img.ChannelOrder.rgb,
    );
  }
}
