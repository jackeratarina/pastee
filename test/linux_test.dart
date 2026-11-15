import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:pastee/model/hotkey.dart';
import 'package:pastee/providers/providers.dart';
import 'package:pastee/services/desktop_bridge.dart';
import 'package:pastee/services/key_store.dart';
import 'package:pastee/services/storage_service.dart';

import 'support/fakes.dart';

final linux = TargetPlatformVariant.only(TargetPlatform.linux);

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

  group('Linux desktop bridge', () {
    const channel = MethodChannel('pastee/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const spec = HotKeySpec(
        keyLabel: 'V',
        keyCode: 0x76,
        modifiers: {KeyModifier.control, KeyModifier.alt});

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Future<HotKeyResult> registerAnswering(int status) async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return status;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final bridge = MethodChannelDesktopBridge(channel: channel);
        expect(bridge.isSupported, isTrue);
        final result = await bridge.registerHotKey(spec);
        expect(calls.single.arguments, {'keyCode': 0x76, 'modifiers': 0x0c});
        return result;
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    test('describes the Linux results', () async {
      expect((await registerAnswering(0)).ok, isTrue);
      expect((await registerAnswering(10)).error,
          'Another app is already using Ctrl+Alt+V. Pick a different shortcut.');
      expect((await registerAnswering(-2)).error,
          contains("doesn't let apps set a global shortcut"));
      expect((await registerAnswering(-3)).error, contains('keyboard layout'));
      expect(
          (await registerAnswering(-4)).error, contains('keyboard settings'));
      expect((await registerAnswering(-5)).error, contains('couldn'));
      expect((await registerAnswering(2)).error, contains('(error 2)'));
    });
  });

  testWidgets('Settings suggests pastee --toggle when the shortcut fails',
      (tester) async {
    final app = TestApp(
        bridge: FakeBridge(
            failWith: 'Your desktop doesn\'t let apps set a global shortcut.'));
    await app.pump(tester);
    await pressShortcut(tester, LogicalKeyboardKey.comma);
    await tester.pumpAndSettle();
    final dialog = find.byType(Dialog);
    expect(
        find.descendant(
            of: dialog,
            matching: find
                .text('Your desktop doesn\'t let apps set a global shortcut.')),
        findsOneWidget);
    expect(
        find.descendant(
            of: dialog,
            matching: find.textContaining('--toggle', findRichText: true)),
        findsOneWidget);
    // No Touch ID / Windows Hello on Linux, and no mention of it.
    expect(find.textContaining('Touch ID'), findsNothing);
  }, variant: linux);

  testWidgets('Settings records shortcuts as X keysyms and masks',
      (tester) async {
    final app = TestApp();
    await app.pump(tester);
    await pressShortcut(tester, LogicalKeyboardKey.comma);
    await tester.pumpAndSettle();
    expect(find.textContaining('--toggle', findRichText: true), findsNothing,
        reason: 'the shortcut works, so no hint');

    await tester.tap(find.text('Record'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final custom = app.container.read(settingsProvider).summonHotKey!;
    expect(custom.display, 'Ctrl+Alt+B');
    expect(custom.keyCode, 0x62); // XK_b
    expect(custom.nativeModifiers, 0x04 | 0x08);
    expect(app.bridge.registered.last, custom);
  }, variant: linux);

  group('Linux storage', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('pastee_linux_test');
    });

    tearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });

    int mode(String path) => FileStat.statSync(path).mode & 0x1ff;

    test('the data folder and key file are private to the user', () async {
      final dataDir = Directory(p.join(root.path, 'support', 'data'));
      final keyFile = File(p.join(dataDir.path, 'key.bin'));
      await Storage.open(dataDir: dataDir, keyStore: FileKeyStore(keyFile));
      expect(mode(dataDir.path), 0x1c0, reason: '0700'); // drwx------
      expect(mode(keyFile.path), 0x180, reason: '0600'); // -rw-------
      await Hive.close();

      // Folders and keys left with looser modes are tightened on the next run.
      await Process.run('chmod', ['755', dataDir.path]);
      await Process.run('chmod', ['644', keyFile.path]);
      await Storage.open(dataDir: dataDir, keyStore: FileKeyStore(keyFile));
      expect(mode(dataDir.path), 0x1c0);
      expect(mode(keyFile.path), 0x180);
    }, skip: !Platform.isLinux ? 'File modes are set on Linux only' : false);
  });
}
