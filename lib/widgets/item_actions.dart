import 'package:flutter/material.dart';

import '../core/gen_types.dart';
import '../services/app_state.dart';
import '../services/history_store.dart';
import '../services/image_actions.dart';
import '../services/image_tools.dart';

/// Actions that create new History items from an existing one.
class ItemActions {
  static const upscaleNote =
      'Basic upscale 2× (smooth resize + sharpening, not AI)';

  /// Runs the on-device basic 2x upscale and stores the result in History.
  static Future<HistoryItem?> upscale(
    BuildContext context,
    AppState s,
    HistoryItem item,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 18),
            Expanded(child: Text('Upscaling 2× on your phone…')),
          ],
        ),
      ),
    );
    try {
      final src = await s.history.fileFor(item).readAsBytes();
      final out = await ImageTools.upscale2x(src);
      final size = ImageTools.sizeOf(out);
      final added = await s.history.add(
        bytes: out,
        mime: 'image/jpeg',
        prompt: item.prompt,
        basePrompt: item.basePrompt,
        style: item.style,
        aspect: item.aspect,
        seed: item.seed,
        provider: item.provider,
        model: item.model,
        kind: HistoryKind.upscale,
        parentId: item.id,
        note: size == null
            ? upscaleNote
            : '$upscaleNote · ${size.width}×${size.height}',
      );
      s.touch();
      nav.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Upscaled to ${size?.width ?? '?'}×${size?.height ?? '?'} (basic, not AI). Added to History.',
          ),
          action: SnackBarAction(
            label: 'Save',
            onPressed: () {
              if (context.mounted) {
                ImageActions.saveToGallery(context, s.history.fileFor(added));
              }
            },
          ),
        ),
      );
      return added;
    } catch (e) {
      nav.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Upscale failed: ${e is FormatException ? e.message : e}',
          ),
        ),
      );
      return null;
    }
  }

  static String kindBadge(HistoryItem i) => switch (i.kind) {
    HistoryKind.generate => i.provider.shortLabel,
    HistoryKind.edit => 'Edit',
    HistoryKind.upscale => '2× basic',
  };
}
