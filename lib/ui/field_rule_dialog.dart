import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../model/field_config.dart';
import '../providers/field_config_provider.dart';
import '../services/pattern_guard.dart';
import 'shortcut_labels.dart';
import 'theme.dart';

/// Edits one of "Your phrases", or makes a new one when [rule] is null.
/// Returns the rule to save, or null if cancelled.
Future<CustomFieldRule?> showFieldRuleDialog(BuildContext context,
    {CustomFieldRule? rule}) {
  return showDialog<CustomFieldRule>(
    context: context,
    builder: (_) => FieldRuleDialog(rule: rule),
  );
}

/// Picks Auto or a number 1–9, shown as the shortcut that copies it.
class FieldNumberDropdown extends StatelessWidget {
  const FieldNumberDropdown({
    super.key,
    required this.number,
    required this.onChanged,
  });

  /// Null is Auto.
  final int? number;

  /// Null disables the dropdown.
  final ValueChanged<int?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return DropdownButton<int>(
      value: number ?? 0,
      isDense: true,
      onChanged: onChanged == null ? null : (v) => onChanged(v == 0 ? null : v),
      items: [
        const DropdownMenuItem(value: 0, child: Text('Auto')),
        for (var n = minFieldNumber; n <= maxFieldNumber; n++)
          DropdownMenuItem(value: n, child: Text(primaryShortcut('$n'))),
      ],
    );
  }
}

class FieldRuleDialog extends ConsumerStatefulWidget {
  const FieldRuleDialog({super.key, this.rule});

  final CustomFieldRule? rule;

  @override
  ConsumerState<FieldRuleDialog> createState() => _FieldRuleDialogState();
}

class _FieldRuleDialogState extends ConsumerState<FieldRuleDialog> {
  static const _uuid = Uuid();
  static final _phraseSeparators = RegExp(r'[,，、;\n]');

  late final _name = TextEditingController(text: widget.rule?.name ?? '');
  late final _phrases =
      TextEditingController(text: widget.rule?.phrases.join(', ') ?? '');
  late final _pattern = TextEditingController(text: widget.rule?.pattern ?? '');
  late bool _secret = widget.rule?.secret ?? false;
  late int? _number = widget.rule?.number;

  String? _nameError;
  String? _phrasesError;
  String? _patternError;
  bool _checking = false;

  @override
  void dispose() {
    _name.dispose();
    _phrases.dispose();
    _pattern.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_checking) return;
    final name = _name.text.trim();
    final raw = _phrases.text
        .split(_phraseSeparators)
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    final pattern = _pattern.text.trim().isEmpty ? '' : _pattern.text;

    String? nameError;
    String? phrasesError;
    String? patternError;
    if (name.isEmpty) nameError = 'Give it a name.';
    if (raw.any((p) => p.length > CustomFieldRule.maxPhraseLength)) {
      phrasesError = 'Keep each phrase under '
          '${CustomFieldRule.maxPhraseLength} characters.';
    } else if (raw.length > CustomFieldRule.maxPhrases) {
      phrasesError = 'Use at most ${CustomFieldRule.maxPhrases} phrases.';
    } else if (raw.isEmpty && pattern.isEmpty) {
      phrasesError = 'Add a phrase, a value pattern, or both.';
    }
    if (pattern.isNotEmpty) patternError = PatternGuard.quickCheck(pattern);
    final ok =
        nameError == null && phrasesError == null && patternError == null;
    // A pattern that was saved before already passed the speed check.
    final timed = pattern.isEmpty || pattern == widget.rule?.pattern;
    setState(() {
      _nameError = nameError;
      _phrasesError = phrasesError;
      _patternError = patternError;
      _checking = ok && !timed;
    });
    if (!ok) return;
    if (timed) {
      _finish(name, raw, pattern);
      return;
    }
    patternError = await ref.read(patternSpeedCheckProvider)(pattern);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _patternError = patternError;
    });
    if (patternError == null) _finish(name, raw, pattern);
  }

  void _finish(String name, List<String> phrases, String pattern) {
    final rule = widget.rule;
    Navigator.pop(
      context,
      CustomFieldRule(
        id: rule?.id ?? _uuid.v4(),
        name: name,
        phrases: phrases,
        pattern: pattern,
        secret: _secret,
        number: _number,
        enabled: rule?.enabled ?? true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mono = TextStyle(
      fontFamily: AppTheme.monoFont,
      fontFamilyFallback: AppTheme.monoFallback,
    );
    return AlertDialog(
      title: Text(widget.rule == null ? 'New phrase' : 'Edit phrase'),
      scrollable: true,
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('rule-name'),
              controller: _name,
              autofocus: widget.rule == null,
              maxLength: CustomFieldRule.maxNameLength,
              decoration: InputDecoration(
                labelText: 'Name',
                helperText: 'Shown on the chip and when you copy it.',
                hintText: 'e.g. Member ID',
                counterText: '',
                border: const OutlineInputBorder(),
                errorText: _nameError,
              ),
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('rule-phrases'),
              controller: _phrases,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Phrases',
                helperText: 'The words before the value. Separate them with '
                    'commas. Case, accents and extra spaces don’t matter.',
                helperMaxLines: 3,
                hintText: 'e.g. member id, mã thành viên',
                border: const OutlineInputBorder(),
                errorText: _phrasesError,
                errorMaxLines: 3,
              ),
              onChanged: (_) {
                if (_phrasesError != null) setState(() => _phrasesError = null);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('rule-pattern'),
              controller: _pattern,
              style: mono,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Value pattern (optional)',
                helperText: 'A regular expression the value must match, like '
                    r'[A-Z]{2}\d{6}. With a (group), only the group is copied. '
                    'With no phrases, every match is a field.',
                helperMaxLines: 4,
                border: const OutlineInputBorder(),
                errorText: _patternError,
                errorMaxLines: 4,
              ),
              onChanged: (_) {
                if (_patternError != null) setState(() => _patternError = null);
              },
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              key: const Key('rule-secret'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Secret'),
              subtitle: const Text(
                  'Hidden behind dots like a password, and copied as a secret.'),
              value: _secret,
              onChanged: (v) => setState(() => _secret = v),
            ),
            Row(
              children: [
                Expanded(
                  child: Text('Number', style: theme.textTheme.bodyMedium),
                ),
                FieldNumberDropdown(
                  key: const Key('rule-number'),
                  number: _number,
                  onChanged: (n) => setState(() => _number = n),
                ),
              ],
            ),
            Text(
              _number == null
                  ? 'Auto: the next free number, in reading order.'
                  : '${primaryShortcut('$_number')} copies it from the top item.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('rule-save'),
          onPressed: _checking ? null : _save,
          child: _checking
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Checking…'),
                  ],
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
