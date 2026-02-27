import 'package:flutter/material.dart';

class ExtractedField {
  final String type;
  final String value;
  final IconData icon;

  const ExtractedField({
    required this.type,
    required this.value,
    required this.icon,
  });
}

class _Pattern {
  final String type;
  final IconData icon;
  final RegExp regex;
  final int? captureGroup;
  final int? minLength;

  const _Pattern(
    this.type,
    this.icon,
    this.regex, {
    this.captureGroup,
    this.minLength,
  });
}

class FieldExtractor {
  static final _patterns = <_Pattern>[
    _Pattern(
      'Secret',
      Icons.key,
      RegExp(
        r'(?:password|passwd|pwd|pass|secret|token|api[_\-]?key|auth[_\-]?token|pin|otp)\s*[:=]\s*(\S+)',
        caseSensitive: false,
      ),
      captureGroup: 1,
    ),
    _Pattern(
      'Email',
      Icons.email_outlined,
      RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+'),
    ),
    _Pattern(
      'URL',
      Icons.link,
      RegExp(r'https?://[^\s<>"{}|\\^`\[\]]+'),
    ),
    _Pattern(
      'Phone',
      Icons.phone_outlined,
      RegExp(
          r'(?:\+\d{1,3}[-.\s]?)?\(?\d{2,4}\)?[-.\s]?\d{3,4}[-.\s]?\d{3,4}'),
      minLength: 7,
    ),
    _Pattern(
      'Code',
      Icons.tag,
      RegExp(
        r'(?:order|id|no|number|ref|ticket|invoice|account|tracking)\s*[#:=]?\s*(\d[\d\-_.]+)',
        caseSensitive: false,
      ),
      captureGroup: 1,
    ),
  ];

  /// Extracts up to 9 labeled fields from [content].
  /// Priority: secrets > emails > URLs > phones > codes > remaining lines.
  static List<ExtractedField> extract(String content) {
    final results = <ExtractedField>[];
    final seen = <String>{};

    void add(String type, IconData icon, String raw) {
      final v = raw.trim();
      if (v.isEmpty || seen.contains(v) || results.length >= 9) return;
      seen.add(v);
      results.add(ExtractedField(type: type, value: v, icon: icon));
    }

    for (final p in _patterns) {
      for (final m in p.regex.allMatches(content)) {
        final raw = p.captureGroup != null
            ? m.group(p.captureGroup!)
            : m.group(0);
        if (raw == null) continue;
        if (p.minLength != null && raw.trim().length < p.minLength!) continue;
        add(p.type, p.icon, raw);
      }
    }

    // Fill remaining slots with non-empty content lines that aren't
    // already represented by a pattern match.
    if (results.length < 9) {
      final lines = content
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      for (final line in lines) {
        if (results.length >= 9) break;
        final covered = seen.any((s) => line.contains(s) || s.contains(line));
        if (covered) continue;
        add('Line', Icons.text_snippet_outlined, line);
      }
    }

    return results;
  }
}
