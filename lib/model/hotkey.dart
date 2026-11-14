import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum KeyModifier { control, alt, shift, meta }

/// A system-wide shortcut, stored with the native key code of the platform it
/// was set on (a macOS virtual key code or a Windows virtual-key code).
@immutable
class HotKeySpec {
  const HotKeySpec({
    required this.keyLabel,
    required this.keyCode,
    required this.modifiers,
  });

  /// What the key is called on screen: "V", "Space", "F5".
  final String keyLabel;
  final int keyCode;
  final Set<KeyModifier> modifiers;

  static bool get _isMac => defaultTargetPlatform == TargetPlatform.macOS;

  /// "⌃⌘V" on macOS, "Alt+Shift+V" elsewhere.
  String get display {
    if (_isMac) {
      final buffer = StringBuffer();
      if (modifiers.contains(KeyModifier.control)) buffer.write('⌃');
      if (modifiers.contains(KeyModifier.alt)) buffer.write('⌥');
      if (modifiers.contains(KeyModifier.shift)) buffer.write('⇧');
      if (modifiers.contains(KeyModifier.meta)) buffer.write('⌘');
      buffer.write(keyLabel);
      return buffer.toString();
    }
    return [
      if (modifiers.contains(KeyModifier.control)) 'Ctrl',
      if (modifiers.contains(KeyModifier.alt)) 'Alt',
      if (modifiers.contains(KeyModifier.shift)) 'Shift',
      if (modifiers.contains(KeyModifier.meta)) 'Win',
      keyLabel,
    ].join('+');
  }

  /// Modifier flags in the native format: Carbon modifier masks on macOS,
  /// RegisterHotKey MOD_* flags on Windows.
  int get nativeModifiers {
    var flags = 0;
    if (_isMac) {
      if (modifiers.contains(KeyModifier.meta)) flags |= 0x0100; // cmdKey
      if (modifiers.contains(KeyModifier.shift)) flags |= 0x0200; // shiftKey
      if (modifiers.contains(KeyModifier.alt)) flags |= 0x0800; // optionKey
      if (modifiers.contains(KeyModifier.control)) {
        flags |= 0x1000; // controlKey
      }
    } else {
      if (modifiers.contains(KeyModifier.alt)) flags |= 0x0001; // MOD_ALT
      if (modifiers.contains(KeyModifier.control)) {
        flags |= 0x0002; // MOD_CONTROL
      }
      if (modifiers.contains(KeyModifier.shift)) flags |= 0x0004; // MOD_SHIFT
      if (modifiers.contains(KeyModifier.meta)) flags |= 0x0008; // MOD_WIN
    }
    return flags;
  }

  Map<String, Object> toJson() => {
        'key': keyLabel,
        'code': keyCode,
        'mods': [
          for (final m in KeyModifier.values)
            if (modifiers.contains(m)) m.name
        ],
      };

  static HotKeySpec? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['key'];
    final code = json['code'];
    final mods = json['mods'];
    if (key is! String || code is! int || mods is! List) return null;
    return HotKeySpec(
      keyLabel: key,
      keyCode: code,
      modifiers: {
        for (final name in mods)
          for (final m in KeyModifier.values)
            if (m.name == name) m,
      },
    );
  }

  /// Builds a spec from a key press in the shortcut recorder. Returns null for
  /// keys that can't be a global shortcut (a lone modifier, Escape, arrows…).
  static HotKeySpec? fromKeyEvent(KeyEvent event, Set<KeyModifier> modifiers) {
    final label = _labelFor(event.logicalKey);
    if (label == null) return null;
    final int? code;
    if (_isMac) {
      // Carbon hotkeys use physical key positions.
      code = _macKeyCodes[event.physicalKey];
    } else {
      // RegisterHotKey uses virtual keys, which follow the keyboard layout.
      code = _windowsKeyCodes[event.logicalKey];
    }
    if (code == null) return null;
    return HotKeySpec(keyLabel: label, keyCode: code, modifiers: modifiers);
  }

  /// Why this combination makes a bad global shortcut, or null if it's fine.
  String? get problem {
    final has = modifiers.contains;
    if (_isMac) {
      if (!has(KeyModifier.control) && !has(KeyModifier.meta)) {
        return 'Include ⌃ or ⌘. Combinations of only ⌥ and ⇧ type special characters.';
      }
    } else if (!has(KeyModifier.control) &&
        !has(KeyModifier.alt) &&
        !has(KeyModifier.meta)) {
      return 'Include Ctrl, Alt or Win. Shift alone is for typing.';
    }
    final fNumber = RegExp(r'^F(\d+)$').firstMatch(keyLabel);
    final isHighFKey = fNumber != null && int.parse(fNumber.group(1)!) >= 13;
    if (modifiers.length < 2 && !isHighFKey) {
      return 'Use two modifier keys (like ${_isMac ? '⌃⌘' : 'Alt+Shift'}) so it doesn\'t clash with app shortcuts.';
    }
    if (_isMac) {
      if (setEquals(modifiers, {KeyModifier.control, KeyModifier.meta}) &&
          const {'Space', 'Q', 'F', 'D'}.contains(keyLabel)) {
        return '$display is already used by macOS.';
      }
      if (setEquals(modifiers, {KeyModifier.shift, KeyModifier.meta}) &&
          const {'3', '4', '5', '6', 'Q'}.contains(keyLabel)) {
        return '$display is already used by macOS.';
      }
    } else {
      if (setEquals(modifiers, {KeyModifier.shift, KeyModifier.meta}) &&
          const {'S', 'V'}.contains(keyLabel)) {
        return '$display is already used by Windows or PowerToys.';
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is HotKeySpec &&
      other.keyCode == keyCode &&
      setEquals(other.modifiers, modifiers);

  @override
  int get hashCode => Object.hash(keyCode, Object.hashAllUnordered(modifiers));

  @override
  String toString() => 'HotKeySpec($display, code: $keyCode)';

  static String? _labelFor(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.tab) return 'Tab';
    for (var i = 1; i <= 19; i++) {
      if (key.keyLabel == 'F$i') return 'F$i';
    }
    final label = key.keyLabel;
    if (label.length != 1) return null;
    if (RegExp(r'[A-Za-z0-9]').hasMatch(label) || _symbolKeys.contains(label)) {
      return label.toUpperCase();
    }
    return null;
  }

  static const _symbolKeys = r"`-=[];',./\\";

  static final Map<PhysicalKeyboardKey, int> _macKeyCodes = {
    for (final entry in kMacOsToPhysicalKey.entries) entry.value: entry.key,
  };

  static final Map<LogicalKeyboardKey, int> _windowsKeyCodes = () {
    final map = <LogicalKeyboardKey, int>{};
    for (final entry in kWindowsToLogicalKey.entries) {
      map.putIfAbsent(entry.value, () => entry.key);
    }
    return map;
  }();
}

/// A suggested summon shortcut with a note about what else uses it.
@immutable
class HotKeyPreset {
  const HotKeyPreset(this.spec, this.note, {this.recommended = false});

  final HotKeySpec spec;
  final String note;
  final bool recommended;
}

// macOS virtual key codes (Carbon kVK_*) and Windows virtual-key codes.
const _macV = 0x09;
const _macSpace = 0x31;
const _winV = 0x56;

/// Recommended summon shortcuts for the current platform, best first.
List<HotKeyPreset> recommendedHotKeys() {
  if (defaultTargetPlatform == TargetPlatform.macOS) {
    return const [
      HotKeyPreset(
        HotKeySpec(
            keyLabel: 'V',
            keyCode: _macV,
            modifiers: {KeyModifier.control, KeyModifier.meta}),
        'Free in macOS and most apps.',
        recommended: true,
      ),
      HotKeyPreset(
        HotKeySpec(
            keyLabel: 'V',
            keyCode: _macV,
            modifiers: {KeyModifier.shift, KeyModifier.meta}),
        'Popular with clipboard apps, but VS Code and some editors use it.',
      ),
      HotKeyPreset(
        HotKeySpec(
            keyLabel: 'V',
            keyCode: _macV,
            modifiers: {KeyModifier.alt, KeyModifier.meta}),
        'Finder uses it to move copied files.',
      ),
      HotKeyPreset(
        HotKeySpec(
            keyLabel: 'Space',
            keyCode: _macSpace,
            modifiers: {KeyModifier.control, KeyModifier.alt}),
        'Rarely taken. Easy to press with one hand.',
      ),
    ];
  }
  return const [
    HotKeyPreset(
      HotKeySpec(
          keyLabel: 'V',
          keyCode: _winV,
          modifiers: {KeyModifier.alt, KeyModifier.shift}),
      'Free in Windows and most apps.',
      recommended: true,
    ),
    HotKeyPreset(
      HotKeySpec(
          keyLabel: 'V',
          keyCode: _winV,
          modifiers: {KeyModifier.control, KeyModifier.shift}),
      'Browsers, Office and Windows Terminal use it to paste plain text.',
    ),
    HotKeyPreset(
      HotKeySpec(
          keyLabel: 'V',
          keyCode: _winV,
          modifiers: {KeyModifier.alt, KeyModifier.meta}),
      'Rarely taken. A bit of a stretch to press.',
    ),
    HotKeyPreset(
      HotKeySpec(
          keyLabel: 'V',
          keyCode: _winV,
          modifiers: {KeyModifier.control, KeyModifier.alt}),
      'Office uses it for Paste Special, and on some keyboard layouts it types a character.',
    ),
  ];
}

/// The shortcut Pastee uses until the user picks another one.
HotKeySpec defaultHotKey() => recommendedHotKeys().first.spec;
