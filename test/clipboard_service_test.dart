import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/model/app_settings.dart';
import 'package:pastee/providers/providers.dart';
import 'package:pastee/services/clipboard_service.dart';
import 'package:pastee/services/storage_service.dart';

import 'support/fakes.dart';

void main() {
  const delay = Duration(seconds: 30);

  group('ClipboardService', () {
    testWidgets('a secret is copied concealed and cleared after the delay',
        (tester) async {
      final bridge = FakeBridge();
      final service =
          ClipboardService(bridge: bridge, clearSecretsAfter: () => delay);
      addTearDown(service.dispose);

      expect(await service.setText('hunter2!', secret: true), delay);
      expect(bridge.clipboardText, 'hunter2!');
      expect(bridge.lastWriteConcealed, isTrue);
      expect(bridge.lastWriteClearsOnExit, isTrue);

      await tester.pump(const Duration(seconds: 29));
      expect(bridge.clipboardText, 'hunter2!');
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.clipboardText, isNull);
    });

    testWidgets('something copied since is never cleared', (tester) async {
      final bridge = FakeBridge();
      final service =
          ClipboardService(bridge: bridge, clearSecretsAfter: () => delay);
      addTearDown(service.dispose);

      await service.setText('hunter2!', secret: true);
      bridge.otherAppCopied('a link from the browser');
      await tester.pump(const Duration(seconds: 31));
      expect(bridge.clearCalls, 1);
      expect(bridge.clipboardText, 'a link from the browser');
    });

    testWidgets('a newer copy from Pastee cancels the pending clear',
        (tester) async {
      final system = SystemClipboardMock()..install(tester);
      final bridge = FakeBridge();
      final service =
          ClipboardService(bridge: bridge, clearSecretsAfter: () => delay);
      addTearDown(service.dispose);

      await service.setText('hunter2!', secret: true);
      expect(await service.setText('just a note'), isNull);
      expect(system.text, 'just a note');
      await tester.pump(const Duration(minutes: 1));
      expect(bridge.clearCalls, 0);
      expect(system.text, 'just a note');
    });

    testWidgets('"Never" still conceals the secret but leaves it there',
        (tester) async {
      final bridge = FakeBridge();
      final service =
          ClipboardService(bridge: bridge, clearSecretsAfter: () => null);
      addTearDown(service.dispose);

      expect(await service.setText('hunter2!', secret: true), isNull);
      expect(bridge.lastWriteConcealed, isTrue);
      expect(bridge.lastWriteClearsOnExit, isFalse);
      await tester.pump(const Duration(minutes: 10));
      expect(bridge.clearCalls, 0);
      expect(bridge.clipboardText, 'hunter2!');
    });

    testWidgets('ordinary text goes through the normal clipboard',
        (tester) async {
      final system = SystemClipboardMock()..install(tester);
      final bridge = FakeBridge();
      final service =
          ClipboardService(bridge: bridge, clearSecretsAfter: () => delay);
      addTearDown(service.dispose);

      expect(await service.setText('hello'), isNull);
      expect(system.text, 'hello');
      expect(bridge.clipboardText, isNull);
      await tester.pump(const Duration(minutes: 1));
      expect(system.text, 'hello');
    });

    testWidgets(
        'without the native side, a secret is cleared only if it is still there',
        (tester) async {
      final system = SystemClipboardMock()..install(tester);
      final service = ClipboardService(
          bridge: FakeBridge(supported: false), clearSecretsAfter: () => delay);
      addTearDown(service.dispose);

      await service.setText('hunter2!', secret: true);
      expect(system.text, 'hunter2!');
      await tester.pump(delay);
      expect(system.text, '');

      await service.setText('hunter2!', secret: true);
      system.text = 'copied in another app';
      await tester.pump(delay);
      expect(system.text, 'copied in another app');
    });

    testWidgets('uses the delay set at the time of copying', (tester) async {
      final bridge = FakeBridge();
      var current = const Duration(seconds: 10);
      final service =
          ClipboardService(bridge: bridge, clearSecretsAfter: () => current);
      addTearDown(service.dispose);

      expect(await service.setText('482913', secret: true), current);
      current = const Duration(minutes: 2);
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.clipboardText, isNull);

      expect(await service.setText('482913', secret: true),
          const Duration(minutes: 2));
      service.dispose(); // before the test checks for pending timers
    });

    test('describes the delay briefly', () {
      expect(describeClearDelay(const Duration(seconds: 10)), '10 s');
      expect(describeClearDelay(const Duration(seconds: 30)), '30 s');
      expect(describeClearDelay(const Duration(seconds: 90)), '90 s');
      expect(describeClearDelay(const Duration(minutes: 1)), '1 min');
      expect(describeClearDelay(const Duration(minutes: 5)), '5 min');
    });
  });

  group('"Clear copied secrets" setting', () {
    AppSettings load(Map<String, Object?> values) {
      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(MemorySettingsStore(values)),
      ]);
      addTearDown(container.dispose);
      return container.read(settingsProvider);
    }

    test('defaults to 30 seconds', () {
      expect(load({}).clearSecretsAfter, const Duration(seconds: 30));
    });

    test('loads a saved choice, and 0 means never', () {
      expect(load({'clearSecretsAfterSeconds': 120}).clearSecretsAfter,
          const Duration(minutes: 2));
      expect(load({'clearSecretsAfterSeconds': 0}).clearSecretsAfter, isNull);
    });

    test('anything that is not a choice falls back to the default', () {
      for (final value in [77, -5, '30', true, 1e9]) {
        expect(load({'clearSecretsAfterSeconds': value}).clearSecretsAfter,
            const Duration(seconds: 30),
            reason: '$value');
      }
    });

    test('is saved', () async {
      final store = MemorySettingsStore();
      final container = ProviderContainer(
          overrides: [settingsStoreProvider.overrideWithValue(store)]);
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);

      await notifier.setClearSecretsAfter(null);
      expect(store.values['clearSecretsAfterSeconds'], 0);
      expect(container.read(settingsProvider).clearSecretsAfter, isNull);

      await notifier.setClearSecretsAfter(const Duration(minutes: 1));
      expect(store.values['clearSecretsAfterSeconds'], 60);
    });

    test('the clipboard service follows the setting', () async {
      final bridge = FakeBridge();
      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(MemorySettingsStore()),
        desktopBridgeProvider.overrideWithValue(bridge),
      ]);
      addTearDown(container.dispose);
      final clipboard = container.read(clipboardServiceProvider);

      expect(await clipboard.setText('hunter2!', secret: true),
          const Duration(seconds: 30));
      await container
          .read(settingsProvider.notifier)
          .setClearSecretsAfter(const Duration(seconds: 10));
      expect(await clipboard.setText('hunter2!', secret: true),
          const Duration(seconds: 10));
    });
  });
}
