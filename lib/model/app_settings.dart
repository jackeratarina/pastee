import 'package:flutter/material.dart';

import 'hotkey.dart';

@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.summonHotKey,
    this.hideAfterCopy = true,
    this.maskSecrets = true,
    this.clearSecretsAfter = defaultClearSecretsAfter,
    this.checkForUpdates = true,
  });

  static const defaultClearSecretsAfter = Duration(seconds: 30);

  /// The choices Settings offers for [clearSecretsAfter], besides "Never".
  static const clearSecretsChoices = [
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  final ThemeMode themeMode;

  /// The global shortcut that shows and hides Pastee; null means off.
  final HotKeySpec? summonHotKey;

  /// After copying from a Pastee you summoned with the shortcut, hide it again
  /// so you're straight back in the app you were pasting into.
  final bool hideAfterCopy;

  /// Show detected passwords, tokens, card numbers and codes as dots.
  final bool maskSecrets;

  /// How long a copied secret stays on the clipboard before Pastee clears it;
  /// null means it stays until something else is copied.
  final Duration? clearSecretsAfter;

  /// Ask GitHub once a day whether there's a new release.
  final bool checkForUpdates;

  AppSettings copyWith({
    ThemeMode? themeMode,
    HotKeySpec? Function()? summonHotKey,
    bool? hideAfterCopy,
    bool? maskSecrets,
    Duration? Function()? clearSecretsAfter,
    bool? checkForUpdates,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      summonHotKey: summonHotKey != null ? summonHotKey() : this.summonHotKey,
      hideAfterCopy: hideAfterCopy ?? this.hideAfterCopy,
      maskSecrets: maskSecrets ?? this.maskSecrets,
      clearSecretsAfter: clearSecretsAfter != null
          ? clearSecretsAfter()
          : this.clearSecretsAfter,
      checkForUpdates: checkForUpdates ?? this.checkForUpdates,
    );
  }
}
