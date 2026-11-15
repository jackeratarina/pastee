import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../model/hotkey.dart';

/// Outcome of asking the OS for a global shortcut.
@immutable
class HotKeyResult {
  const HotKeyResult.ok() : error = null;
  const HotKeyResult.failed(String this.error);

  final String? error;
  bool get ok => error == null;
}

/// The small native layer in macos/Runner/MainFlutterWindow.swift and
/// windows/runner/flutter_window.cpp: one global summon shortcut, plus showing
/// and hiding the window.
abstract class DesktopBridge {
  /// False where the native side doesn't exist (tests, Linux dev builds).
  bool get isSupported;

  /// Fires when the summon shortcut is pressed. true: the native side has
  /// already shown and focused Pastee. false: the user wants it hidden; the
  /// native side waits for Dart to draw its lock screen or privacy cover and
  /// call [hideWindow], and hides by itself after 500 ms if that never comes.
  Stream<bool> get summonEvents;

  Future<HotKeyResult> registerHotKey(HotKeySpec spec);
  Future<void> unregisterHotKey();

  /// Brings Pastee to the front.
  Future<void> showWindow();

  /// Hides Pastee and returns focus to the app you were in (macOS hides the
  /// app; Windows minimizes the window).
  Future<void> hideWindow();

  /// Puts [text] on the clipboard and returns the clipboard's change number
  /// afterwards, or null if the native side couldn't (the caller then falls
  /// back to Flutter's clipboard).
  ///
  /// [concealed] marks the text as a secret so clipboard history, clipboard
  /// managers and other devices leave it out: org.nspasteboard.ConcealedType
  /// and current-host-only (no Universal Clipboard) on macOS; the formats that
  /// keep it out of clipboard history (Win+V) and cloud sync on Windows. With
  /// [clearOnExit], quitting Pastee empties the clipboard if it still holds
  /// this text.
  Future<int?> writeClipboard(String text,
      {required bool concealed, required bool clearOnExit});

  /// Empties the clipboard if its change number is still [changeCount], that
  /// is, if nothing else was copied since. Returns whether it was emptied.
  Future<bool> clearClipboard(int changeCount);
}

class MethodChannelDesktopBridge implements DesktopBridge {
  MethodChannelDesktopBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('pastee/native') {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  final MethodChannel _channel;
  final _summons = StreamController<bool>.broadcast();

  @override
  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  @override
  Stream<bool> get summonEvents => _summons.stream;

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method == 'onHotKey') {
      final args = call.arguments;
      final shown = args is Map && args['shown'] == true;
      _summons.add(shown);
    }
    return null;
  }

  @override
  Future<HotKeyResult> registerHotKey(HotKeySpec spec) async {
    if (!isSupported) {
      return const HotKeyResult.failed(
          'Global shortcuts are not available on this system.');
    }
    try {
      final status = await _channel.invokeMethod<int>('registerHotKey', {
        'keyCode': spec.keyCode,
        'modifiers': spec.nativeModifiers,
      });
      if (status == 0) return const HotKeyResult.ok();
      return HotKeyResult.failed(_describe(status ?? -1, spec));
    } on PlatformException catch (e) {
      return HotKeyResult.failed(e.message ?? 'The shortcut could not be set.');
    } on MissingPluginException {
      return const HotKeyResult.failed(
          'Global shortcuts are not available in this build.');
    }
  }

  String _describe(int status, HotKeySpec spec) {
    const macTaken = -9878; // eventHotKeyExistsErr
    const macInvalid = -9879; // eventHotKeyInvalidErr
    const windowsTaken = 1409; // ERROR_HOTKEY_ALREADY_REGISTERED
    if (status == macTaken || status == windowsTaken) {
      return 'Another app is already using ${spec.display}. Pick a different shortcut.';
    }
    if (status == macInvalid) {
      return '${spec.display} can\'t be used as a shortcut.';
    }
    return 'The system refused ${spec.display} (error $status).';
  }

  @override
  Future<void> unregisterHotKey() => _invoke('unregisterHotKey');

  @override
  Future<void> showWindow() => _invoke('showWindow');

  @override
  Future<void> hideWindow() => _invoke('hideWindow');

  @override
  Future<int?> writeClipboard(String text,
      {required bool concealed, required bool clearOnExit}) async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<int>('writeClipboard', {
        'text': text,
        'concealed': concealed,
        'clearOnExit': clearOnExit,
      });
    } on PlatformException {
      return null; // e.g. another app is holding the clipboard open
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> clearClipboard(int changeCount) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>(
              'clearClipboard', {'changeCount': changeCount}) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _invoke(String method) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Running without the native runner (tests, other platforms).
    }
  }
}
