import 'dart:async';

import 'package:flutter/services.dart';

import 'desktop_bridge.dart';

/// Reads and writes plain text on the system clipboard.
///
/// Secrets (detected passwords, codes and keys, and items you chose to always
/// hide) get extra care: they're copied so that clipboard history, clipboard
/// managers and your other devices leave them out where the system supports
/// that, and they're cleared again after the "Clear copied secrets" delay,
/// unless something else was copied in the meantime.
class ClipboardService {
  ClipboardService({
    DesktopBridge? bridge,
    Duration? Function()? clearSecretsAfter,
  })  : _bridge = bridge,
        _clearSecretsAfter = clearSecretsAfter ?? (() => null);

  final DesktopBridge? _bridge;
  final Duration? Function() _clearSecretsAfter;
  Timer? _clearTimer;

  Future<String?> getText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  /// Copies [text]. For a [secret], returns how long until it is cleared from
  /// the clipboard; null when it stays until something else is copied.
  Future<Duration?> setText(String text, {bool secret = false}) async {
    // Whatever was copied before is no longer ours to clear.
    _clearTimer?.cancel();
    _clearTimer = null;

    final clearAfter = secret ? _clearSecretsAfter() : null;
    int? changeCount;
    final bridge = _bridge;
    if (secret && bridge != null && bridge.isSupported) {
      changeCount = await bridge.writeClipboard(text,
          concealed: true, clearOnExit: clearAfter != null);
    }
    if (changeCount == null) {
      await Clipboard.setData(ClipboardData(text: text));
    }
    if (clearAfter == null) return null;

    // Two copies started back to back: only the newer one may clear.
    _clearTimer?.cancel();
    _clearTimer = Timer(clearAfter, () {
      _clearTimer = null;
      unawaited(_clearIfUnchanged(text, changeCount));
    });
    return clearAfter;
  }

  Future<void> _clearIfUnchanged(String text, int? changeCount) async {
    try {
      if (changeCount != null) {
        await _bridge!.clearClipboard(changeCount);
      } else if (await getText() == text) {
        // Without the native side there's no change number, so compare the
        // text; Flutter can't empty the clipboard, only overwrite it.
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {
      // The clipboard was busy; leave it rather than crash a timer.
    }
  }

  void dispose() {
    _clearTimer?.cancel();
    _clearTimer = null;
  }
}

/// "10 s", "1 min": how long until a copied secret is cleared.
String describeClearDelay(Duration delay) {
  if (delay.inSeconds < 60 || delay.inSeconds % 60 != 0) {
    return '${delay.inSeconds} s';
  }
  return '${delay.inMinutes} min';
}
