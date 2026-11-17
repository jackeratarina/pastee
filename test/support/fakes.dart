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
import 'package:pastee/services/device_auth.dart';
import 'package:pastee/services/passcode.dart';
import 'package:pastee/services/paste_titles.dart';
import 'package:pastee/services/storage_service.dart';
import 'package:pastee/services/updates.dart';
import 'package:pastee/providers/update_provider.dart';
import 'package:pastee/ui/update_dialog.dart';

import 'update_fakes.dart';

class FakeClipboard extends ClipboardService {
  FakeClipboard([this.text]);

  String? text;

  /// Whether the last [setText] was a secret.
  bool? lastSecret;

  /// What [setText] reports back for secrets (the "clears in" delay).
  Duration? clearsSecretsAfter;

  @override
  Future<String?> getText() async => text;

  @override
  Future<Duration?> setText(String value, {bool secret = false}) async {
    text = value;
    lastSecret = secret;
    return secret ? clearsSecretsAfter : null;
  }
}

class FakeBridge implements DesktopBridge {
  FakeBridge({this.supported = true, this.failWith});

  final bool supported;
  String? failWith;
  final registered = <HotKeySpec>[];
  int unregisterCalls = 0;
  int showCalls = 0;
  int hideCalls = 0;

  /// Called when Dart asks the native side to hide the window.
  void Function()? onHide;
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
  Future<void> hideWindow() async {
    hideCalls++;
    onHide?.call();
  }

  /// A pretend system clipboard with a change number, like NSPasteboard's
  /// changeCount, Windows' clipboard sequence number or the Linux runner's
  /// own counter.
  String? clipboardText;
  int changeCount = 0;
  bool lastWriteConcealed = false;
  bool lastWriteClearsOnExit = false;
  int clearCalls = 0;

  /// Another app copied something.
  void otherAppCopied(String text) {
    clipboardText = text;
    changeCount++;
  }

  @override
  Future<int?> writeClipboard(String text,
      {required bool concealed, required bool clearOnExit}) async {
    clipboardText = text;
    lastWriteConcealed = concealed;
    lastWriteClearsOnExit = clearOnExit;
    return ++changeCount;
  }

  @override
  Future<bool> clearClipboard(int changeCount) async {
    clearCalls++;
    if (changeCount != this.changeCount) return false;
    clipboardText = null;
    this.changeCount++;
    return true;
  }
}

class FakeAuthenticator implements DeviceAuthenticator {
  FakeAuthenticator(
      {this.available = true, this.succeeds = true, this.name = 'Touch ID'});

  bool available;
  bool succeeds;
  final String name;
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<String> displayName() async => name;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return succeeds;
  }
}

/// Low PBKDF2 rounds keep tests fast; the real app uses 120k.
const testIterations = 1000;

/// Settings that turn App Lock on with [passcode].
Future<Map<String, Object?>> lockedSettings(String passcode,
    {bool deviceUnlock = false, String timeout = 'fiveMinutes'}) async {
  final hash = await PasscodeHash.create(passcode, iterations: testIterations);
  return {
    'lock.passcode': hash.toJson(),
    'lock.deviceUnlock': deviceUnlock,
    'lock.timeout': timeout,
  };
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
    FakeAuthenticator? authenticator,
    this.version,
    FakeReleaseSource? releases,
    FakeInstaller? installer,
  })  : store = MemoryPasteStore(items),
        settingsStore = MemorySettingsStore(settings),
        clipboard = clipboard ?? FakeClipboard(),
        bridge = bridge ?? FakeBridge(),
        authenticator = authenticator ?? FakeAuthenticator(available: false),
        releases = releases ?? FakeReleaseSource(),
        installer = installer ?? FakeInstaller();

  final MemoryPasteStore store;
  final MemorySettingsStore settingsStore;
  final FakeClipboard clipboard;
  final FakeBridge bridge;
  final FakeAuthenticator authenticator;

  /// The version Pastee says it is; null is a development build, which
  /// never checks for updates.
  final String? version;
  final FakeReleaseSource releases;
  final FakeInstaller installer;
  int quitCalls = 0;
  final openedUrls = <Uri>[];
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
          deviceAuthenticatorProvider.overrideWithValue(authenticator),
          passcodeIterationsProvider.overrideWithValue(testIterations),
          storageReportProvider.overrideWithValue(const StorageReport(
              dataPath: '/tmp/pastee-test', encrypted: true)),
          runningVersionProvider.overrideWithValue(Version.tryParse(version)),
          releaseSourceProvider.overrideWithValue(releases),
          updateInstallerProvider.overrideWithValue(installer),
          quitForUpdateProvider.overrideWithValue(() async => quitCalls++),
          openUrlProvider.overrideWithValue((url) async {
            openedUrls.add(url);
            return true;
          }),
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
/// Windows and Linux) held down.
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
