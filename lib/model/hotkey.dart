import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum KeyModifier { control, alt, shift, meta }

/// A system-wide shortcut, stored with the native key code of the platform it
/// was set on: a macOS virtual key code, a Windows virtual-key code, or an X
/// keysym on Linux (the same number as a GDK keyval, lowercase for letters).
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
  static bool get _isLinux => defaultTargetPlatform == TargetPlatform.linux;

  /// "⌃⌘V" on macOS, "Alt+Shift+V" on Windows, "Ctrl+Alt+V" or "Super+V" on
  /// Linux.
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
      if (modifiers.contains(KeyModifier.meta)) _isLinux ? 'Super' : 'Win',
      keyLabel,
    ].join('+');
  }

  /// Modifier flags in the native format: Carbon modifier masks on macOS,
  /// RegisterHotKey MOD_* flags on Windows, X modifier masks on Linux.
  int get nativeModifiers {
    var flags = 0;
    if (_isLinux) {
      if (modifiers.contains(KeyModifier.shift)) flags |= 0x01; // ShiftMask
      if (modifiers.contains(KeyModifier.control)) {
        flags |= 0x04; // ControlMask
      }
      if (modifiers.contains(KeyModifier.alt)) flags |= 0x08; // Mod1Mask
      if (modifiers.contains(KeyModifier.meta)) flags |= 0x40; // Mod4Mask
    } else if (_isMac) {
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
    } else if (_isLinux) {
      // X keysyms follow the keyboard layout. Latin-1 keysyms are their
      // code points, like Flutter's logical keys for printable keys.
      final id = event.logicalKey.keyId;
      code = id < 0x100 ? id : _gtkKeyvals[event.logicalKey];
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
      return 'Include Ctrl, Alt or ${_isLinux ? 'Super' : 'Win'}. Shift alone is for typing.';
    }
    final fNumber = RegExp(r'^F(\d+)$').firstMatch(keyLabel);
    final isHighFKey = fNumber != null && int.parse(fNumber.group(1)!) >= 13;
    if (modifiers.length < 2 && !isHighFKey) {
      final example = _isMac
          ? '⌃⌘'
          : _isLinux
              ? 'Ctrl+Alt'
              : 'Alt+Shift';
      return 'Use two modifier keys (like $example) so it doesn\'t clash with app shortcuts.';
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
    } else if (_isLinux) {
      for (final (taken, keys, use) in _linuxReserved) {
        if (setEquals(modifiers, taken) && keys.contains(keyLabel)) {
          return '$display $use.';
        }
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

  /// X keysyms of the keys above Latin-1 (Tab, F-keys): the inverse of
  /// Flutter's GTK table, without the keypad (KP_Tab, KP_F1…) and ISO
  /// (ISO_Left_Tab) keysyms that share a logical key with the main keyboard.
  static final Map<LogicalKeyboardKey, int> _gtkKeyvals = () {
    final map = <LogicalKeyboardKey, int>{};
    for (final entry in kGtkToLogicalKey.entries) {
      final keyval = entry.key;
      final isKeypadOrIso = (keyval >= 0xfe00 && keyval <= 0xfeff) ||
          (keyval >= 0xff80 && keyval <= 0xffbd);
      if (!isKeypadOrIso) map.putIfAbsent(entry.value, () => keyval);
    }
    return map;
  }();
}

const _ctrlAlt = {KeyModifier.control, KeyModifier.alt};
const _altShift = {KeyModifier.alt, KeyModifier.shift};
const _shiftSuper = {KeyModifier.shift, KeyModifier.meta};
const _ctrlSuper = {KeyModifier.control, KeyModifier.meta};
const _altSuper = {KeyModifier.alt, KeyModifier.meta};
const _digits = {'1', '2', '3', '4', '5', '6', '7', '8', '9', '0'};

/// Shortcuts that GNOME, Ubuntu, KDE Plasma, Xfce, Cinnamon or MATE bind out
/// of the box (2026 defaults), and what they do there.
const List<(Set<KeyModifier>, Set<String>, String)> _linuxReserved = [
  (_ctrlAlt, {'T'}, 'opens a terminal in Ubuntu, KDE, Xfce and Cinnamon'),
  (_ctrlAlt, {'L'}, 'locks the screen in Xfce, Cinnamon and MATE'),
  (_ctrlAlt, {'D'}, 'shows the desktop in Ubuntu, Xfce and MATE'),
  (_ctrlAlt, {'Tab'}, 'switches between panels in GNOME, Cinnamon and MATE'),
  (
    _ctrlAlt,
    {'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'},
    'switches to another console or session',
  ),
  (_altShift, {'Tab', '`'}, 'switches windows backwards'),
  (_shiftSuper, {'Tab', '`'}, 'switches windows backwards in GNOME'),
  (_shiftSuper, {'S', 'R'}, 'takes a screenshot or recording in KDE Plasma'),
  (_shiftSuper, _digits, 'opens apps from the dock in Ubuntu and Cinnamon'),
  (_ctrlSuper, _digits, 'opens apps from the dash in GNOME and Ubuntu'),
  (_altSuper, {'S', '8', '=', '-'}, 'controls the screen reader or zoom'),
  (_altSuper, {'K', 'L', 'P', 'R'}, 'is used by KDE Plasma'),
  (
    {KeyModifier.control, KeyModifier.shift},
    {'V'},
    'is how terminals paste',
  ),
];

/// A suggested summon shortcut with a note about what else uses it.
@immutable
class HotKeyPreset {
  const HotKeyPreset(this.spec, this.note, {this.recommended = false});

  final HotKeySpec spec;
  final String note;
  final bool recommended;
}

// macOS virtual key codes (Carbon kVK_*), Windows virtual-key codes, and X
// keysyms (Linux).
const _macV = 0x09;
const _macSpace = 0x31;
const _winV = 0x56;
const _xV = 0x76; // XK_v
const _xSpace = 0x20; // XK_space

/// Recommended summon shortcuts for the current platform, best first.
List<HotKeyPreset> recommendedHotKeys() {
  if (defaultTargetPlatform == TargetPlatform.linux) {
    return const [
      HotKeyPreset(
        HotKeySpec(keyLabel: 'V', keyCode: _xV, modifiers: _ctrlAlt),
        'Free in GNOME, KDE and Xfce. GPaste and JetBrains IDEs use it.',
        recommended: true,
      ),
      HotKeyPreset(
        HotKeySpec(keyLabel: 'V', keyCode: _xV, modifiers: _altSuper),
        'Free in GNOME, KDE and Xfce, and rarely taken by apps.',
      ),
      HotKeyPreset(
        HotKeySpec(keyLabel: 'V', keyCode: _xV, modifiers: _shiftSuper),
        'Popular with clipboard apps; GNOME clipboard extensions like Pano use it.',
      ),
      HotKeyPreset(
        HotKeySpec(keyLabel: 'Space', keyCode: _xSpace, modifiers: _ctrlAlt),
        'Rarely taken. Easy to press with one hand.',
      ),
    ];
  }
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
