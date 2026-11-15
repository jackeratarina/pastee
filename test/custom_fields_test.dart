import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/model/field_config.dart';
import 'package:pastee/services/custom_fields.dart';
import 'package:pastee/services/field_extractor.dart';

import 'support/field_helpers.dart';

void main() {
  group('phrases', () {
    test('ignore case, accents and extra spaces; đ is d', () {
      final config = configWith([
        rule('Password', phrases: ['mat khau']),
        rule('Order', phrases: ['Mã ĐƠN']),
        rule('Member', phrases: ['member   id']),
      ]);
      expect(valuesOf('Mật khẩu: abc123', config), {'Password': 'abc123'});
      expect(valuesOf('MAT  KHAU = xyz', config), {'Password': 'xyz'});
      expect(valuesOf('ma don: DH-1', config), {'Order': 'DH-1'});
      expect(valuesOf('Mã đơn: DH-2', config), {'Order': 'DH-2'});
      expect(valuesOf('MEMBER \t ID: 42', config), {'Member': '42'});
    });

    test('accents typed as combining marks still match', () {
      final config = configWith([
        rule('Password', phrases: ['mật khẩu'])
      ]);
      // "Mật khẩu" with every accent as a separate combining character.
      const decomposed = 'Mật khẩu: s3cret';
      expect(valuesOf(decomposed, config), {'Password': 's3cret'});
      final field = customField(run(decomposed, config), 'Password')!;
      expect(decomposed.substring(field.span.start, field.span.end), 's3cret');
    });

    test('every separator, or just a space', () {
      final config = configWith([
        rule('Seat', phrases: ['seat'])
      ]);
      for (final text in [
        'Seat: 12A',
        'Seat = 12A',
        'Seat - 12A',
        'Seat – 12A',
        'Seat — 12A',
        'Seat → 12A',
        'Seat > 12A',
        'Seat | 12A',
        'Seat：12A',
        'Seat -> 12A',
        'Seat => 12A',
        'Seat 12A',
        'Seat:12A',
        'Seat\t12A',
        'Seat : 12A',
      ]) {
        expect(valuesOf(text, config), {'Seat': '12A'}, reason: text);
      }
    });

    test('the value is the rest of the line, trimmed', () {
      final config = configWith([
        rule('Address', phrases: ['ship to'])
      ]);
      expect(valuesOf('Ship to:   12 Main St, Springfield   ', config),
          {'Address': '12 Main St, Springfield'});
    });

    test('nothing after the phrase: the next non-empty line', () {
      final config = configWith([
        rule('Member', phrases: ['member id'])
      ]);
      expect(valuesOf('Member ID\n\n   M-0042  \nsomething else', config),
          {'Member': 'M-0042'});
      expect(valuesOf('Member ID:\nM-0043', config), {'Member': 'M-0043'});
      // …unless that line is a label of its own.
      expect(valuesOf('Member ID:\nPassword: hunter2!', config), isEmpty);
      expect(valuesOf('Member ID:', config), isEmpty);
      // The heading line itself is not offered as a plain line.
      final e = run('Member ID\nM-0042\nsomething else', config);
      expect(numbered(e), [(1, 'M-0042'), (2, 'something else')]);
    });

    test('whole words only', () {
      final config = configWith([
        rule('Pin', phrases: ['pin']),
        rule('Ref', phrases: ['ref']),
      ]);
      expect(valuesOf('spin: 5', config), isEmpty);
      expect(valuesOf('pinned: 3', config), isEmpty);
      expect(valuesOf('prefix: abc', config), isEmpty);
      expect(valuesOf('my_pin: 7', config), isEmpty);
      expect(valuesOf('Your PIN: 4821', config), {'Pin': '4821'});
      expect(valuesOf('Ref: AB-1', config), {'Ref': 'AB-1'});
      // A phrase that starts or ends with a symbol only needs a boundary on
      // the word side.
      final hash = configWith([
        rule('Ticket', phrases: ['ticket #'])
      ]);
      expect(valuesOf('Ticket #4821', hash), {'Ticket': '4821'});
    });

    test('the longest phrase wins where two overlap', () {
      final config = configWith([
        rule('Short', phrases: ['code']),
        rule('Long', phrases: ['promo code']),
      ]);
      expect(valuesOf('Promo code: SAVE20', config), {'Long': 'SAVE20'});
      expect(valuesOf('Code: X1', config), {'Short': 'X1'});
    });

    test('a value stops at the next label on the same line', () {
      final config = configWith([
        rule('Member', phrases: ['member id'])
      ]);
      final e = run('Member ID: 12345, PIN: 9876', config);
      expect(customField(e, 'Member')!.value, '12345');
      expect(e.fields.where((f) => f.value == '9876').single.secret, isTrue);

      final two = configWith([
        rule('Member', phrases: ['member id']),
        rule('Seat', phrases: ['seat']),
      ]);
      expect(valuesOf('Member ID 77 seat 12A', two),
          {'Member': '77', 'Seat': '12A'});
      expect(valuesOf('Member ID\t77\tVIP', two), {'Member': '77'});
    });

    test('disabled rules find nothing', () {
      final config = configWith([
        rule('Seat', phrases: ['seat'], enabled: false)
      ]);
      expect(valuesOf('Seat: 12A', config), isEmpty);
    });

    test('lines over 2,000 characters are skipped', () {
      final config = configWith([
        rule('Seat', phrases: ['seat'])
      ]);
      final long = 'Seat: 12A ${'x' * CustomFields.maxLineLength}';
      expect(valuesOf(long, config), isEmpty);
      expect(valuesOf('$long\nSeat: 14C', config), {'Seat': '14C'});
    });
  });

  group('patterns', () {
    test('pattern only: every match, line by line', () {
      final config = configWith([rule('Customer', pattern: r'KH-\d+')]);
      final e = run('KH-1 and KH-22\nnothing\nalso KH-333 here', config);
      expect(
          e.fields.where((f) => f.kind == FieldKind.custom).map((f) => f.value),
          ['KH-1', 'KH-22', 'KH-333']);
    });

    test('phrase and pattern: the first match after the phrase', () {
      final config = configWith([
        rule('Member', phrases: ['member'], pattern: r'\d{4,}')
      ]);
      expect(valuesOf('Member: gold, since 2019, no. 123456', config),
          {'Member': '2019'});
      expect(valuesOf('Member: gold', config), isEmpty);
      // The pattern looks at the next line when the phrase line has nothing.
      expect(valuesOf('Member\n  card 5555 9999', config), {'Member': '5555'});
    });

    test('with a group, only the group is copied', () {
      final config =
          configWith([rule('Invoice', pattern: r'INV-(\d+)-[A-Z]{2}')]);
      final e = run('Paid INV-2024-VN today', config);
      final field = customField(e, 'Invoice')!;
      expect(field.value, '2024');
      expect(e.fields.length, greaterThanOrEqualTo(1));
      expect(
          'Paid INV-2024-VN today'.substring(field.span.start, field.span.end),
          '2024');
    });

    test('a group whose text occurs twice is masked wherever it could be', () {
      final config =
          configWith([rule('Code', pattern: r'(\d{3})-\1', secret: true)]);
      const text = 'ref 123-123 ok';
      final e = run(text, config);
      expect(customField(e, 'Code')!.value, '123');
      expect(isMaskedEverywhere(e, text, '123'), isTrue);
    });

    test('a pattern Pastee won\'t run finds nothing', () {
      final config = configWith([
        rule('Broken', pattern: '(unclosed'),
        rule('Huge', pattern: 'a' * 301),
      ]);
      expect(valuesOf('(unclosed ${'a' * 301}', config), isEmpty);
    });

    test('invalid without Unicode mode still works', () {
      // \- outside brackets is only allowed without Unicode mode.
      final config = configWith([rule('Code', pattern: r'AB\-\d+')]);
      expect(valuesOf('see AB-77', config), {'Code': 'AB-77'});
    });
  });

  group('your fields and built-in ones', () {
    test('your phrase beats built-in detection of the same text', () {
      final config = configWith([
        rule('Shop order', phrases: ['order'])
      ]);
      final e = run('Order #12345678', config);
      expect(e.fields.single.kind, FieldKind.custom);
      expect(e.fields.single.label, 'Shop order');
      expect(e.fields.single.value, '#12345678');
    });

    test('a secret rule masks every occurrence and is a known secret', () {
      final config = configWith([
        rule('Locker', phrases: ['locker'], secret: true)
      ]);
      const text = 'Locker: K7Q9X\nreminder: K7Q9X is on the fridge';
      final e = run(text, config);
      final field = customField(e, 'Locker')!;
      expect(field.secret, isTrue);
      expect(e.secretValues, contains('K7Q9X'));
      expect(isMaskedEverywhere(e, text, 'K7Q9X'), isTrue);
    });

    test('every match of a secret pattern is masked, even past the field cap',
        () {
      final config =
          configWith([rule('Voucher', pattern: r'V-\d{5}', secret: true)]);
      final codes = [for (var i = 0; i < 80; i++) 'V-${10000 + i}'];
      final text = codes.join('\n');
      final e = run(text, config);
      for (final code in codes) {
        expect(isMaskedEverywhere(e, text, code), isTrue, reason: code);
      }
    });

    test('a built-in secret inside your non-secret value stays masked', () {
      final config = configWith([rule('Database', pattern: r'postgres://\S+')]);
      const text = 'postgres://app:S3cret!@db.internal/prod';
      final e = run(text, config);
      expect(customField(e, 'Database')!.value, text);
      // The built-in password field gave way to yours, but not its mask.
      expect(e.fields.where((f) => f.value == 'S3cret!'), isEmpty);
      expect(isMaskedEverywhere(e, text, 'S3cret!'), isTrue);
    });

    test('a phrase inside a link or an email address is not a label', () {
      final config = configWith([
        rule('ID', phrases: ['id']),
        rule('Admin', phrases: ['admin']),
      ]);
      const text =
          'see https://shop.example.com/page?id=42 or admin@example.com';
      final e = run(text, config);
      expect(e.fields.where((f) => f.kind == FieldKind.custom), isEmpty);
      expect(e.fields.map((f) => f.value),
          ['https://shop.example.com/page?id=42', 'admin@example.com']);
    });

    test('a label inside a link does not cut your value short', () {
      final config = configWith([
        rule('Portal', phrases: ['portal'])
      ]);
      expect(valuesOf('Portal: https://x.example.com/login?user=me', config),
          {'Portal': 'https://x.example.com/login?user=me'});
    });

    test('your match inside a longer built-in field keeps both', () {
      final config = configWith([rule('Customer', pattern: r'KH-\d+')]);
      const text = 'Track it: https://shop.example.com/t/KH-1234';
      final e = run(text, config);
      expect(numbered(e), [
        (1, 'https://shop.example.com/t/KH-1234'),
        (2, 'KH-1234'),
      ]);
    });

    test('a value stops where a built-in label takes over', () {
      final config = configWith([
        rule('Wifi', phrases: ['wifi'])
      ]);
      final e = run('Wifi pass: banana42', config);
      expect(customField(e, 'Wifi'), isNull);
      expect(e.fields.single.value, 'banana42');
      expect(e.fields.single.secret, isTrue);
    });
  });

  group('folding', () {
    test('maps folded offsets back to the original', () {
      final folded = FoldedText.of('Ậy  ĐÓ\tﬁ\n🎉x');
      expect(folded.text, 'ay do fi\n🎉x');
      expect(folded.original(0), 0);
      expect(folded.original(3), 4); // "d" came from "Đ" after two spaces
      expect(folded.original(folded.text.length), 'Ậy  ĐÓ\tﬁ\n🎉x'.length);
    });
  });

  test('the config used is part of the cache key', () {
    const text = 'Seat: 12A';
    final none = FieldExtractor.extract(text);
    final some = FieldExtractor.extract(text,
        config: configWith([
          rule('Seat', phrases: ['seat'])
        ]));
    expect(none.fields.any((f) => f.kind == FieldKind.custom), isFalse);
    expect(customField(some, 'Seat')!.value, '12A');
    expect(identical(FieldExtractor.extract(text), none), isTrue);
  });

  test('BuiltInField names never change (they are saved)', () {
    expect(BuiltInField.values.map((f) => f.name), [
      'password',
      'pin',
      'card',
      'token',
      'username',
      'email',
      'link',
      'ip',
      'phone',
      'reference',
      'labeled',
    ]);
  });
}
