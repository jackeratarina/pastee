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

  /// Fires when the summon shortcut is pressed: true if that showed Pastee,
  /// false if it hid it. The native side does the showing and hiding itself,
  /// which keeps focus handling instant and reliable.
  Stream<bool> get summonEvents;

  Future<HotKeyResult> registerHotKey(HotKeySpec spec);
  Future<void> unregisterHotKey();

  /// Brings Pastee to the front.
  Future<void> showWindow();

  /// Hides Pastee and returns focus to the app you were in (macOS hides the
  /// app; Windows minimizes the window).
  Future<void> hideWindow();
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

  Future<void> _invoke(String method) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Running without the native runner (tests, other platforms).
    }
  }
}
