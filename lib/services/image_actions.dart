import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

/// Save / share / copy helpers shared by the result view and History.
class ImageActions {
  static const album = 'Imagine Pad';

  static Future<void> saveToGallery(
    BuildContext context,
    File file, {
    bool quiet = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Android 10+ needs no permission to add to MediaStore; older versions
      // ask for storage access (WRITE_EXTERNAL_STORAGE, maxSdkVersion 29).
      if (!await Gal.hasAccess(toAlbum: true)) {
        final ok = await Gal.requestAccess(toAlbum: true);
        if (!ok) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text(
                'Permission denied. Allow photo access in Android Settings.',
              ),
            ),
          );
          return;
        }
      }
      await Gal.putImage(file.path, album: album);
      if (quiet) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Saved to your gallery (Imagine Pad album)'),
        ),
      );
    } on GalException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save: ${e.type.message}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  static Future<void> share(
    BuildContext context,
    File file,
    String prompt,
  ) async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        text: prompt,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  static Future<void> copyPrompt(BuildContext context, String prompt) async {
    await Clipboard.setData(ClipboardData(text: prompt));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Prompt copied')));
    }
  }
}
