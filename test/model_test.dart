import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/model/hotkey.dart';
import 'package:pastee/model/paste_item.dart';
import 'package:pastee/providers/providers.dart';
import 'package:pastee/services/field_extractor.dart';
import 'package:pastee/services/masking.dart';
import 'package:pastee/services/paste_titles.dart';
import 'package:pastee/services/storage_service.dart';
import 'package:pastee/services/text_utils.dart';

void onPlatform(TargetPlatform platform, void Function() body) {
  debugDefaultTargetPlatformOverride = platform;
  try {
    body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  group('text helpers', () {
    test('truncation never splits an emoji', () {
      const text = 'Meeting moved to 3pm 🎉 see you';
      // The limit includes the ellipsis.
      expect(truncateGraphemes(text, 22), 'Meeting moved to 3pm …');
      final cut = truncateGraphemes(text, 23);
      expect(cut, 'Meeting moved to 3pm 🎉…');
      expect(sanitizeUtf16(cut), cut);
      expect(truncateGraphemes('short', 10), 'short');
      expect(truncateGraphemes('👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦', 2),
          '👩‍👩‍👧‍👦…');
    });

    test('sanitizeUtf16 replaces lone surrogates only', () {
      expect(sanitizeUtf16('ok 🎉'), 'ok 🎉');
      expect(sanitizeUtf16('bad \uD83C'), 'bad �');
      expect(sanitizeUtf16('\uDF89 start'), '� start');
    });
  });

  group('titles', () {
    test('auto titles use the first line and never show a password', () {
      expect(autoTitle('\n\n  Netflix  \nemail: a@b.co\npassword: hunter2!'),
          'Netflix');
      expect(autoTitle('password: hunter2! for the wifi'),
          'password: •••••••• for the wifi');
      expect(autoTitle('   '), 'Untitled');
      expect(autoTitle('x' * 100).length, maxTitleLength);
    });

    test(
        'hidden items mask secrets in titles; sensitive auto titles are replaced',
        () {
      const content = 'pin: 482913';
      final extraction = FieldExtractor.extract(content);
      final typed = PasteItem(
          id: '1',
          title: 'Bank 482913',
          content: content,
          createdAt: DateTime(2026));
      expect(displayTitle(typed, extraction, hidden: true), 'Bank ••••••••');
      expect(displayTitle(typed, extraction, hidden: false), 'Bank 482913');

      final sensitive = PasteItem(
          id: '2',
          title: autoTitle('dear diary'),
          content: 'dear diary',
          createdAt: DateTime(2026),
          sensitive: true);
      expect(displayTitle(sensitive, Extraction.empty, hidden: true),
          'Hidden item');
      expect(
          displayTitle(sensitive.copyWith(title: 'Diary'), Extraction.empty,
              hidden: true),
          'Diary');
    });
  });

  group('masking', () {
    test('segments and clamping', () {
      expect(Masker.apply('abc secret def', const [Span(4, 10)]),
          'abc ${Masker.dots} def');
      expect(Masker.apply('short', const [Span(2, 99)]), 'sh${Masker.dots}');
      expect(
          Masker.apply('aa bb', const [Span(0, 2), Span(1, 5)]), Masker.dots);
    });

    test('fields that contain a secret are partly masked', () {
      const url = 'postgres://app:S3cret!@db:5432/prod';
      final e = FieldExtractor.extract(url);
      final urlField = e.fields.firstWhere((f) => f.kind == FieldKind.url);
      expect(Masker.maskWithin(url, urlField.span, e.secretSpans),
          'postgres://app:${Masker.dots}@db:5432/prod');
    });

    test('hidden cards keep their last four digits', () {
      final card = FieldExtractor.extract('4242 4242 4242 4242')
          .fields
          .firstWhere((f) => f.kind == FieldKind.card);
      expect(Masker.hiddenFieldText(card), '•••• 4242');
    });
  });

  group('hotkeys', () {
    test('display and native modifiers per platform', () {
      const spec = HotKeySpec(
          keyLabel: 'V',
          keyCode: 9,
          modifiers: {KeyModifier.control, KeyModifier.meta});
      onPlatform(TargetPlatform.macOS, () {
        expect(spec.display, '⌃⌘V');
        expect(spec.nativeModifiers, 0x1000 | 0x0100);
      });
      onPlatform(TargetPlatform.windows, () {
        expect(spec.display, 'Ctrl+Win+V');
        expect(spec.nativeModifiers, 0x0002 | 0x0008);
      });
    });

    test('JSON round trip', () {
      const spec = HotKeySpec(
          keyLabel: 'Space',
          keyCode: 0x31,
          modifiers: {KeyModifier.control, KeyModifier.alt});
      expect(HotKeySpec.fromJson(spec.toJson()), spec);
      expect(HotKeySpec.fromJson('garbage'), isNull);
    });

    test('every recommended shortcut is valid and uses the right key codes',
        () {
      onPlatform(TargetPlatform.macOS, () {
        final presets = recommendedHotKeys();
        expect(presets.first.recommended, isTrue);
        expect(presets.first.spec.display, '⌃⌘V');
        expect(presets.map((p) => p.spec.problem), everyElement(isNull));
        expect(presets.first.spec.keyCode, 0x09); // kVK_ANSI_V
      });
      onPlatform(TargetPlatform.windows, () {
        final presets = recommendedHotKeys();
        expect(presets.first.spec.display, 'Alt+Shift+V');
        expect(presets.map((p) => p.spec.problem), everyElement(isNull));
        expect(presets.first.spec.keyCode, 0x56); // VK 'V'
      });
    });

    test('bad shortcuts are explained', () {
      onPlatform(TargetPlatform.macOS, () {
        String? problem(Set<KeyModifier> mods, [String key = 'K']) =>
            HotKeySpec(keyLabel: key, keyCode: 1, modifiers: mods).problem;
        expect(problem({KeyModifier.meta}), contains('two modifier keys'));
        expect(
            problem({KeyModifier.alt, KeyModifier.shift}), contains('⌃ or ⌘'));
        expect(problem({KeyModifier.shift, KeyModifier.meta}, '4'),
            contains('used by macOS'));
        expect(problem({KeyModifier.control, KeyModifier.alt}), isNull);
      });
      onPlatform(TargetPlatform.windows, () {
        String? problem(Set<KeyModifier> mods, [String key = 'K']) =>
            HotKeySpec(keyLabel: key, keyCode: 1, modifiers: mods).problem;
        expect(problem({KeyModifier.shift}), contains('Ctrl, Alt or Win'));
        expect(problem({KeyModifier.control}), contains('two modifier keys'));
        expect(problem({KeyModifier.shift, KeyModifier.meta}, 'S'), isNotNull);
        expect(problem({KeyModifier.alt, KeyModifier.shift}), isNull);
      });
    });
  });

  group('settings', () {
    test('defaults: recommended shortcut, masking on, hide after copy on', () {
      final notifier = SettingsNotifier(MemorySettingsStore());
      expect(notifier.state.summonHotKey, defaultHotKey());
      expect(notifier.state.maskSecrets, isTrue);
      expect(notifier.state.hideAfterCopy, isTrue);
      expect(notifier.state.themeMode, ThemeMode.system);
    });

    test('choices are saved and restored', () async {
      final store = MemorySettingsStore();
      final notifier = SettingsNotifier(store);
      await notifier.setSummonHotKey(null);
      await notifier.setThemeMode(ThemeMode.dark);
      await notifier.setMaskSecrets(false);

      final reloaded = SettingsNotifier(store).state;
      expect(reloaded.summonHotKey, isNull, reason: 'off stays off');
      expect(reloaded.themeMode, ThemeMode.dark);
      expect(reloaded.maskSecrets, isFalse);
    });
  });
}
