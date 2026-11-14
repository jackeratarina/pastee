import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/main.dart';
import 'package:pastee/model/hotkey.dart';
import 'package:pastee/model/paste_item.dart';
import 'package:pastee/providers/providers.dart';
import 'package:pastee/services/clipboard_service.dart';
import 'package:pastee/services/desktop_bridge.dart';
import 'package:pastee/services/paste_titles.dart';
import 'package:pastee/services/storage_service.dart';

class FakeClipboard extends ClipboardService {
  FakeClipboard([this.text]);

  String? text;

  @override
  Future<String?> getText() async => text;

  @override
  Future<void> setText(String value) async => text = value;
}

class FakeBridge implements DesktopBridge {
  FakeBridge({this.supported = true, this.failWith});

  final bool supported;
  String? failWith;
  final registered = <HotKeySpec>[];
  int unregisterCalls = 0;
  int showCalls = 0;
  int hideCalls = 0;
  final _summons = StreamController<bool>.broadcast();

  /// Pretend the native side handled the summon shortcut.
  void summon({required bool shown}) => _summons.add(shown);

  @override
  bool get isSupported => supported;

  @override
  Stream<bool> get summonEvents => _summons.stream;

  @override
  Future<HotKeyResult> registerHotKey(HotKeySpec spec) async {
    registered.add(spec);
    final error = failWith;
    return error == null ? const HotKeyResult.ok() : HotKeyResult.failed(error);
  }

  @override
  Future<void> unregisterHotKey() async => unregisterCalls++;

  @override
  Future<void> showWindow() async => showCalls++;

  @override
  Future<void> hideWindow() async => hideCalls++;
}

PasteItem makeItem(String content,
    {String? id, int minutesAgo = 0, bool sensitive = false}) {
  return PasteItem(
    id: id ?? content.hashCode.toString(),
    title: autoTitle(content),
    content: content,
    createdAt: DateTime.now().subtract(Duration(minutes: minutesAgo)),
    sensitive: sensitive,
  );
}

class TestApp {
  TestApp({
    List<PasteItem> items = const [],
    Map<String, Object?>? settings,
    FakeClipboard? clipboard,
    FakeBridge? bridge,
  })  : store = MemoryPasteStore(items),
        settingsStore = MemorySettingsStore(settings),
        clipboard = clipboard ?? FakeClipboard(),
        bridge = bridge ?? FakeBridge();

  final MemoryPasteStore store;
  final MemorySettingsStore settingsStore;
  final FakeClipboard clipboard;
  final FakeBridge bridge;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pasteStoreProvider.overrideWithValue(store),
          settingsStoreProvider.overrideWithValue(settingsStore),
          clipboardServiceProvider.overrideWithValue(clipboard),
          desktopBridgeProvider.overrideWithValue(bridge),
          storageReportProvider.overrideWithValue(const StorageReport(
              dataPath: '/tmp/pastee-test', encrypted: true)),
        ],
        child: const PasteeApp(),
      ),
    );
    container =
        ProviderScope.containerOf(tester.element(find.byType(PasteeApp)));
    await tester.pump();
  }

  List<PasteItem> get items => container.read(pasteListProvider);
}

/// Presses [key] with the platform's primary modifier (⌘ on macOS, Ctrl on
/// Windows) held down.
Future<void> pressShortcut(WidgetTester tester, LogicalKeyboardKey key) async {
  final modifier = defaultTargetPlatform == TargetPlatform.macOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

/// A stand-in for the system clipboard that text fields use directly.
class SystemClipboardMock {
  String? text;

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          text = (call.arguments as Map)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return text == null ? null : {'text': text};
        case 'Clipboard.hasStrings':
          return {'value': text != null && text!.isNotEmpty};
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
  }
}
