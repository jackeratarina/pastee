/// Finds copyable fields in a pasted note (passwords, usernames, links, codes,
/// phone numbers, …) and the character ranges that must be masked on screen.
///
/// Pure Dart, no Flutter imports, so it can be unit-tested in isolation.
library;

import 'dart:math' as math;

import '../model/field_config.dart';
import 'custom_fields.dart';

enum FieldKind {
  password,
  token,
  otp,
  card,
  username,
  email,
  url,
  ip,
  phone,
  code,
  labeled,
  line,

  /// Found by one of your own phrases or patterns.
  custom,
}

/// A half-open range `[start, end)` of UTF-16 offsets into the content.
final class Span {
  const Span(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start;

  bool overlaps(Span other) => start < other.end && other.start < end;

  @override
  bool operator ==(Object other) =>
      other is Span && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'Span($start, $end)';
}

final class ExtractedField {
  const ExtractedField({
    required this.kind,
    required this.label,
    required this.value,
    required this.span,
    required this.number,
    this.secret = false,
  });

  final FieldKind kind;

  /// Short human label: "Password", "Email", "Order", the key of a
  /// `Key: value` line such as "Host", or the name of your own field.
  final String label;

  /// What gets copied. For card numbers this is the digits without spaces.
  final String value;

  /// Where the field sits in the content.
  final Span span;

  /// 1–9: the field ⌘N / Ctrl+N copies. Unique within an extraction, but not
  /// always 1, 2, 3…: a field that asks for number 5 in Settings gets 5.
  final int number;

  /// Hidden behind dots unless the user reveals it.
  final bool secret;

  @override
  String toString() =>
      'ExtractedField($number, $kind, $label, "$value", secret: $secret)';
}

final class Extraction {
  const Extraction({
    required this.fields,
    required this.secretSpans,
    required this.secretValues,
  });

  static const empty =
      Extraction(fields: [], secretSpans: [], secretValues: <String>{});

  /// At most [FieldExtractor.maxFields] fields, in order of their numbers.
  /// With the default settings that is the detected fields in reading order,
  /// then plain lines as a fallback.
  final List<ExtractedField> fields;

  /// Sorted, non-overlapping ranges of the content to mask.
  final List<Span> secretSpans;

  /// The secret strings themselves, for masking text that is not the content
  /// (an auto-generated title, for example).
  final Set<String> secretValues;

  bool get hasSecrets => secretSpans.isNotEmpty;

  /// The field ⌘[number] copies, if there is one.
  ExtractedField? fieldNumbered(int number) {
    for (final field in fields) {
      if (field.number == number) return field;
    }
    return null;
  }
}

enum _Cat { password, pin, token, otp, cvv, username, phone, code }

final class _Candidate {
  _Candidate({
    required this.kind,
    required this.label,
    required this.value,
    required this.span,
    required this.priority,
    required BuiltInField this.builtIn,
    this.secret = false,
    this.group,
  }) : rule = null;

  _Candidate.custom({
    required CustomFieldRule this.rule,
    required this.value,
    required this.span,
  })  : kind = FieldKind.custom,
        label = rule.name,
        priority = _pCustom,
        secret = rule.secret,
        builtIn = null,
        group = null;

  final FieldKind kind;
  final String label;
  final String value;
  final Span span;
  final int priority;
  final bool secret;

  /// Which switch and number in Settings applies: a built-in kind, or (for
  /// your own fields) the rule that found it.
  final BuiltInField? builtIn;
  final CustomFieldRule? rule;

  /// Candidates of the same group may overlap: a database URL and the password
  /// inside it are both useful fields.
  final int? group;

  bool conflictsWith(_Candidate other) {
    if (!span.overlaps(other.span)) return false;
    if (group != null && group == other.group) return false;
    // One of your fields inside a longer built-in one, like a code inside a
    // link: both are useful. (The same text is yours alone.)
    if (rule != null && other.rule == null && other._holds(this)) return false;
    if (other.rule != null && rule == null && _holds(other)) return false;
    return true;
  }

  bool _holds(_Candidate inner) =>
      span.start <= inner.span.start &&
      inner.span.end <= span.end &&
      span.length > inner.span.length;

  ExtractedField toField(int number) => ExtractedField(
        kind: kind,
        label: label,
        value: value,
        span: span,
        number: number,
        secret: secret,
      );
}

/// What the built-in detectors find in one content, whatever the settings.
/// Masking comes from here alone (plus your own secret fields), so turning a
/// kind off can never unmask it.
final class _Analysis {
  _Analysis({
    required this.text,
    required this.candidates,
    required this.accepted,
    required this.values,
    required this.secretSpans,
    required this.secretValues,
  });

  /// The scanned part of the content, `\r` turned into spaces.
  final String text;

  /// Best first.
  final List<_Candidate> candidates;

  /// The candidates that don't overlap a better one or repeat its value.
  final List<_Candidate> accepted;
  final Set<String> values;

  /// Not merged yet.
  final List<Span> secretSpans;
  final Set<String> secretValues;

  // Only needed (and only worked out) when there are rules of your own.

  /// Links and email addresses, merged and sorted. A phrase inside one is
  /// part of the address ("?id=42", "admin@…"), not a label.
  late final List<(int, int)> addresses = [
    for (final span in FieldExtractor._merge([
      for (final c in candidates)
        if (c.builtIn == BuiltInField.link || c.builtIn == BuiltInField.email)
          c.span,
    ]))
      (span.start, span.end),
  ];

  /// Where a known label followed by ":" or "=" starts, outside addresses.
  late final List<int> labelStops = [
    for (final at in FieldExtractor._labelStops(text))
      if (!CustomFields.isInside(addresses, at)) at,
  ];
}

// Lower number wins when two candidates claim the same text. Your own fields
// beat built-in detection: they are what you asked for.
const _pCustom = -1;
const _pPrivateKey = 0;
const _pKnownToken = 1;
const _pLabeledSecret = 2;
const _pCard = 3;
const _pUrlPassword = 4;
const _pLabeledOther = 5;
const _pUrl = 6;
const _pEmail = 7;
const _pIp = 8;
const _pUuid = 9;
const _pPhone = 10;
const _pGeneric = 11;
const _pGuessedPassword = 12;

class FieldExtractor {
  FieldExtractor._();

  static const int maxFields = 9;

  /// Only the start of very large pastes is scanned; the rest is still stored
  /// and copied, it just isn't searched for fields.
  static const int scanLimit = 20000;

  /// At most this many fields come from one of your rules, however often it
  /// matches. (Every match of a secret rule is still masked.)
  static const int _maxPerRule = 50;

  static const int _cacheSize = 256;
  // Map literals are insertion-ordered, which makes these simple LRUs.
  static final _cache = <(FieldConfig, String), Extraction>{};
  static final _analyses = <String, _Analysis>{};

  /// Extracts fields from [content], with your own fields and numbers from
  /// [config] (the defaults if null). Results are memoized per config and
  /// content, so calling this from build methods and key handlers is cheap.
  static Extraction extract(String content, {FieldConfig? config}) {
    final key = (config ?? FieldConfig.defaults, content);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    final result = _run(content, key.$1);
    _cache[key] = result;
    if (_cache.length > _cacheSize) _cache.remove(_cache.keys.first);
    return result;
  }

  static Extraction _run(String content, FieldConfig config) {
    if (content.trim().isEmpty) return Extraction.empty;
    final analysis = _analyze(content);
    final text = analysis.text;
    final matches = config.activeRules.isEmpty
        ? const <CustomMatch>[]
        : CustomFields.find(text, config.custom,
            stops: analysis.labelStops, notLabels: analysis.addresses);

    // Which candidates become fields: your own first, then the built-in ones
    // by priority, skipping any that overlap one already taken.
    var accepted = analysis.accepted;
    var values = analysis.values;
    if (matches.isNotEmpty) {
      final custom = <_Candidate>[];
      final perRule = <int, int>{};
      for (final m in matches) {
        final count = perRule[m.ruleIndex] = (perRule[m.ruleIndex] ?? 0) + 1;
        if (count > _maxPerRule) continue;
        custom.add(_Candidate.custom(
            rule: m.rule, value: m.value, span: Span(m.start, m.end)));
      }
      accepted = [];
      values = {};
      for (final candidate in [...custom, ...analysis.candidates]) {
        if (accepted.any(candidate.conflictsWith)) continue;
        if (!values.add(candidate.value)) continue;
        accepted.add(candidate);
      }
    }

    // Masking: everything the built-in detectors mask, always, plus every
    // match of your own secret rules, masked the same way.
    final secretSpans = [...analysis.secretSpans];
    final secretValues = {...analysis.secretValues};
    for (final m in matches) {
      if (!m.rule.secret) continue;
      secretSpans.add(Span(m.start, m.end));
      for (final (start, end) in m.alsoMask) {
        secretSpans.add(Span(start, end));
      }
      if (secretValues.add(m.value)) {
        _maskOccurrences(text, m.value, FieldKind.custom, secretSpans);
      }
    }
    if (matches.isNotEmpty) {
      for (final c in accepted) {
        if (!c.secret && secretValues.contains(c.value)) {
          secretSpans.add(c.span);
        }
      }
    }

    // A kind that is turned off still holds its text (it isn't offered as a
    // plain line instead); it just gets no chip and no number.
    final numbered = _numbered(
      [
        for (final c in accepted)
          if (_isOn(c, config)) c
      ],
      (c) => _numberAskedFor(c, config),
    );
    final byNumber = <int, ExtractedField>{
      for (final entry in numbered.entries)
        entry.key: entry.value.toField(entry.key),
    };
    if (config.numberLines && byNumber.length < maxFields) {
      _fallbackLines(
        text,
        byNumber,
        [
          for (final c in accepted) c.span,
          // "Member ID" on its own line, with the value on the next one.
          for (final m in matches) Span(m.labelStart, m.labelEnd),
        ],
        {...values},
      );
    }
    final numbers = byNumber.keys.toList()..sort();

    return Extraction(
      fields: List.unmodifiable([for (final n in numbers) byNumber[n]!]),
      secretSpans: List.unmodifiable(_merge(secretSpans)),
      secretValues: Set.unmodifiable(secretValues),
    );
  }

  static bool _isOn(_Candidate c, FieldConfig config) {
    final builtIn = c.builtIn;
    return builtIn == null || config[builtIn].enabled;
  }

  static int? _numberAskedFor(_Candidate c, FieldConfig config) {
    final rule = c.rule;
    if (rule != null) return rule.number;
    return config[c.builtIn!].number;
  }

  /// Numbers the fields. [candidates] are best first.
  ///
  /// Fields that ask for a number get it first; when two ask for the same one,
  /// the one earlier in the note wins and the other is numbered automatically.
  /// The best of the rest then fill the free numbers in reading order, so a
  /// field with its own number is never pushed out by them.
  static Map<int, _Candidate> _numbered(
      List<_Candidate> candidates, int? Function(_Candidate) numberAskedFor) {
    final result = <int, _Candidate>{};
    final asking = [
      for (final c in candidates)
        if (numberAskedFor(c) != null) c
    ]..sort(_byPosition);
    final placed = <_Candidate>{};
    for (final c in asking) {
      final number = numberAskedFor(c)!;
      if (result.containsKey(number)) continue;
      result[number] = c;
      placed.add(c);
    }
    final rest = candidates
        .where((c) => !placed.contains(c))
        .take(maxFields - result.length)
        .toList()
      ..sort(_byPosition);
    var next = 1;
    for (final c in rest) {
      while (result.containsKey(next)) {
        next++;
      }
      result[next] = c;
    }
    return result;
  }

  static int _byPosition(_Candidate a, _Candidate b) {
    final byStart = a.span.start.compareTo(b.span.start);
    return byStart != 0 ? byStart : a.span.end.compareTo(b.span.end);
  }

  static _Analysis _analyze(String content) {
    final cached = _analyses.remove(content);
    if (cached != null) {
      _analyses[content] = cached;
      return cached;
    }
    final result = _detect(content);
    _analyses[content] = result;
    if (_analyses.length > _cacheSize) _analyses.remove(_analyses.keys.first);
    return result;
  }

  static _Analysis _detect(String content) {
    var text =
        content.length > scanLimit ? content.substring(0, scanLimit) : content;
    // Windows line endings: treat \r as a space so offsets stay identical to
    // the content while every pattern only has to think about \n.
    text = text.replaceAll('\r', ' ');

    final candidates = <_Candidate>[];
    var groupCounter = 0;
    int nextGroup() => ++groupCounter;

    _privateKeys(text, candidates);
    _knownTokens(text, candidates);
    _labeled(text, candidates);
    _labelOnPreviousLine(text, candidates);
    _cards(text, candidates);
    _urls(text, candidates, nextGroup);
    _emails(text, candidates);
    _ips(text, candidates);
    _uuids(text, candidates);
    _phones(text, candidates);
    _genericKeyValues(text, candidates);
    _quotedPairs(text, candidates);
    _guessedPasswords(text, candidates);

    candidates.sort((a, b) {
      final byPriority = a.priority.compareTo(b.priority);
      return byPriority != 0
          ? byPriority
          : a.span.start.compareTo(b.span.start);
    });

    final accepted = <_Candidate>[];
    final values = <String>{};
    // Secret candidates that did not become fields still have to be masked:
    // a second "PIN: 4821", the same card twice, or a longer secret that
    // overlaps a shorter accepted one.
    final hiddenSecrets = <_Candidate>[];
    for (final candidate in candidates) {
      final blockers = accepted.where(candidate.conflictsWith).toList();
      if (blockers.isNotEmpty) {
        if (candidate.secret && blockers.any((b) => b.secret)) {
          hiddenSecrets.add(candidate);
        }
        continue;
      }
      if (!values.add(candidate.value)) {
        if (candidate.secret) hiddenSecrets.add(candidate);
        continue;
      }
      accepted.add(candidate);
    }

    // Secrets are masked wherever they appear, even if only one occurrence
    // became a field.
    final secretSpans = <Span>[];
    final secretValues = <String>{};
    for (final c in [...accepted.where((c) => c.secret), ...hiddenSecrets]) {
      secretSpans.add(c.span);
      if (!secretValues.add(c.value)) continue; // other occurrences done
      _maskOccurrences(text, c.value, c.kind, secretSpans);
    }

    // A non-secret field whose value is also a secret is masked too.
    for (final c in accepted) {
      if (!c.secret && secretValues.contains(c.value)) secretSpans.add(c.span);
    }

    return _Analysis(
      text: text,
      candidates: candidates,
      accepted: accepted,
      values: values,
      secretSpans: secretSpans,
      secretValues: secretValues,
    );
  }

  /// Adds every occurrence of the secret [value] to [spans]. Short values (a
  /// 4-digit PIN) only mask the detected spot, or every "2024" in the note
  /// would turn into dots. So do card numbers, which are found in any spacing.
  static void _maskOccurrences(
      String text, String value, FieldKind kind, List<Span> spans) {
    final numeric = RegExp(r'^\d+$').hasMatch(value);
    if (value.length < (numeric ? 6 : 4) || kind == FieldKind.card) return;
    var from = 0;
    while (true) {
      final at = text.indexOf(value, from);
      if (at < 0) break;
      spans.add(Span(at, at + value.length));
      from = at + value.length;
    }
  }

  // ── private keys & well-known token formats ───────────────────────────────

  static final _pemKey = RegExp(
      r'-----BEGIN ((?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?)-----[\s\S]*?(?:-----END \1-----|$)');

  static void _privateKeys(String text, List<_Candidate> out) {
    for (final m in _pemKey.allMatches(text)) {
      out.add(_Candidate(
        kind: FieldKind.token,
        label: 'Private key',
        value: m.group(0)!,
        span: Span(m.start, m.end),
        priority: _pPrivateKey,
        builtIn: BuiltInField.token,
        secret: true,
      ));
    }
  }

  static final _tokenPatterns = <(RegExp, String)>[
    (RegExp(r'\bgithub_pat_[A-Za-z0-9_]{40,255}'), 'GitHub token'),
    (RegExp(r'\bgh[pousr]_[A-Za-z0-9]{36,255}\b'), 'GitHub token'),
    (RegExp(r'\bglpat-[A-Za-z0-9_-]{20,}'), 'GitLab token'),
    (RegExp(r'\b(?:AKIA|ASIA)[0-9A-Z]{16}\b'), 'AWS key ID'),
    (RegExp(r'\bxox[abposr]-[A-Za-z0-9-]{10,}'), 'Slack token'),
    (RegExp(r'\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}\b'), 'Stripe key'),
    (RegExp(r'\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])'), 'Google API key'),
    (RegExp(r'\bsk-ant-[A-Za-z0-9_-]{20,}'), 'Anthropic key'),
    (
      RegExp(r'\bsk-(?!ant-)(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}'),
      'API key'
    ),
    (RegExp(r'\bnpm_[A-Za-z0-9]{36}\b'), 'npm token'),
    (RegExp(r'\bhf_[A-Za-z0-9]{30,}\b'), 'Hugging Face token'),
    (RegExp(r'\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}'), 'SendGrid key'),
    (
      RegExp(
          r'(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'),
      'JWT'
    ),
  ];

  static final _bearer = RegExp(r'\bBearer[ \t]+([A-Za-z0-9._~+/-]{16,}=*)');

  static void _knownTokens(String text, List<_Candidate> out) {
    for (final (pattern, label) in _tokenPatterns) {
      for (final m in pattern.allMatches(text)) {
        out.add(_Candidate(
          kind: FieldKind.token,
          label: label,
          value: m.group(0)!,
          span: Span(m.start, m.end),
          priority: _pKnownToken,
          builtIn: BuiltInField.token,
          secret: true,
        ));
      }
    }
    for (final m in _bearer.allMatches(text)) {
      final value = m.group(1)!;
      final start = m.end - value.length;
      out.add(_Candidate(
        kind: FieldKind.token,
        label: 'Bearer token',
        value: value,
        span: Span(start, m.end),
        priority: _pKnownToken,
        builtIn: BuiltInField.token,
        secret: true,
      ));
    }
  }

  // ── labeled values: "Password: …", "tk: … mk: …", "Order #123" ────────────

  /// Normalized label → category and display label. Keys are lower case with
  /// single spaces; "api key" also matches "api_key", "api-key" and "apikey".
  static const Map<String, (_Cat, String)> _labels = {
    // passwords
    'password': (_Cat.password, 'Password'),
    'passwd': (_Cat.password, 'Password'),
    'pwd': (_Cat.password, 'Password'),
    'pass': (_Cat.password, 'Password'),
    'pw': (_Cat.password, 'Password'),
    'passcode': (_Cat.password, 'Passcode'),
    'passphrase': (_Cat.password, 'Passphrase'),
    'mật khẩu': (_Cat.password, 'Mật khẩu'),
    'mat khau': (_Cat.password, 'Mật khẩu'),
    'mk': (_Cat.password, 'Mật khẩu'),
    // PINs
    'pin': (_Cat.pin, 'PIN'),
    'pin code': (_Cat.pin, 'PIN'),
    'mã pin': (_Cat.pin, 'PIN'),
    'ma pin': (_Cat.pin, 'PIN'),
    // keys & tokens
    'secret': (_Cat.token, 'Secret'),
    'client secret': (_Cat.token, 'Client secret'),
    'secret key': (_Cat.token, 'Secret key'),
    'secret access key': (_Cat.token, 'Secret key'),
    'api key': (_Cat.token, 'API key'),
    'access key': (_Cat.token, 'Access key'),
    'access token': (_Cat.token, 'Access token'),
    'refresh token': (_Cat.token, 'Refresh token'),
    'auth token': (_Cat.token, 'Auth token'),
    'token': (_Cat.token, 'Token'),
    'private key': (_Cat.token, 'Private key'),
    'license key': (_Cat.token, 'License key'),
    'recovery code': (_Cat.token, 'Recovery code'),
    'recovery key': (_Cat.token, 'Recovery key'),
    'backup code': (_Cat.token, 'Backup code'),
    // one-time codes
    'otp': (_Cat.otp, 'OTP'),
    '2fa': (_Cat.otp, '2FA code'),
    '2fa code': (_Cat.otp, '2FA code'),
    'mfa code': (_Cat.otp, 'MFA code'),
    'verification code': (_Cat.otp, 'Verification code'),
    'security code': (_Cat.otp, 'Security code'),
    'one time code': (_Cat.otp, 'One-time code'),
    'one time password': (_Cat.otp, 'One-time code'),
    'login code': (_Cat.otp, 'Login code'),
    'auth code': (_Cat.otp, 'Auth code'),
    'mã otp': (_Cat.otp, 'OTP'),
    'ma otp': (_Cat.otp, 'OTP'),
    'mã xác thực': (_Cat.otp, 'Mã xác thực'),
    'ma xac thuc': (_Cat.otp, 'Mã xác thực'),
    'mã xác nhận': (_Cat.otp, 'Mã xác nhận'),
    'ma xac nhan': (_Cat.otp, 'Mã xác nhận'),
    // card security codes
    'cvv': (_Cat.cvv, 'CVV'),
    'cvv2': (_Cat.cvv, 'CVV'),
    'cvc': (_Cat.cvv, 'CVC'),
    // usernames
    'username': (_Cat.username, 'Username'),
    'user name': (_Cat.username, 'Username'),
    'user': (_Cat.username, 'Username'),
    'login': (_Cat.username, 'Login'),
    'login id': (_Cat.username, 'Login'),
    'user id': (_Cat.username, 'User ID'),
    'userid': (_Cat.username, 'User ID'),
    'account': (_Cat.username, 'Account'),
    'account name': (_Cat.username, 'Account'),
    'tài khoản': (_Cat.username, 'Tài khoản'),
    'tai khoan': (_Cat.username, 'Tài khoản'),
    'tk': (_Cat.username, 'Tài khoản'),
    'tên đăng nhập': (_Cat.username, 'Tên đăng nhập'),
    'ten dang nhap': (_Cat.username, 'Tên đăng nhập'),
    // phone numbers
    'phone': (_Cat.phone, 'Phone'),
    'phone number': (_Cat.phone, 'Phone'),
    'tel': (_Cat.phone, 'Phone'),
    'telephone': (_Cat.phone, 'Phone'),
    'mobile': (_Cat.phone, 'Mobile'),
    'cell': (_Cat.phone, 'Mobile'),
    'hotline': (_Cat.phone, 'Hotline'),
    'whatsapp': (_Cat.phone, 'WhatsApp'),
    'zalo': (_Cat.phone, 'Zalo'),
    'sđt': (_Cat.phone, 'SĐT'),
    'sdt': (_Cat.phone, 'SĐT'),
    'số điện thoại': (_Cat.phone, 'SĐT'),
    'so dien thoai': (_Cat.phone, 'SĐT'),
    'điện thoại': (_Cat.phone, 'SĐT'),
    'dien thoai': (_Cat.phone, 'SĐT'),
    // reference numbers
    'order': (_Cat.code, 'Order'),
    'order id': (_Cat.code, 'Order'),
    'order no': (_Cat.code, 'Order'),
    'order number': (_Cat.code, 'Order'),
    'invoice': (_Cat.code, 'Invoice'),
    'invoice no': (_Cat.code, 'Invoice'),
    'invoice number': (_Cat.code, 'Invoice'),
    'ticket': (_Cat.code, 'Ticket'),
    'ref': (_Cat.code, 'Ref'),
    'reference': (_Cat.code, 'Ref'),
    'booking': (_Cat.code, 'Booking'),
    'booking ref': (_Cat.code, 'Booking'),
    'booking code': (_Cat.code, 'Booking'),
    'confirmation': (_Cat.code, 'Confirmation'),
    'confirmation code': (_Cat.code, 'Confirmation'),
    'confirmation number': (_Cat.code, 'Confirmation'),
    'tracking': (_Cat.code, 'Tracking'),
    'tracking number': (_Cat.code, 'Tracking'),
    'tracking code': (_Cat.code, 'Tracking'),
    'account number': (_Cat.code, 'Account no.'),
    'account no': (_Cat.code, 'Account no.'),
    'serial': (_Cat.code, 'Serial'),
    'serial number': (_Cat.code, 'Serial'),
    'id': (_Cat.code, 'ID'),
    'mã đơn': (_Cat.code, 'Mã đơn'),
    'ma don': (_Cat.code, 'Mã đơn'),
    'mã đơn hàng': (_Cat.code, 'Mã đơn'),
    'ma don hang': (_Cat.code, 'Mã đơn'),
    'mã vận đơn': (_Cat.code, 'Mã vận đơn'),
    'ma van don': (_Cat.code, 'Mã vận đơn'),
    'số tài khoản': (_Cat.code, 'Số tài khoản'),
    'so tai khoan': (_Cat.code, 'Số tài khoản'),
    'stk': (_Cat.code, 'Số tài khoản'),
  };

  static final RegExp _labelRe = () {
    final words = _labels.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final alternation = words.map((w) => w.split(' ').join('[ _-]?')).join('|');
    return RegExp('(?<![\\p{L}\\p{N}_])(?:$alternation)(?![\\p{L}\\p{N}_])',
        caseSensitive: false, unicode: true);
  }();

  static final _strongSep = RegExp(r'^[ \t]*[:=：][ \t]*');
  static final _proseSep =
      RegExp(r'^[ \t]+(?:is|là|la)[ \t]+', caseSensitive: false, unicode: true);
  static final _proseFillerSep = RegExp(
      r'^(?:[ \t]+[\p{L}\p{N}-]+){1,3}?[ \t]+(?:is|là|la)[ \t]+',
      caseSensitive: false,
      unicode: true);
  static final _dashSep = RegExp(r'^[ \t]+[-–—][ \t]+');
  static final _bareSep =
      RegExp(r'''^[ \t]+(?=[^\s"'“”‘’`()\[\]{}<>:=：]+[ \t]*$)''');
  static final _hashSep =
      RegExp(r'^[ \t]*(?:#|no\.|nr\.|number)[ \t]*', caseSensitive: false);
  static final _spaceSep = RegExp(r'^[ \t]+(?=[0-9+(#])');

  static final _strongSepAfter = RegExp(r'[ \t]*[:=：]');

  /// "… PIN: 4821": where each known label with a ":" or "=" after it
  /// starts, so a value of your own on the same line stops before it.
  static List<int> _labelStops(String text) => [
        for (final m in _labelRe.allMatches(text))
          if (_strongSepAfter.matchAsPrefix(text, m.end) != null &&
              _lookupLabel(m.group(0)!) != null)
            m.start,
      ];

  static String _normalizeLabel(String raw) =>
      raw.toLowerCase().replaceAll(RegExp(r'[ _-]+'), ' ').trim();

  static (_Cat, String)? _lookupLabel(String raw) {
    final normalized = _normalizeLabel(raw);
    return _labels[normalized] ?? _labels[normalized.replaceAll(' ', '')];
  }

  static void _labeled(String text, List<_Candidate> out) {
    for (final m in _labelRe.allMatches(text)) {
      final entry = _lookupLabel(m.group(0)!);
      if (entry == null) continue;
      final (cat, label) = entry;
      final lineEnd = math.min(_lineEnd(text, m.end), m.end + 512);
      final after = text.substring(m.end, lineEnd);

      Match? sep = _strongSep.firstMatch(after);
      var prose = false;
      var strict = false; // weak separator: the value must look like a password
      if (sep == null) {
        sep = _proseSep.firstMatch(after);
        prose = sep != null;
      }
      if (sep == null) {
        sep = _proseFillerSep.firstMatch(after);
        prose = strict = sep != null;
      }
      if (sep == null && cat == _Cat.password) {
        // "pass - abc123", "pw abc123", "mk abc123"
        sep = _dashSep.firstMatch(after) ?? _bareSep.firstMatch(after);
        strict = sep != null;
      }
      if (sep == null && cat == _Cat.code) sep = _hashSep.firstMatch(after);
      if (sep == null &&
          (cat == _Cat.code ||
              cat == _Cat.phone ||
              cat == _Cat.otp ||
              cat == _Cat.pin ||
              cat == _Cat.cvv)) {
        sep = _spaceSep.firstMatch(after);
      }
      if (sep == null) continue;

      final valueStart = m.end + sep.end;
      if (label == 'Passphrase') {
        final phrase = _wholeValue(text, valueStart, lineEnd);
        if (phrase != null) {
          out.add(_candidateFor(cat, label, phrase.$1, phrase.$2));
        }
        continue;
      }
      final parsed = _parseValue(text, valueStart, lineEnd, cat, prose: prose);
      if (parsed == null) continue;
      if (strict &&
          (cat == _Cat.password || cat == _Cat.token) &&
          !_looksLikePassword(parsed.$1)) {
        continue;
      }
      out.add(_candidateFor(cat, label, parsed.$1, parsed.$2));
    }
    // SMS style, code first: "482913 is your Instagram code".
    for (final m in _otpBeforeLabel.allMatches(text)) {
      final digits = m.group(1)!;
      final start = m.start + m.group(0)!.indexOf(digits);
      out.add(_Candidate(
        kind: FieldKind.otp,
        label: 'OTP',
        value: digits,
        span: Span(start, start + digits.length),
        priority: _pLabeledSecret,
        builtIn: BuiltInField.pin,
        secret: true,
      ));
    }
  }

  static final _otpBeforeLabel = RegExp(
    r'(?<![\w-])(?:[A-Z]-)?(\d{4,8})(?!\d)[ \t]+(?:is[ \t]+(?:your|the)|là[ \t]+mã)[ \t]+(?:[\p{L}\p{N}-]+[ \t]+){0,4}?(?:code|otp|pin|passcode|password|xác thực|xác nhận)(?![\p{L}])',
    caseSensitive: false,
    unicode: true,
  );

  /// "Password" on one line and the value alone on the next.
  static void _labelOnPreviousLine(String text, List<_Candidate> out) {
    final lines = _lines(text);
    for (var i = 0; i < lines.length - 1; i++) {
      final (start, end) = lines[i];
      var head = text.substring(start, end).trim();
      head = head.replaceFirst(RegExp(r'^[-*•·>]+\s*'), '');
      if (head.endsWith(':') || head.endsWith('：')) {
        head = head.substring(0, head.length - 1).trimRight();
      }
      if (head.isEmpty || head.length > 30) continue;
      final entry = _lookupLabel(head);
      if (entry == null) continue;

      final (nextStart, nextEnd) = lines[i + 1];
      final nextLine = text.substring(nextStart, nextEnd);
      if (nextLine.trim().isEmpty || _looksLikeKeyValue.hasMatch(nextLine)) {
        continue;
      }
      final (cat, label) = entry;
      final parsed = _parseValue(text, nextStart, nextEnd, cat, prose: false);
      if (parsed == null) continue;
      // Only the whole line counts as the value, not just its first word.
      if (parsed.$1.trim() != nextLine.trim()) continue;
      out.add(_candidateFor(cat, label, parsed.$1, parsed.$2));
    }
  }

  static _Candidate _candidateFor(
      _Cat cat, String label, String value, Span span) {
    final (kind, priority, secret) = switch (cat) {
      _Cat.password || _Cat.pin => (FieldKind.password, _pLabeledSecret, true),
      _Cat.token => (FieldKind.token, _pLabeledSecret, true),
      _Cat.otp => (FieldKind.otp, _pLabeledSecret, true),
      _Cat.cvv => (FieldKind.password, _pLabeledSecret, true),
      _Cat.username => (FieldKind.username, _pLabeledOther, false),
      _Cat.phone => (FieldKind.phone, _pLabeledOther, false),
      _Cat.code => (FieldKind.code, _pLabeledOther, false),
    };
    return _Candidate(
      kind: kind,
      label: label,
      value: value,
      span: span,
      priority: priority,
      builtIn: _fieldOf(cat),
      secret: secret,
    );
  }

  /// The Settings group a labeled value belongs to.
  static BuiltInField _fieldOf(_Cat cat) => switch (cat) {
        _Cat.password => BuiltInField.password,
        _Cat.pin || _Cat.otp => BuiltInField.pin,
        _Cat.cvv => BuiltInField.card,
        _Cat.token => BuiltInField.token,
        _Cat.username => BuiltInField.username,
        _Cat.phone => BuiltInField.phone,
        _Cat.code => BuiltInField.reference,
      };

  static final _cellBreak = RegExp(r'\t| \| | \|\| ');
  static final _valueEndingSemicolon = RegExp(r';(?=\s*[A-Za-z][\w ]*=|$)');
  static final _quoted = RegExp('^(["\'`“‘])(.+?)(["\'`”’])');
  static final _firstToken = RegExp(r'^\S+');
  static final _pinValue = RegExp(r'^\d{4,8}(?!\d)');
  static final _cvvValue = RegExp(r'^\d{3,4}(?!\d)');
  static final _otpValue =
      RegExp(r'^(?:[A-Za-z]{1,3}-)?(\d{4,10})(?![0-9A-Za-z])');
  static final _phoneValue = RegExp(r'^\+?\(?\d[\d \t().-]{5,22}\d');
  static final _codeValue =
      RegExp(r'^#?[ \t]*([A-Za-z0-9](?:[A-Za-z0-9._/-]{0,38}[A-Za-z0-9])?)');
  static final _schemeStart = RegExp(r'^(?:[a-zA-Z][a-zA-Z0-9+.-]*://|www\.)');
  static final _placeholder = RegExp(
    r'^(?:none|null|nil|n/?a|tbd|todo|unknown|empty|hidden|redacted|your[-_ ]?\w*|[x*•.?_-]+)$',
    caseSensitive: false,
  );
  static final _bracketed = RegExp(r'^[<\[{(].*[>\]})]$');
  static final _looksLikeKeyValue =
      RegExp(r'^\s*[\p{L}][\p{L}\p{N} ._-]{0,30}[:：=]\s', unicode: true);
  static final _nextKey = RegExp(
      r'(?<![ \t])[ \t]+[\p{L}][\p{L}\p{N} _-]{0,24}[:=：]',
      unicode: true);

  /// Parses the value that starts at [start] on a line ending at [lineEnd].
  /// Returns the value and its span, or null if it doesn't fit the category.
  static (String, Span)? _parseValue(
    String text,
    int start,
    int lineEnd,
    _Cat cat, {
    required bool prose,
  }) {
    var region = text.substring(start, lineEnd);
    var wasCut = false;
    // "user: a pass: b" — stop at the next key on the same line.
    final next = _nextKey.firstMatch(region);
    if (next != null && next.start > 0) {
      region = region.substring(0, next.start);
      wasCut = true;
    }
    final cutAt = region.indexOf(_cellBreak);
    if (cutAt > 0) {
      region = region.substring(0, cutAt);
      wasCut = true;
    }
    final leading = region.length - region.trimLeft().length;
    region = region.trim();
    if (region.isEmpty) return null;
    final base = start + leading;

    (String, Span)? at(int offset, String value) => value.isEmpty
        ? null
        : (value, Span(base + offset, base + offset + value.length));

    String stripTrailing(String value, {required bool moreFollows}) {
      if (prose) return value.replaceFirst(RegExp(r'[.,;]$'), '');
      if (moreFollows) return value.replaceFirst(RegExp(r'[,;]$'), '');
      return value;
    }

    switch (cat) {
      case _Cat.password || _Cat.token || _Cat.username:
        final quoted = _quoted.firstMatch(region);
        String value;
        int offset;
        if (quoted != null) {
          value = quoted.group(2)!;
          offset = 1;
        } else {
          final token = _firstToken.firstMatch(region)!.group(0)!;
          value = stripTrailing(token,
              moreFollows: wasCut || token.length < region.length);
          // Connection strings: "Password=abc;Database=prod" or "pwd=abc;".
          final semicolon = _valueEndingSemicolon.firstMatch(value);
          if (semicolon != null) value = value.substring(0, semicolon.start);
          // "(pass: abc123)": the closing bracket belongs to the sentence.
          if (value.endsWith(')') &&
              '('.allMatches(value).length < ')'.allMatches(value).length) {
            value = value.substring(0, value.length - 1);
          }
          offset = 0;
        }
        if (value.isEmpty || value.length > 200) return null;
        if (_placeholder.hasMatch(value) || _bracketed.hasMatch(value)) {
          return null;
        }
        if (prose && !_looksLikeCredential(value)) return null;
        if (cat == _Cat.token &&
            value.length < 8 &&
            !_looksLikePassword(value)) {
          return null;
        }
        if (cat == _Cat.username &&
            (_schemeStart.hasMatch(value) || value.length > 100)) {
          return null;
        }
        return at(offset, value);
      case _Cat.pin:
        final m = _pinValue.firstMatch(region);
        return m == null ? null : at(0, m.group(0)!);
      case _Cat.cvv:
        final m = _cvvValue.firstMatch(region);
        return m == null ? null : at(0, m.group(0)!);
      case _Cat.otp:
        final m = _otpValue.firstMatch(region);
        if (m == null) return null;
        final digits = m.group(1)!;
        return at(m.end - digits.length, digits);
      case _Cat.phone:
        final m = _phoneValue.firstMatch(region);
        if (m == null) return null;
        final digitCount = m.group(0)!.replaceAll(RegExp(r'\D'), '').length;
        if (digitCount < 7 || digitCount > 15) return null;
        return at(0, m.group(0)!);
      case _Cat.code:
        final m = _codeValue.firstMatch(region);
        if (m == null) return null;
        final value = m.group(1)!;
        if (value.length < 3 || !value.contains(RegExp(r'\d'))) return null;
        return at(m.end - value.length, value);
    }
  }

  /// Mixes letters and digits, or has a symbol: "abc123" or "hunter2!", not
  /// "2", "2024", "yes" or "see".
  static bool _looksLikePassword(String v) =>
      v.length >= 4 &&
      ((v.contains(RegExp(r'\p{L}', unicode: true)) &&
              v.contains(RegExp(r'\d'))) ||
          v.contains(RegExp(r'[^\p{L}\p{N}]', unicode: true)));

  /// For "the password is …" phrasing, require something that doesn't read
  /// like an ordinary word ("is incorrect", "is locked").
  static bool _looksLikeCredential(String value) {
    if (value.contains(RegExp(r'\d'))) return true;
    if (value.contains(RegExp(r'[^\p{L}\p{N}]', unicode: true))) return true;
    return value.length > 1 && value.substring(1).contains(RegExp(r'[A-Z]'));
  }

  // ── generic "Key: value" lines ─────────────────────────────────────────────

  static final _keyValueLine = RegExp(
    r'^[ \t]*(?:[-*•·>]+[ \t]*)?([\p{L}][\p{L}\p{N} ._/()\[\]#&\x27-]{0,30}?)[ \t]*[:：=][ \t]*(\S[^\n]*)$',
    multiLine: true,
    unicode: true,
  );
  static final _secretWords = RegExp(
    r'(?<![\p{L}])(?:password|passwd|pwd|pass|passcode|secret|token|api[ _-]?key|private[ _-]?key|pin|otp|mật khẩu|mat khau|mk|pw|passphrase|cvv|cvc|mã pin|ma pin|mã bảo mật|ma bao mat|seed phrase|recovery phrase|mnemonic|(?:wifi|wi-fi|network|security|wpa2?) key)(?![\p{L}])',
    caseSensitive: false,
    unicode: true,
  );
  static final _usernameWords = RegExp(
    r'(?<![\p{L}])(?:username|user|login|account|tài khoản|tai khoan)(?![\p{L}])',
    caseSensitive: false,
    unicode: true,
  );

  static final _phraseWords = RegExp(
    r'(?<![\p{L}])(?:passphrase|seed phrase|recovery phrase|secret phrase|mnemonic)(?![\p{L}])',
    caseSensitive: false,
    unicode: true,
  );

  static final _cardSecretWords = RegExp(r'(?<![\p{L}])(?:cvv|cvc)(?![\p{L}])',
      caseSensitive: false, unicode: true);
  static final _codeSecretWords = RegExp(
      r'(?<![\p{L}])(?:pin|otp|mã pin|ma pin|mã bảo mật|ma bao mat)(?![\p{L}])',
      caseSensitive: false,
      unicode: true);
  static final _tokenSecretWords = RegExp(
      r'(?<![\p{L}])(?:secret|token|api[ _-]?key|private[ _-]?key)(?![\p{L}])',
      caseSensitive: false,
      unicode: true);

  /// The Settings group of a secret whose key isn't a known label: "Wifi
  /// pass for guests" is a password, "Prod token for CI" a token.
  static BuiltInField _secretKeyField(String key) {
    if (_cardSecretWords.hasMatch(key)) return BuiltInField.card;
    if (_codeSecretWords.hasMatch(key)) return BuiltInField.pin;
    if (_tokenSecretWords.hasMatch(key)) return BuiltInField.token;
    return BuiltInField.password;
  }

  /// A multi-word secret: the rest of the value, without quotes.
  static (String, Span)? _wholeValue(String text, int start, int end) {
    final raw = text.substring(start, end);
    final quoted = _quoted.firstMatch(raw.trimLeft());
    final lead = raw.length - raw.trimLeft().length;
    if (quoted != null) {
      final v = quoted.group(2)!;
      return (v, Span(start + lead + 1, start + lead + 1 + v.length));
    }
    final v = raw.trim();
    if (v.isEmpty || v.length > 300 || _placeholder.hasMatch(v)) return null;
    return (v, Span(start + lead, start + lead + v.length));
  }

  static void _genericKeyValues(String text, List<_Candidate> out) {
    for (final m in _keyValueLine.allMatches(text)) {
      final key = m.group(1)!.trim();
      var value = m.group(2)!.trimRight();
      final secretKey = _secretWords.hasMatch(key);
      if (key.length < 2 ||
          key.split(RegExp(r'\s+')).length > (secretKey ? 8 : 4)) {
        continue;
      }
      if (!secretKey && RegExp(r'\d$').hasMatch(key)) continue; // "at 10:30"
      if (value.startsWith('//')) continue; // "https://…" split at its colon
      if (_lookupLabel(key) != null) continue; // handled by _labeled
      final cut = value.indexOf(RegExp(r'\t| \| '));
      if (cut > 0) value = value.substring(0, cut).trimRight();
      if (value.length > 300) continue;
      final valueStart = m.start + m.group(0)!.lastIndexOf(m.group(2)!);
      final label = _capitalize(key);

      if (_phraseWords.hasMatch(key)) {
        final phrase = _wholeValue(text, valueStart, valueStart + value.length);
        if (phrase == null) continue;
        out.add(_Candidate(
          kind: FieldKind.password,
          label: label,
          value: phrase.$1,
          span: phrase.$2,
          priority: _pLabeledSecret,
          builtIn: BuiltInField.password,
          secret: true,
        ));
      } else if (_secretWords.hasMatch(key)) {
        final parsed = _parseValue(
            text, valueStart, valueStart + value.length, _Cat.password,
            prose: false);
        if (parsed == null) continue;
        out.add(_Candidate(
          kind: FieldKind.password,
          label: label,
          value: parsed.$1,
          span: parsed.$2,
          priority: _pLabeledSecret,
          builtIn: _secretKeyField(key),
          secret: true,
        ));
      } else if (_usernameWords.hasMatch(key)) {
        final parsed = _parseValue(
            text, valueStart, valueStart + value.length, _Cat.username,
            prose: false);
        if (parsed == null) continue;
        out.add(_Candidate(
          kind: FieldKind.username,
          label: label,
          value: parsed.$1,
          span: parsed.$2,
          priority: _pLabeledOther,
          builtIn: BuiltInField.username,
        ));
      } else {
        out.add(_Candidate(
          kind: FieldKind.labeled,
          label: label,
          value: value,
          span: Span(valueStart, valueStart + value.length),
          priority: _pGeneric,
          builtIn: BuiltInField.labeled,
        ));
      }
    }
  }

  static final _quotedPair = RegExp(
      r'''(["'])([^"'\n]{1,40})\1[ \t]*[:=][ \t]*(?:"((?:[^"\\\n]|\\.){1,200})"|'((?:[^'\\\n]|\\.){1,200})')''');

  static void _quotedPairs(String text, List<_Candidate> out) {
    for (final m in _quotedPair.allMatches(text)) {
      final key = m.group(2)!;
      final value = m.group(3) ?? m.group(4)!;
      final entry = _lookupLabel(key);
      final secret = _secretWords.hasMatch(key) ||
          (entry != null &&
              entry.$1 != _Cat.username &&
              entry.$1 != _Cat.phone &&
              entry.$1 != _Cat.code);
      if (!secret || value.isEmpty || _placeholder.hasMatch(value)) continue;
      final start = m.end - 1 - value.length;
      out.add(_Candidate(
        kind: FieldKind.password,
        label: entry?.$2 ?? _capitalize(key),
        value: value,
        span: Span(start, start + value.length),
        priority: _pLabeledSecret,
        builtIn: entry != null ? _fieldOf(entry.$1) : _secretKeyField(key),
        secret: true,
      ));
    }
  }

  // ── cards ──────────────────────────────────────────────────────────────────

  static final _cardRe = RegExp(r'(?<![\d-])(?:\d[ -]?){12,18}\d(?![\d-])');

  static void _cards(String text, List<_Candidate> out) {
    for (final m in _cardRe.allMatches(text)) {
      final digits = m.group(0)!.replaceAll(RegExp(r'\D'), '');
      if (digits.length < 13 || digits.length > 19) continue;
      final brand = _cardBrand(digits);
      if (brand == null || !_luhn(digits)) continue;
      out.add(_Candidate(
        kind: FieldKind.card,
        label: brand,
        value: digits,
        span: Span(m.start, m.end),
        priority: _pCard,
        builtIn: BuiltInField.card,
        secret: true,
      ));
    }
  }

  static String? _cardBrand(String d) {
    int prefix(int n) => int.parse(d.substring(0, n));
    if (d.startsWith('4')) return 'Visa';
    if (prefix(2) >= 51 && prefix(2) <= 55) return 'Mastercard';
    if (prefix(4) >= 2221 && prefix(4) <= 2720) return 'Mastercard';
    if (d.startsWith('34') || d.startsWith('37')) return 'Amex';
    if (d.startsWith('6011') || d.startsWith('65')) return 'Discover';
    if (prefix(3) >= 644 && prefix(3) <= 649) return 'Discover';
    if (prefix(4) >= 3528 && prefix(4) <= 3589) return 'JCB';
    if (d.startsWith('62')) return 'UnionPay';
    if (d.startsWith('36') || d.startsWith('38')) return 'Diners';
    if (prefix(3) >= 300 && prefix(3) <= 305) return 'Diners';
    return null;
  }

  static bool _luhn(String digits) {
    var sum = 0;
    var doubleIt = false;
    for (var i = digits.length - 1; i >= 0; i--) {
      var n = digits.codeUnitAt(i) - 48;
      if (doubleIt) {
        n *= 2;
        if (n > 9) n -= 9;
      }
      sum += n;
      doubleIt = !doubleIt;
    }
    return sum % 10 == 0;
  }

  // ── links, emails, addresses ───────────────────────────────────────────────

  static final _urlRe = RegExp(
      r'''(?<![\w@.+-])(?:[a-zA-Z][a-zA-Z0-9+.-]{1,20}://|www\.)[^\s<>"'`{}|\\^\[\]]+''');
  static final _www =
      RegExp(r'^www\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}');
  static final _urlCredentials =
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#@\s:]*):([^\s/]+)@');

  static void _urls(
      String text, List<_Candidate> out, int Function() nextGroup) {
    for (final m in _urlRe.allMatches(text)) {
      final raw = m.group(0)!;
      final url = raw.substring(0, _trimUrlEnd(raw));
      if (url.startsWith('www.')) {
        if (!_www.hasMatch(url)) continue;
      } else if (url.length <= url.indexOf('://') + 3) {
        continue;
      }
      final group = nextGroup();
      out.add(_Candidate(
        kind: FieldKind.url,
        label: 'URL',
        value: url,
        span: Span(m.start, m.start + url.length),
        priority: _pUrl,
        builtIn: BuiltInField.link,
        group: group,
      ));
      final creds = _urlCredentials.firstMatch(url);
      if (creds != null) {
        final password = creds.group(2)!;
        final start = m.start + creds.end - 1 - password.length;
        out.add(_Candidate(
          kind: FieldKind.password,
          label: 'Password',
          value: password,
          span: Span(start, start + password.length),
          priority: _pUrlPassword,
          builtIn: BuiltInField.password,
          secret: true,
          group: group,
        ));
      }
    }
  }

  /// Drops sentence punctuation and unbalanced closing brackets from the end
  /// of a URL: "(see https://x.com/a)." → "https://x.com/a".
  static int _trimUrlEnd(String s) {
    var open = 0, close = 0;
    for (final unit in s.codeUnits) {
      if (unit == 0x28) open++;
      if (unit == 0x29) close++;
    }
    var end = s.length;
    while (end > 0) {
      final c = s[end - 1];
      if ('.,;:!?*'.contains(c)) {
        end--;
        continue;
      }
      if (c == ')' && open < close) {
        close--;
        end--;
        continue;
      }
      break;
    }
    return end;
  }

  static final _emailRe = RegExp(
      r'(?<![\w.%+-])[A-Za-z0-9](?:[A-Za-z0-9._%+-]*[A-Za-z0-9_%+-])?@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,24}(?![A-Za-z0-9-])');

  static void _emails(String text, List<_Candidate> out) {
    for (final m in _emailRe.allMatches(text)) {
      out.add(_Candidate(
        kind: FieldKind.email,
        label: 'Email',
        value: m.group(0)!,
        span: Span(m.start, m.end),
        priority: _pEmail,
        builtIn: BuiltInField.email,
      ));
    }
  }

  static final _ipv4Re = RegExp(
      r'(?<![\w.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:/(?:3[0-2]|[12]?\d)|:\d{1,5})?(?!\d|\.\d)');

  static void _ips(String text, List<_Candidate> out) {
    for (final m in _ipv4Re.allMatches(text)) {
      out.add(_Candidate(
        kind: FieldKind.ip,
        label: 'IP',
        value: m.group(0)!,
        span: Span(m.start, m.end),
        priority: _pIp,
        builtIn: BuiltInField.ip,
      ));
    }
  }

  static final _uuidRe = RegExp(
      r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b');

  static void _uuids(String text, List<_Candidate> out) {
    for (final m in _uuidRe.allMatches(text)) {
      out.add(_Candidate(
        kind: FieldKind.code,
        label: 'UUID',
        value: m.group(0)!,
        span: Span(m.start, m.end),
        priority: _pUuid,
        builtIn: BuiltInField.reference,
      ));
    }
  }

  // Unlabeled phone numbers need a recognizable shape: a + country code, an
  // area code in brackets, a leading 0 (0912 345 678), or 555-123-4567. A bare
  // run of digits such as an order number or a Unix timestamp is not a phone.
  static final _phoneRe = RegExp(r'(?<![\w+#$.,/-])(?:'
      r'\+\d{1,3}(?:[ .-]?\(?\d{1,4}\)?)(?:[ .-]?\d{2,4}){2,4}'
      r'|\(\d{2,4}\)[ .-]?\d{3,4}[ .-]?\d{3,4}'
      r'|0\d{2,4}[ .-]\d{3,4}[ .-]\d{3,4}'
      r'|0\d{8,10}'
      r'|\d{3}[ .-]\d{3}[ .-]\d{4}'
      r')(?!\d|[.-]\d)');

  static void _phones(String text, List<_Candidate> out) {
    for (final m in _phoneRe.allMatches(text)) {
      final digits = m.group(0)!.replaceAll(RegExp(r'\D'), '').length;
      if (digits < 8 || digits > 15) continue;
      out.add(_Candidate(
        kind: FieldKind.phone,
        label: 'Phone',
        value: m.group(0)!,
        span: Span(m.start, m.end),
        priority: _pPhone,
        builtIn: BuiltInField.phone,
      ));
    }
  }

  // ── a password pasted on its own ───────────────────────────────────────────

  static final _identifier = RegExp(r'^[A-Z]?[a-z]+(?:[A-Z][a-z]+)+\d{0,4}$');
  static final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}');

  static void _guessedPasswords(String text, List<_Candidate> out) {
    final lines = _lines(text)
        .where((l) => text.substring(l.$1, l.$2).trim().isNotEmpty)
        .toList();
    if (lines.length > 10) return; // a code listing, not a password
    for (final (start, end) in lines) {
      final raw = text.substring(start, end);
      final token = raw.trim();
      if (token.length < 8 ||
          token.length > 64 ||
          token.contains(RegExp(r'\s'))) {
        continue;
      }
      if (token.startsWith(RegExp(r'[/~\\]|[A-Za-z]:\\')) ||
          _schemeStart.hasMatch(token) ||
          _isoDate.hasMatch(token)) {
        continue;
      }
      if (RegExp(r'\(.*\)|<.*>|\[.*\]|\{.*\}').hasMatch(token)) continue;
      final hasLower = token.contains(RegExp(r'[a-z]'));
      final hasUpper = token.contains(RegExp(r'[A-Z]'));
      final hasDigit = token.contains(RegExp(r'\d'));
      final hasSymbol = token.contains(RegExp(r'[^A-Za-z0-9._-]'));
      final classes =
          [hasLower, hasUpper, hasDigit, hasSymbol].where((b) => b).length;
      if (classes < 3 || !(hasSymbol || token.length >= 10)) continue;
      if (!hasSymbol && _identifier.hasMatch(token)) continue;
      final offset = start + raw.indexOf(token);
      out.add(_Candidate(
        kind: FieldKind.password,
        label: 'Password',
        value: token,
        span: Span(offset, offset + token.length),
        priority: _pGuessedPassword,
        builtIn: BuiltInField.password,
        secret: true,
      ));
    }
  }

  // ── plain lines as a fallback ──────────────────────────────────────────────

  /// Gives the free numbers in [fields] to plain lines, in reading order.
  /// Lines that overlap [taken] (any accepted candidate, including kinds that
  /// are turned off) or repeat one of [values] are skipped.
  static void _fallbackLines(String text, Map<int, ExtractedField> fields,
      List<Span> taken, Set<String> values) {
    var number = 1;
    for (final (start, end) in _lines(text)) {
      if (fields.length >= maxFields) break;
      final raw = text.substring(start, end);
      final line = raw.trim();
      if (line.isEmpty ||
          !line.contains(RegExp(r'[\p{L}\p{N}]', unicode: true))) {
        continue;
      }
      final offset = start + raw.indexOf(line);
      final span = Span(offset, offset + line.length);
      if (taken.any(span.overlaps)) continue;
      final bare = line.replaceFirst(RegExp(r'[:：]$'), '');
      if (_lookupLabel(bare) != null) continue; // "Password" heading
      if (line.endsWith(':') && line.length <= 40) continue; // "Credentials:"
      if (!values.add(line)) continue;
      while (fields.containsKey(number)) {
        number++;
      }
      fields[number] = ExtractedField(
        kind: FieldKind.line,
        label: 'Line',
        value: line,
        span: span,
        number: number,
      );
    }
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  static int _lineEnd(String text, int from) {
    final i = text.indexOf('\n', from);
    return i < 0 ? text.length : i;
  }

  static List<(int, int)> _lines(String text) {
    final result = <(int, int)>[];
    var start = 0;
    while (start <= text.length) {
      final end = _lineEnd(text, start);
      result.add((start, end));
      if (end >= text.length) break;
      start = end + 1;
    }
    return result;
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static List<Span> _merge(List<Span> spans) {
    if (spans.isEmpty) return const [];
    final sorted = [...spans]..sort((a, b) => a.start.compareTo(b.start));
    final merged = <Span>[sorted.first];
    for (final s in sorted.skip(1)) {
      final last = merged.last;
      if (s.start <= last.end) {
        if (s.end > last.end) {
          merged[merged.length - 1] = Span(last.start, s.end);
        }
      } else {
        merged.add(s);
      }
    }
    return merged;
  }
}
