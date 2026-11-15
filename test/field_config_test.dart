import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/model/field_config.dart';
import 'package:pastee/model/paste_item.dart';
import 'package:pastee/providers/field_config_provider.dart';
import 'package:pastee/providers/providers.dart';
import 'package:pastee/services/field_extractor.dart';
import 'package:pastee/services/paste_titles.dart';
import 'package:pastee/services/storage_service.dart';

import 'support/field_helpers.dart';
import 'support/fakes.dart';

final _everything = FieldConfig(
  custom: [
    rule('Mã khách hàng',
        phrases: ['mã KH', 'customer no.'],
        pattern: r'KH-(\d{4,})\s*"',
        secret: true,
        number: 3),
    rule('Off', phrases: ['seat'], enabled: false),
    rule('Pattern only', pattern: r'\p{Lu}{2}\d{6}'),
  ],
  builtIn: {
    BuiltInField.email: const BuiltInFieldSetting(number: 2),
    BuiltInField.ip: const BuiltInFieldSetting(enabled: false),
    BuiltInField.password: const BuiltInFieldSetting(enabled: false, number: 9),
  },
  numberLines: false,
);

void main() {
  group('saving', () {
    test('round trip, as a JSON string or as its decoded map', () {
      final encoded = _everything.encode();
      expect(FieldConfig.decode(encoded), _everything);
      expect(FieldConfig.decode(jsonDecode(encoded)), _everything);
      expect(FieldConfig.decode(FieldConfig.defaults.encode()),
          FieldConfig.defaults);
    });

    test('the saved shape', () {
      final json = jsonDecode(_everything.encode()) as Map<String, dynamic>;
      expect(json['version'], 1);
      expect(json['numberLines'], false);
      expect(json['builtIn'], {
        'email': {'enabled': true, 'number': 2},
        'ip': {'enabled': false, 'number': null},
        'password': {'enabled': false, 'number': 9},
      });
      expect((json['custom'] as List).first, {
        'id': 'id-Mã khách hàng',
        'name': 'Mã khách hàng',
        'phrases': ['mã KH', 'customer no.'],
        'pattern': r'KH-(\d{4,})\s*"',
        'secret': true,
        'number': 3,
        'enabled': true,
      });
    });

    test('defaults are not written out', () {
      expect(
          FieldConfig(builtIn: {
            BuiltInField.email: BuiltInFieldSetting.standard,
          }).builtIn,
          isEmpty);
      expect(FieldConfig(), FieldConfig.defaults);
      expect(FieldConfig().isDefault, isTrue);
    });
  });

  group('unreadable settings give the defaults', () {
    test('missing, garbage or from a newer version', () {
      for (final stored in <Object?>[
        null,
        '',
        'not json',
        '[1, 2]',
        '{"version": 2, "custom": []}',
        '{"custom": []}',
        42,
        true,
        ['version', 1],
        {'version': '1'},
      ]) {
        expect(FieldConfig.decode(stored), FieldConfig.defaults,
            reason: '$stored');
      }
    });

    test('wrong types fall back field by field', () {
      final config = FieldConfig.decode({
        'version': 1,
        'custom': 'nope',
        'builtIn': ['email'],
        'numberLines': 'yes',
      });
      expect(config, FieldConfig.defaults);
    });

    test('bad rules and entries are skipped, good ones kept', () {
      final config = FieldConfig.decode(jsonEncode({
        'version': 1,
        'custom': [
          {
            'id': 'a',
            'name': 'Good',
            'phrases': ['seat', 7, ''],
            'number': 4
          },
          {
            'id': 'b',
            'name': '  ',
            'phrases': ['nameless']
          },
          {'id': 'c', 'name': 'Nothing to find'},
          {'id': 'a', 'name': 'Same id', 'pattern': r'\d+'},
          'not a rule',
          {
            'name': 'No id, odd values',
            'phrases': ['x'],
            'number': 12,
            'secret': 'yes',
            'enabled': null,
          },
        ],
        'builtIn': {
          'email': {'enabled': false, 'number': '3'},
          'phone': {'number': 0},
          'teleport': {'enabled': false},
          'ip': 'off',
        },
      }));
      expect(config.custom.map((r) => r.name),
          ['Good', 'Same id', 'No id, odd values']);
      expect(config.custom.map((r) => r.id).toSet(), hasLength(3));
      expect(config.custom[0].phrases, ['seat']);
      expect(config.custom[0].number, 4);
      expect(config.custom[2].number, isNull);
      expect(config.custom[2].secret, isFalse);
      expect(config.custom[2].enabled, isTrue);
      expect(config.builtIn, {
        BuiltInField.email: const BuiltInFieldSetting(enabled: false),
      });
      expect(config.numberLines, isTrue);
    });

    test('at most 50 rules are read', () {
      final config = FieldConfig.decode(jsonEncode({
        'version': 1,
        'custom': [
          for (var i = 0; i < 80; i++)
            {
              'id': '$i',
              'name': 'Rule $i',
              'phrases': ['p$i']
            },
        ],
      }));
      expect(config.custom, hasLength(FieldConfig.maxRules));
    });
  });

  group('the provider', () {
    test('loads, saves to one key, and resets', () async {
      final store = MemorySettingsStore({'fields': _everything.encode()});
      final notifier = FieldConfigNotifier(store);
      expect(notifier.state, _everything);

      final seat = rule('Seat', phrases: ['seat'], number: 5);
      await notifier.saveRule(seat);
      expect(FieldConfig.decode(store.values['fields']).custom.last, seat);
      await notifier.saveRule(seat.copyWith(name: 'Seat no.'));
      expect(notifier.state.custom.where((r) => r.id == seat.id).single.name,
          'Seat no.');
      await notifier.setRuleEnabled(seat.id, false);
      expect(notifier.state.custom.last.enabled, isFalse);
      await notifier.removeRule(seat.id);
      expect(notifier.state.custom.map((r) => r.id), isNot(contains(seat.id)));
      await notifier.setBuiltIn(
          BuiltInField.phone, const BuiltInFieldSetting(number: 1));
      await notifier.setNumberLines(true);
      expect(FieldConfigNotifier(store).state, notifier.state);

      await notifier.reset();
      expect(notifier.state, FieldConfig.defaults);
      expect(store.values['fields'], isNull);
    });

    test('corrupt settings load as the defaults without crashing', () {
      final store = MemorySettingsStore({'fields': '{"version":1,"custom":['});
      expect(FieldConfigNotifier(store).state, FieldConfig.defaults);
    });

    test('new pastes use the current config for titles and known secrets',
        () async {
      final locker = configWith([
        rule('Locker',
            phrases: ['locker code'], pattern: '[A-Z0-9]{5}', secret: true),
      ]);
      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(
            MemorySettingsStore({'fields': locker.encode()})),
        pasteStoreProvider.overrideWithValue(
            MemoryPasteStore([makeItem('Locker code - Q7Z9X', id: 'l')])),
      ]);
      addTearDown(container.dispose);
      final list = container.read(pasteListProvider.notifier);

      final secret = await list.addFromClipboard('Q7Z9X');
      expect(secret!.sensitive, isTrue,
          reason: 'it is a secret of another item under your rules');
      final titled = await list.addFromClipboard('Locker code: 88QQ7 for gym');
      expect(titled!.title, 'Locker code: •••••••• for gym');

      await container.read(fieldConfigProvider.notifier).reset();
      final plain = await list.addFromClipboard('Locker code: 99RR8');
      expect(plain!.title, 'Locker code: 99RR8');
    });
  });

  test('an always-hidden item whose title masked your secret stays hidden', () {
    final locker = configWith([
      rule('Locker', phrases: ['locker'], pattern: '[A-Z0-9]{5}', secret: true),
    ]);
    const content = 'Locker K7Q9X at the gym\nmore notes';
    final title = autoTitle(content, config: locker);
    expect(title, 'Locker •••••••• at the gym');
    final item = PasteItem(
      id: 'x',
      title: title,
      content: content,
      createdAt: DateTime(2026),
      sensitive: true,
    );
    // Even after the rule is gone, the title is recognized as generated.
    expect(hasAutoTitle(item), isTrue);
    expect(displayTitle(item, FieldExtractor.extract(content), hidden: true),
        'Hidden item');
    // A title the user typed is still shown (masked).
    expect(hasAutoTitle(item.copyWith(title: 'Gym •••• stuff')), isFalse);
    expect(hasAutoTitle(item.copyWith(title: 'Locker •••')), isFalse);

    // The length limit can cut the dots short.
    final long = '${'x' * 29} Locker K7Q9X and more';
    final cut = autoTitle(long, config: locker);
    expect(cut, endsWith('••…'));
    expect(
        hasAutoTitle(PasteItem(
            id: 'y', title: cut, content: long, createdAt: DateTime(2026))),
        isTrue);
  });
}
