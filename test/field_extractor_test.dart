import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/services/field_extractor.dart';

List<ExtractedField> fieldsOf(String text) =>
    FieldExtractor.extract(text).fields;

ExtractedField? fieldWith(String text, String value) {
  for (final f in fieldsOf(text)) {
    if (f.value == value) return f;
  }
  return null;
}

Matcher isField(FieldKind kind, {bool? secret, String? label}) =>
    predicate<ExtractedField?>(
      (f) =>
          f != null &&
          f.kind == kind &&
          (secret == null || f.secret == secret) &&
          (label == null || f.label == label),
      'a ${secret == true ? 'secret ' : ''}$kind field${label == null ? '' : ' labeled "$label"'}',
    );

void main() {
  group('labeled credentials', () {
    test('a typical login block keeps reading order and labels', () {
      const text = 'Netflix\nemail: me@example.com\npassword: hunter2!';
      final fields = fieldsOf(text);
      expect(fields.map((f) => f.value).toList(),
          ['me@example.com', 'hunter2!', 'Netflix']);
      expect(fields[0], isField(FieldKind.email));
      expect(fields[1],
          isField(FieldKind.password, secret: true, label: 'Password'));
      expect(fields[2], isField(FieldKind.line));
    });

    test('two labels on one line are split', () {
      const text = 'user: alice pass: s3cr3t!';
      expect(fieldWith(text, 'alice'), isField(FieldKind.username));
      expect(fieldWith(text, 's3cr3t!'),
          isField(FieldKind.password, secret: true));
    });

    test('a value cut at the next key loses its separator comma', () {
      const text = 'Password: hunter2, User: bob';
      expect(fieldWith(text, 'hunter2'),
          isField(FieldKind.password, secret: true));
      expect(fieldWith(text, 'bob'), isField(FieldKind.username));
    });

    test('Vietnamese labels', () {
      const text = 'tk: datdm mk: Abc@12345\nMật khẩu wifi: khongcho123';
      expect(fieldWith(text, 'datdm'),
          isField(FieldKind.username, label: 'Tài khoản'));
      expect(fieldWith(text, 'Abc@12345'),
          isField(FieldKind.password, secret: true));
      expect(fieldWith(text, 'khongcho123'),
          isField(FieldKind.password, secret: true));
    });

    test('"the password is X" phrasing', () {
      expect(fieldWith('Your temporary password is Xyz123.', 'Xyz123'),
          isField(FieldKind.password, secret: true));
      expect(fieldWith('mat khau la abc123', 'abc123'),
          isField(FieldKind.password, secret: true));
    });

    test('ordinary sentences are not credentials', () {
      final fields =
          fieldsOf('The password is incorrect. Your account is locked.');
      expect(fields.where((f) => f.secret), isEmpty);
      expect(fields.where((f) => f.kind == FieldKind.username), isEmpty);
    });

    test('words that merely contain a label are ignored', () {
      for (final text in [
        'bypass: true',
        'spin=3',
        'compass: north',
        'hotel: Hilton'
      ]) {
        final fields = fieldsOf(text);
        expect(fields.where((f) => f.secret), isEmpty, reason: text);
        expect(fields.where((f) => f.kind == FieldKind.phone), isEmpty,
            reason: text);
      }
    });

    test('placeholders are not secrets', () {
      for (final text in [
        'password: ******',
        'token: <your-token>',
        'Password: N/A'
      ]) {
        expect(fieldsOf(text).where((f) => f.secret), isEmpty, reason: text);
      }
    });

    test('label on its own line, value on the next', () {
      const text = 'Password\nXk9#mP2\$vL';
      expect(fieldWith(text, r'Xk9#mP2$vL'),
          isField(FieldKind.password, secret: true));
      expect(fieldsOf(text).where((f) => f.value == 'Password'), isEmpty);
    });

    test('a key that mentions a secret makes its value secret', () {
      expect(fieldWith('Wifi pass for guests: banana42', 'banana42'),
          isField(FieldKind.password, secret: true));
    });

    test('generic Key: value lines keep their key as the label', () {
      const text = 'Host: db.internal\nPort: 5432\nDatabase: orders';
      expect(fieldWith(text, 'db.internal'),
          isField(FieldKind.labeled, label: 'Host'));
      expect(
          fieldWith(text, '5432'), isField(FieldKind.labeled, label: 'Port'));
      expect(fieldWith(text, 'orders'),
          isField(FieldKind.labeled, label: 'Database'));
    });

    test('times are not keys', () {
      expect(fieldsOf('Meeting at 10:30 tomorrow').single.kind, FieldKind.line);
    });
  });

  group('one-time codes, PINs and cards', () {
    test('verification codes', () {
      expect(fieldWith('Your verification code is 482913.', '482913'),
          isField(FieldKind.otp, secret: true));
      expect(
          fieldWith('OTP: 1234', '1234'), isField(FieldKind.otp, secret: true));
      expect(fieldWith('G-482913 is your Google verification code', '482913'),
          isField(FieldKind.otp, secret: true));
      expect(fieldWith('123456 là mã xác thực của bạn', '123456'),
          isField(FieldKind.otp, secret: true));
    });

    test('PIN and CVV', () {
      expect(fieldWith('PIN: 4821', '4821'),
          isField(FieldKind.password, secret: true));
      expect(fieldWith('CVV 123', '123'),
          isField(FieldKind.password, secret: true));
    });

    test('valid card numbers are secret, invalid ones are not cards', () {
      final card = fieldWith('Card: 4242 4242 4242 4242', '4242424242424242');
      expect(card, isField(FieldKind.card, secret: true, label: 'Visa'));
      expect(
          fieldsOf('1234 5678 9012 3456')
              .where((f) => f.kind == FieldKind.card),
          isEmpty);
    });
  });

  group('links and addresses', () {
    test('URLs drop trailing punctuation and unbalanced brackets', () {
      expect(fieldWith('see (https://example.com/a).', 'https://example.com/a'),
          isField(FieldKind.url));
      expect(
          fieldWith('https://en.wikipedia.org/wiki/Foo_(bar)',
              'https://en.wikipedia.org/wiki/Foo_(bar)'),
          isField(FieldKind.url));
      expect(fieldWith('go to www.example.com, then log in', 'www.example.com'),
          isField(FieldKind.url));
    });

    test('a password inside a connection URL is its own secret field', () {
      const text = 'postgres://app:S3cret!@db.internal:5432/prod';
      expect(fieldWith(text, text), isField(FieldKind.url));
      expect(fieldWith(text, 'S3cret!'),
          isField(FieldKind.password, secret: true));
      final spans = FieldExtractor.extract(text).secretSpans;
      expect(spans.single, const Span(15, 22));
    });

    test('emails drop a trailing full stop and are not split out of URLs', () {
      expect(fieldWith('mail me at a@b.com.', 'a@b.com'),
          isField(FieldKind.email));
      expect(
          fieldWith('x a.b+c@mail.example.co.uk y', 'a.b+c@mail.example.co.uk'),
          isField(FieldKind.email));
      final fields = fieldsOf('https://user@host.example.com/path');
      expect(fields.where((f) => f.kind == FieldKind.email), isEmpty);
    });

    test('IPv4 addresses are IPs, not phone numbers', () {
      expect(fieldWith('server 192.168.100.200', '192.168.100.200'),
          isField(FieldKind.ip));
      expect(fieldWith('db at 10.0.0.1:5432.', '10.0.0.1:5432'),
          isField(FieldKind.ip));
      expect(fieldWith('version v1.2.3.4', '1.2.3.4'), isNull);
    });

    test('UUIDs', () {
      expect(
          fieldWith('request 123e4567-e89b-12d3-a456-426614174000',
              '123e4567-e89b-12d3-a456-426614174000'),
          isField(FieldKind.code, label: 'UUID'));
    });
  });

  group('numbers', () {
    test('phone number shapes', () {
      for (final phone in [
        '+84 912 345 678',
        '0912345678',
        '0912 345 678',
        '(555) 123-4567',
        '+1 555-123-4567',
        '555.123.4567',
      ]) {
        expect(fieldWith('call $phone today', phone), isField(FieldKind.phone),
            reason: phone);
      }
    });

    test('bare digit runs are not phone numbers', () {
      for (final text in ['ts=1731561600', '12345678', 'build 20241114']) {
        expect(fieldsOf(text).where((f) => f.kind == FieldKind.phone), isEmpty,
            reason: text);
      }
    });

    test('labeled reference numbers', () {
      expect(fieldWith('Order #12345678', '12345678'),
          isField(FieldKind.code, label: 'Order'));
      expect(fieldWith('Invoice: INV-2024-0042', 'INV-2024-0042'),
          isField(FieldKind.code, label: 'Invoice'));
      expect(
          fieldWith('Tracking number 1Z999AA10123456784', '1Z999AA10123456784'),
          isField(FieldKind.code));
      expect(fieldWith('SĐT: 0912 345 678', '0912 345 678'),
          isField(FieldKind.phone));
    });
  });

  group('tokens and keys', () {
    test('well-known token formats are secret', () {
      final samples = {
        'ghp_${'a' * 36}': 'GitHub token',
        'AKIAIOSFODNN7EXAMPLE': 'AWS key ID',
        'xoxb-123456789012-abcdefghij': 'Slack token',
        'sk_live_${'4' * 24}': 'Stripe key',
        'sk-ant-api03-${'x' * 30}': 'Anthropic key',
        'sk-proj-${'y' * 30}': 'API key',
        'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U':
            'JWT',
      };
      samples.forEach((token, label) {
        expect(fieldWith('key $token here', token),
            isField(FieldKind.token, secret: true, label: label),
            reason: label);
      });
    });

    test('bearer tokens and PEM private keys', () {
      expect(
          fieldWith('Authorization: Bearer abcdef1234567890ABCDEF',
              'abcdef1234567890ABCDEF'),
          isField(FieldKind.token, secret: true));
      const pem =
          '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAA\n-----END OPENSSH PRIVATE KEY-----';
      expect(fieldWith('my key:\n$pem', pem),
          isField(FieldKind.token, secret: true));
    });

    test('a password pasted on its own is recognized', () {
      for (final pw in [
        r'Xk9#mP2$vL',
        'Summer2024!',
        'P@ssw0rd',
        'aB3dE5fG7h'
      ]) {
        expect(fieldWith(pw, pw), isField(FieldKind.password, secret: true),
            reason: pw);
      }
    });

    test('identifiers and other single words are not passwords', () {
      for (final word in [
        'getUserById',
        'MyComponent2',
        'x86_64-linux-gnu',
        '2024-11-14T10:30:00Z',
        'Map<String,dynamic>',
        '/usr/local/bin'
      ]) {
        expect(fieldsOf(word).where((f) => f.secret), isEmpty, reason: word);
      }
    });
  });

  group('masking spans', () {
    test('every occurrence of a secret is masked', () {
      const text = 'pass: abcd1234\nreminder: the code is abcd1234';
      final extraction = FieldExtractor.extract(text);
      expect(extraction.secretSpans.length, 2);
      expect(extraction.secretValues, contains('abcd1234'));
    });

    test('a short PIN only masks where it was found', () {
      const text = 'PIN: 2024\nBorn in 2024';
      expect(FieldExtractor.extract(text).secretSpans.single, const Span(5, 9));
    });
  });

  group('limits and robustness', () {
    test('at most nine fields', () {
      final text = List.generate(20, (i) => 'line number $i').join('\n');
      expect(fieldsOf(text).length, FieldExtractor.maxFields);
    });

    test('detected fields come before fallback lines', () {
      const text = 'first line\nsecond line\nmail: x@y.dev';
      final kinds = fieldsOf(text).map((f) => f.kind).toList();
      expect(kinds.first, FieldKind.email);
      expect(kinds.skip(1), everyElement(FieldKind.line));
    });

    test('Windows line endings', () {
      const text = 'user: bob\r\npassword: hunter2!\r\n';
      expect(fieldWith(text, 'bob'), isField(FieldKind.username));
      expect(fieldWith(text, 'hunter2!'),
          isField(FieldKind.password, secret: true));
    });

    test('emoji do not break spans', () {
      const text = 'Meeting moved to 3pm 🎉 see you\npassword: 🎉party🎉2024';
      final extraction = FieldExtractor.extract(text);
      for (final f in extraction.fields) {
        expect(
            text.substring(f.span.start, f.span.end).contains(f.value) ||
                f.kind == FieldKind.card,
            isTrue);
      }
    });

    test('huge pastes are scanned quickly', () {
      final text =
          'password: hunter2!\n${'lorem ipsum dolor sit amet 0912 345 678 ' * 40000}';
      final watch = Stopwatch()..start();
      final extraction = FieldExtractor.extract(text);
      watch.stop();
      expect(extraction.fields, isNotEmpty);
      expect(watch.elapsedMilliseconds, lessThan(2000));
    });

    test('empty and whitespace-only content', () {
      expect(fieldsOf(''), isEmpty);
      expect(fieldsOf('   \n\t '), isEmpty);
    });
  });
  group('review fixes: detection', () {
    test('URL passwords containing @ # ? and an empty username', () {
      const tricky = 'postgres://admin:P@ss#123@db.example.com:5432/app';
      expect(fieldWith(tricky, 'P@ss#123'),
          isField(FieldKind.password, secret: true));
      expect(fieldWith('redis://:Sup3rSecret@cache:6379', 'Sup3rSecret'),
          isField(FieldKind.password, secret: true));
    });

    test('a secret written twice is masked both times', () {
      const text = 'Card: 4242 4242 4242 4242\nConfirm: 4242 4242 4242 4242\n'
          'PIN: 4821\nRe-enter PIN: 4821';
      final extraction = FieldExtractor.extract(text);
      for (final occurrence in ['4242 4242 4242 4242', '4821']) {
        var from = 0;
        while (true) {
          final at = text.indexOf(occurrence, from);
          if (at < 0) break;
          expect(
              extraction.secretSpans
                  .any((s) => s.start <= at && at + occurrence.length <= s.end),
              isTrue,
              reason: '"$occurrence" at $at should be masked');
          from = at + occurrence.length;
        }
      }
    });

    test('more ways of writing a password', () {
      final cases = {
        '{"password": "abc12345"}': 'abc12345',
        'Password for my email account: s3cret!': 's3cret!',
        'Mật khẩu tài khoản ngân hàng: Ab123456': 'Ab123456',
        'Password 2: hunter22': 'hunter22',
        'Secret: hunter2': 'hunter2',
        'pass - abc12345': 'abc12345',
        'mk wifi: khongcho1': 'khongcho1',
        'password for wifi is Summer2024!': 'Summer2024!',
        'Server=db;User Id=sa;Password=abc123;Database=prod': 'abc123',
        'Wifi (pass: abc12345)': 'abc12345',
      };
      cases.forEach((text, secret) {
        expect(fieldWith(text, secret)?.secret, isTrue, reason: text);
      });
    });

    test('a passphrase keeps all its words', () {
      expect(
          fieldWith('Passphrase: correct horse battery staple',
              'correct horse battery staple'),
          isField(FieldKind.password, secret: true));
    });

    test('ordinary sentences still are not passwords', () {
      for (final text in [
        'The password you entered is incorrect.',
        'Please pass the salt',
        'Secret: see below',
      ]) {
        expect(fieldsOf(text).where((f) => f.secret), isEmpty, reason: text);
      }
    });
  });

  group('review fixes: no slow patterns', () {
    final inputs = {
      'key: value + spaces': 'k: v${' ' * 19990}x',
      'password + spaces': 'password: x${' ' * 19985}y',
      'repeated pin': 'pin 1 ' * 3300,
      'repeated tel': 'tel 0 ' * 3300,
      'url + brackets': 'https://x.com/${')' * 19980}',
      'jwt fragments': '-eyJ' * 5000,
    };
    inputs.forEach((name, text) {
      test(name, () {
        final watch = Stopwatch()..start();
        FieldExtractor.extract(text);
        expect(watch.elapsedMilliseconds, lessThan(1500), reason: name);
      });
    });
  });
}
