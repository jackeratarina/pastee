import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/model/field_config.dart';
import 'package:pastee/services/field_extractor.dart';

import 'support/field_helpers.dart';

const _off = BuiltInFieldSetting(enabled: false);
BuiltInFieldSetting _number(int n) => BuiltInFieldSetting(number: n);

/// Notes with a bit of everything, to compare configurations on.
final _corpus = [
  'Netflix\nemail: me@example.com\npassword: hunter2!',
  'user: alice pass: s3cr3t!',
  'tk: datdm mk: Abc@12345\nMật khẩu wifi: khongcho123',
  'Host: db.internal\nPort: 5432\nUser: admin\nPassword: P@ssw0rd!\n'
      'URL: postgres://admin:P@ssw0rd!@db.internal:5432/orders',
  'Card: 4242 4242 4242 4242\nCVV 123\nPIN: 4821\nRe-enter PIN: 4821',
  'Order #12345678\nInvoice: INV-2024-0042\nSĐT: 0912 345 678',
  'Your verification code is 482913.\nG-482913 is your Google verification code',
  'ghp_${'a' * 36}\nAKIAIOSFODNN7EXAMPLE\nsk_live_${'4' * 24}',
  '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n'
      '-----END OPENSSH PRIVATE KEY-----',
  List.generate(20, (i) => 'line number $i').join('\n'),
  'server 10.0.0.1\nrequest 123e4567-e89b-12d3-a456-426614174000',
  'Wifi pass for guests: banana42\n{"password": "abc12345"}',
  'pass: abcd1234\nreminder: the code is abcd1234',
  r'Xk9#mP2$vL',
  'Meeting at 10:30 tomorrow',
  '',
];

void main() {
  group('with no configuration nothing changes', () {
    test('numbers are 1, 2, 3… in the order fields come', () {
      for (final text in _corpus) {
        final fields = FieldExtractor.extract(text).fields;
        expect([
          for (final f in fields) f.number
        ], [
          for (var i = 1; i <= fields.length; i++) i
        ], reason: text);
      }
    });

    test('an equal or equivalent config gives exactly the default result', () {
      final equivalent = FieldConfig(
        custom: [
          rule('Off', phrases: ['netflix'], enabled: false)
        ],
        builtIn: {
          for (final field in BuiltInField.values)
            field: BuiltInFieldSetting.standard,
        },
      );
      for (final config in [FieldConfig(), equivalent]) {
        for (final text in _corpus) {
          final expected = FieldExtractor.extract(text);
          final actual = FieldExtractor.extract(text, config: config);
          expect(_describe(actual), _describe(expected), reason: text);
        }
      }
    });
  });

  group('numbers', () {
    const login = 'user: bob\nemail: a@b.co\nhttps://x.com';

    test('a kind asking for a number gets it; the rest fill in', () {
      expect(numbered(FieldExtractor.extract(login)),
          [(1, 'bob'), (2, 'a@b.co'), (3, 'https://x.com')]);
      final config = configWith([], builtIn: {BuiltInField.email: _number(3)});
      expect(numbered(run(login, config)),
          [(1, 'bob'), (2, 'https://x.com'), (3, 'a@b.co')]);
      expect(run(login, config).fieldNumbered(3)!.value, 'a@b.co');
    });

    test('chips are ordered by number, with gaps where nothing asked', () {
      final config = configWith([
        rule('Seat', phrases: ['seat'], number: 7)
      ]);
      expect(numbered(run('Seat: 12A\nemail a@b.co', config)),
          [(1, 'a@b.co'), (7, '12A')]);
    });

    test('two asking for one number: the first in the note wins', () {
      final config = configWith(
        [
          rule('Member', phrases: ['member'], number: 1)
        ],
        builtIn: {BuiltInField.email: _number(1)},
      );
      expect(numbered(run('a@b.co\nMember: 42', config)),
          [(1, 'a@b.co'), (2, '42')]);
      expect(numbered(run('Member: 42\na@b.co', config)),
          [(1, '42'), (2, 'a@b.co')]);
    });

    test('Auto fields take the lowest free numbers in reading order', () {
      final config = configWith([
        rule('A', phrases: ['alpha'], number: 1),
        rule('C', phrases: ['gamma'], number: 3),
      ]);
      const text = 'x@y.io\nbeta: 2\ngamma: 3\nalpha: 1\nfree line';
      expect(numbered(run(text, config)),
          [(1, '1'), (2, 'x@y.io'), (3, '3'), (4, '2'), (5, 'free line')]);
    });

    test('more than nine candidates never push out a fixed number', () {
      final emails = [for (var i = 1; i <= 12; i++) 'u$i@example.com'];
      final text = '${emails.join('\n')}\nHost: db.internal';
      // Without a number, the generic "Host" value doesn't make the cut.
      expect(FieldExtractor.extract(text).fields.map((f) => f.value),
          isNot(contains('db.internal')));
      final config =
          configWith([], builtIn: {BuiltInField.labeled: _number(9)});
      expect(numbered(run(text, config)), [
        for (var i = 1; i <= 8; i++) (i, 'u$i@example.com'),
        (9, 'db.internal'),
      ]);
    });

    test('your own fields come before built-in ones when space runs out', () {
      final text = [
        for (var i = 1; i <= 10; i++) 'u$i@example.com',
        'Member: M-1',
      ].join('\n');
      final config = configWith([
        rule('Member', phrases: ['member'])
      ]);
      final fields = run(text, config).fields;
      expect(fields, hasLength(9));
      expect(customField(run(text, config), 'Member')!.number, 9);
    });
  });

  group('turning kinds off', () {
    const note = 'Netflix\nemail: me@example.com\npassword: hunter2!';

    test('removes the chip and the number; plain lines fill in', () {
      expect(numbered(FieldExtractor.extract(note)),
          [(1, 'me@example.com'), (2, 'hunter2!'), (3, 'Netflix')]);
      final config = configWith([], builtIn: {BuiltInField.email: _off});
      expect(numbered(run(note, config)), [(1, 'hunter2!'), (2, 'Netflix')]);
    });

    test('a kind turned off is not offered as a plain line instead', () {
      final config = configWith([], builtIn: {BuiltInField.password: _off});
      final e = run(note, config);
      expect(numbered(e), [(1, 'me@example.com'), (2, 'Netflix')]);
      expect(e.fields.any((f) => f.value.contains('hunter2!')), isFalse);
    });

    test('secret kinds turned off are still masked, exactly as before', () {
      final config = configWith([], builtIn: {
        for (final field in BuiltInField.values)
          if (field.secret) field: _off,
      });
      for (final text in _corpus) {
        final normal = FieldExtractor.extract(text);
        final off = run(text, config);
        expect(off.secretSpans, normal.secretSpans, reason: text);
        expect(off.secretValues, normal.secretValues, reason: text);
        expect(off.fields.where((f) => f.secret), isEmpty, reason: text);
      }
      final e = run(note, config);
      expect(isMaskedEverywhere(e, note, 'hunter2!'), isTrue);
      expect(e.secretValues, contains('hunter2!'));
    });

    test('everything off', () {
      final config = configWith([], builtIn: {
        for (final field in BuiltInField.values) field: _off,
      }, numberLines: false);
      expect(run(note, config).fields, isEmpty);
      expect(run(note, config).hasSecrets, isTrue);
    });

    test('plain lines can be left unnumbered', () {
      final config = configWith([], numberLines: false);
      expect(numbered(run(note, config)),
          [(1, 'me@example.com'), (2, 'hunter2!')]);
    });

    test('which group each kind of field belongs to', () {
      final cases = <String, BuiltInField>{
        'password: hunter2!': BuiltInField.password,
        'PIN: 4821': BuiltInField.pin,
        'OTP: 123456': BuiltInField.pin,
        'CVV 123': BuiltInField.card,
        'Card: 4242 4242 4242 4242': BuiltInField.card,
        'API key: zzzz9999yyyy': BuiltInField.token,
        'ghp_${'a' * 36}': BuiltInField.token,
        'Prod token for CI: abcd1234efgh': BuiltInField.token,
        'user: alice': BuiltInField.username,
        'me@example.com': BuiltInField.email,
        'https://example.com': BuiltInField.link,
        '10.0.0.1': BuiltInField.ip,
        '0912 345 678': BuiltInField.phone,
        'Order #12345678': BuiltInField.reference,
        'Host: db.internal': BuiltInField.labeled,
      };
      cases.forEach((text, field) {
        final config = configWith([], builtIn: {field: _off});
        expect(FieldExtractor.extract(text).fields, isNotEmpty, reason: text);
        expect(run(text, config).fields.where((f) => f.kind != FieldKind.line),
            isEmpty,
            reason: '$text should be a ${field.name}');
      });
    });
  });
}

List<Object> _describe(Extraction e) => [
      [
        for (final f in e.fields)
          (f.number, f.kind, f.label, f.value, f.span, f.secret)
      ],
      e.secretSpans,
      e.secretValues.toList()..sort(),
    ];
