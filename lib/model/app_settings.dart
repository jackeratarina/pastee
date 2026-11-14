import 'package:flutter/material.dart';

import 'hotkey.dart';

@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.summonHotKey,
    this.hideAfterCopy = true,
    this.maskSecrets = true,
  });

  final ThemeMode themeMode;

  /// The global shortcut that shows and hides Pastee; null means off.
  final HotKeySpec? summonHotKey;

  /// After copying from a Pastee you summoned with the shortcut, hide it again
  /// so you're straight back in the app you were pasting into.
  final bool hideAfterCopy;

  /// Show detected passwords, tokens, card numbers and codes as dots.
  final bool maskSecrets;

  AppSettings copyWith({
    ThemeMode? themeMode,
    HotKeySpec? Function()? summonHotKey,
    bool? hideAfterCopy,
    bool? maskSecrets,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      summonHotKey: summonHotKey != null ? summonHotKey() : this.summonHotKey,
      hideAfterCopy: hideAfterCopy ?? this.hideAfterCopy,
      maskSecrets: maskSecrets ?? this.maskSecrets,
    );
  }
}
