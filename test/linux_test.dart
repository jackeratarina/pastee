import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/model/hotkey.dart';

void onLinux(void Function() body) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  try {
    body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

KeyDownEvent keyDown(LogicalKeyboardKey logical, PhysicalKeyboardKey physical) {
  return KeyDownEvent(
      physicalKey: physical, logicalKey: logical, timeStamp: Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Linux shortcuts', () {
    test('X keysyms, X modifier masks and Linux labels', () {
      onLinux(() {
        const spec = HotKeySpec(
            keyLabel: 'V',
            keyCode: 0x76,
            modifiers: {KeyModifier.control, KeyModifier.alt});
        expect(spec.display, 'Ctrl+Alt+V');
        expect(spec.nativeModifiers, 0x04 | 0x08); // ControlMask | Mod1Mask
        const all = HotKeySpec(
            keyLabel: 'K', keyCode: 0x6b, modifiers: {...KeyModifier.values});
        expect(all.display, 'Ctrl+Alt+Shift+Super+K');
        expect(all.nativeModifiers, 0x01 | 0x04 | 0x08 | 0x40);
      });
    });

    test('recorded keys become keysyms that follow the layout', () {
      onLinux(() {
        int? code(LogicalKeyboardKey logical, PhysicalKeyboardKey physical) =>
            HotKeySpec.fromKeyEvent(
                keyDown(logical, physical), {KeyModifier.control})?.keyCode;
        expect(code(LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV), 0x76);
        // A German layout: the key labeled Z sits where QWERTY has Y.
        expect(code(LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyY), 0x7a);
        expect(
            code(LogicalKeyboardKey.digit1, PhysicalKeyboardKey.digit1), 0x31);
        expect(code(LogicalKeyboardKey.slash, PhysicalKeyboardKey.slash), 0x2f);
        expect(code(LogicalKeyboardKey.space, PhysicalKeyboardKey.space), 0x20);
        // Not the keypad or ISO keysyms that map to the same logical key.
        expect(code(LogicalKeyboardKey.tab, PhysicalKeyboardKey.tab),
            0xff09); // XK_Tab, not ISO_Left_Tab or KP_Tab
        expect(code(LogicalKeyboardKey.f1, PhysicalKeyboardKey.f1),
            0xffbe); // XK_F1, not KP_F1
        expect(code(LogicalKeyboardKey.f13, PhysicalKeyboardKey.f13), 0xffca);
        expect(
            HotKeySpec.fromKeyEvent(
                    keyDown(LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV),
                    {KeyModifier.alt, KeyModifier.meta})!
                .display,
            'Alt+Super+V');
      });
    });

    test('presets are valid, Ctrl+Alt+V first', () {
      onLinux(() {
        final presets = recommendedHotKeys();
        expect(presets.first.recommended, isTrue);
        expect(presets.first.spec.display, 'Ctrl+Alt+V');
        expect(presets.first.spec.keyCode, 0x76); // XK_v
        expect(presets.map((p) => p.spec.problem), everyElement(isNull));
        expect(defaultHotKey(), presets.first.spec);
      });
    });

    test('desktop and terminal shortcuts are explained', () {
      onLinux(() {
        String? problem(Set<KeyModifier> mods, String key) =>
            HotKeySpec(keyLabel: key, keyCode: 1, modifiers: mods).problem;
        const ctrlAlt = {KeyModifier.control, KeyModifier.alt};
        expect(
            problem({KeyModifier.shift}, 'K'), contains('Ctrl, Alt or Super'));
        expect(problem({KeyModifier.meta}, 'V'), contains('two modifier keys'));
        expect(problem({KeyModifier.meta}, 'L'), contains('Ctrl+Alt'));
        expect(problem(ctrlAlt, 'T'), contains('terminal'));
        expect(problem(ctrlAlt, 'L'), contains('locks the screen'));
        expect(problem(ctrlAlt, 'D'), contains('desktop'));
        expect(problem(ctrlAlt, 'F3'), contains('console'));
        expect(problem({KeyModifier.alt, KeyModifier.shift}, 'Tab'),
            contains('switches windows'));
        expect(problem({KeyModifier.control, KeyModifier.meta}, '3'),
            contains('dash'));
        expect(problem({KeyModifier.control, KeyModifier.shift}, 'V'),
            contains('terminals paste'));
        expect(problem(ctrlAlt, 'V'), isNull);
        expect(problem(ctrlAlt, 'K'), isNull);
        expect(problem({KeyModifier.alt, KeyModifier.meta}, 'V'), isNull);
      });
    });
  });
}
