import 'package:flutter/foundation.dart';

bool get isMacPlatform => defaultTargetPlatform == TargetPlatform.macOS;

/// "⌘C" on macOS, "Ctrl+C" on Windows.
String primaryShortcut(String key) => isMacPlatform ? '⌘$key' : 'Ctrl+$key';

/// The in-app keyboard shortcuts, for the hint bar and the settings list.
List<(String, String)> inAppShortcuts() => [
      (primaryShortcut('V'), 'Save what’s on the clipboard as a new item'),
      (primaryShortcut('C'), 'Copy the top item (Enter does the same)'),
      (primaryShortcut('1–9'), 'Copy field 1–9 of the top item'),
      (primaryShortcut('X'), 'Cut the top item (copy, then delete)'),
      ('Delete', 'Delete the top item'),
      (primaryShortcut('Z'), 'Undo the last delete or cut'),
      (primaryShortcut('E'), 'Rename the top item'),
      (primaryShortcut('R'), 'Show or hide the top item’s hidden text'),
      (primaryShortcut('F'), 'Search (Enter copies the top result)'),
      (primaryShortcut(','), 'Settings'),
      ('Esc', 'Clear search, cancel renaming, or hide a summoned Pastee'),
    ];
