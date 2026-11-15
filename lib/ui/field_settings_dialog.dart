import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/field_config.dart';
import '../providers/field_config_provider.dart';
import '../services/field_extractor.dart';
import '../services/masking.dart';
import '../services/text_utils.dart';
import 'field_rule_dialog.dart';
import 'key_cap.dart';
import 'paste_tile.dart';
import 'shortcut_labels.dart';

/// Settings → Fields & numbers: your own phrases, the built-in kinds of
/// field, and which number copies what.
Future<void> showFieldSettingsDialog(BuildContext context) {
  return showDialog<void>(
      context: context, builder: (_) => const FieldSettingsDialog());
}

/// The section in Settings that opens [FieldSettingsDialog].
class FieldsSettingsEntry extends ConsumerWidget {
  const FieldsSettingsEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final summary = _summary(ref.watch(fieldConfigProvider));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            'Fields',
            style: theme.textTheme.titleSmall
                ?.copyWith(color: cs.primary, fontWeight: FontWeight.w700),
          ),
        ),
        Text(
          'Teach Pastee your own labels, turn off fields you don’t need, and '
          'choose which number copies what.',
          style:
              theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        if (summary != null) ...[
          const SizedBox(height: 2),
          Text(summary, style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => showFieldSettingsDialog(context),
          icon: const Icon(Icons.tune, size: 18),
          label: const Text('Fields & numbers…'),
        ),
      ],
    );
  }

  static String? _summary(FieldConfig config) {
    if (config.isDefault) return null;
    final rules = config.custom.length;
    final off = config.builtIn.values.where((s) => !s.enabled).length;
    final numbered = config.builtIn.values
            .where((s) => s.enabled && s.number != null)
            .length +
        config.custom.where((r) => r.number != null).length;
    return [
      if (rules > 0) '$rules ${rules == 1 ? 'phrase' : 'phrases'} of your own',
      if (numbered > 0) '$numbered with a fixed number',
      if (off > 0) '$off built-in ${off == 1 ? 'kind' : 'kinds'} off',
      if (!config.numberLines) 'plain lines not numbered',
    ].join(' · ');
  }
}

/// How the built-in kinds are named in Settings.
(String, String) describeBuiltInField(BuiltInField field) => switch (field) {
      BuiltInField.password => (
          'Passwords',
          'Password, passcode, passphrase, mật khẩu, and passwords in links',
        ),
      BuiltInField.pin => (
          'PINs & one-time codes',
          'PIN, OTP, 2FA and verification codes',
        ),
      BuiltInField.card => ('Cards', 'Card numbers and CVV'),
      BuiltInField.token => (
          'Keys & tokens',
          'API keys, tokens, private keys and recovery codes',
        ),
      BuiltInField.username => (
          'Usernames',
          'Username, login, account, tài khoản',
        ),
      BuiltInField.email => ('Emails', 'Email addresses'),
      BuiltInField.link => ('Links', 'Web and connection addresses'),
      BuiltInField.ip => ('IP addresses', 'Like 192.168.1.10 or 10.0.0.1:5432'),
      BuiltInField.phone => (
          'Phone numbers',
          'Labeled ones, and numbers shaped like a phone number',
        ),
      BuiltInField.reference => (
          'Order & reference numbers',
          'Order, invoice, tracking, booking, IDs and UUIDs',
        ),
      BuiltInField.labeled => (
          'Other labeled values',
          'Any “Key: value” line, like Host: or Port:',
        ),
    };

class FieldSettingsDialog extends ConsumerStatefulWidget {
  const FieldSettingsDialog({super.key});

  @override
  ConsumerState<FieldSettingsDialog> createState() =>
      _FieldSettingsDialogState();
}

class _FieldSettingsDialogState extends ConsumerState<FieldSettingsDialog> {
  /// When the dialog has this much height, "Try it" stays in view below the
  /// settings; with less, it goes at the end of the list.
  static const _pinTryItFrom = 600.0;

  final _sample = TextEditingController();

  FieldConfigNotifier get _fields => ref.read(fieldConfigProvider.notifier);

  @override
  void dispose() {
    _sample.dispose();
    super.dispose();
  }

  Future<void> _edit([CustomFieldRule? rule]) async {
    final saved = await showFieldRuleDialog(context, rule: rule);
    if (saved != null) await _fields.saveRule(saved);
  }

  Future<void> _delete(CustomFieldRule rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete “${truncateGraphemes(rule.name, 30)}”?'),
        content: const Text('Pastee stops picking it out of your notes.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _fields.removeRule(rule.id);
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset fields and numbers?'),
        content: const Text('This deletes your phrases, turns every built-in '
            'field back on, and sets all numbers to Auto.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _fields.reset();
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(fieldConfigProvider);
    final tryIt = _TryIt(controller: _sample, config: config);

    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: LayoutBuilder(
          builder: (context, constraints) => _buildBody(context, config, tryIt,
              pinTryIt: constraints.maxHeight >= _pinTryItFrom),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, FieldConfig config, Widget tryIt,
      {required bool pinTryIt}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text('Fields & numbers',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${primaryShortcut('1–9')} copies the field with that '
                  'number from the top item. A field set to a number '
                  'keeps it; if two want the same one, the first in the '
                  'note gets it. Auto fields take the numbers left over, '
                  'in reading order.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
                ..._clashes(config, theme),
                const SizedBox(height: 16),
                _buildRules(config, theme, cs),
                const SizedBox(height: 20),
                _buildBuiltIn(config, theme, cs),
                if (!pinTryIt) ...[
                  const SizedBox(height: 20),
                  tryIt,
                ],
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: config.isDefault ? null : _reset,
                    child: const Text('Reset to defaults…'),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (pinTryIt) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: tryIt,
          ),
        ],
      ],
    );
  }

  /// "⌘3: Member ID and Emails both want it", for each number asked for twice.
  List<Widget> _clashes(FieldConfig config, ThemeData theme) {
    final wanted = <int, List<String>>{};
    for (final rule in config.custom) {
      final n = rule.number;
      if (rule.enabled && n != null) (wanted[n] ??= []).add(rule.name);
    }
    for (final field in BuiltInField.values) {
      final setting = config[field];
      final n = setting.number;
      if (setting.enabled && n != null) {
        (wanted[n] ??= []).add(describeBuiltInField(field).$1);
      }
    }
    final clashes = wanted.entries.where((e) => e.value.length > 1).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      for (final clash in clashes)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline,
                  size: 16, color: theme.colorScheme.tertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${primaryShortcut('${clash.key}')}: ${_names(clash.value)} '
                  '${clash.value.length == 2 ? 'both' : 'all'} want it. In a '
                  'note, the one that comes first gets it.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
    ];
  }

  static String _names(List<String> names) => names.length == 2
      ? '${names[0]} and ${names[1]}'
      : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';

  Widget _sectionTitle(String text, ThemeData theme, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildRules(FieldConfig config, ThemeData theme, ColorScheme cs) {
    final rules = config.custom;
    final full = rules.length >= FieldConfig.maxRules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(
          'Your phrases',
          theme,
          trailing: TextButton.icon(
            key: const Key('fields-add'),
            onPressed: full ? null : () => _edit(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add'),
          ),
        ),
        if (rules.isEmpty)
          Text(
            'None yet. Add the label that comes before a value you copy '
            'often, like “Member ID” or “Mã khách hàng”, and Pastee picks '
            'the value out of your notes.',
            style:
                theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          )
        else
          for (final rule in rules)
            _RuleRow(
              key: ValueKey('rule-${rule.id}'),
              rule: rule,
              onEnabled: (on) => _fields.setRuleEnabled(rule.id, on),
              onEdit: () => _edit(rule),
              onDelete: () => _delete(rule),
            ),
      ],
    );
  }

  Widget _buildBuiltIn(FieldConfig config, ThemeData theme, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('Built-in fields', theme),
        for (final field in BuiltInField.values)
          _BuiltInRow(
            key: ValueKey('builtin-${field.name}'),
            field: field,
            setting: config[field],
            onChanged: (setting) => _fields.setBuiltIn(field, setting),
          ),
        _SwitchRow(
          switchKey: const Key('builtin-lines'),
          title: 'Number plain lines too',
          subtitle: 'Lines with no detected field take the numbers left over.',
          value: config.numberLines,
          onChanged: _fields.setNumberLines,
        ),
      ],
    );
  }
}

/// A switch, a title and subtitle, and something on the right.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.switchKey,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.trailing,
    this.onTap,
  });

  final Key switchKey;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap ?? () => onChanged(!value),
      borderRadius: BorderRadius.circular(6),
      canRequestFocus: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              // Read out as one control: "Passwords, switch, on".
              child: MergeSemantics(
                child: Row(
                  children: [
                    Switch(
                      key: switchKey,
                      value: value,
                      onChanged: onChanged,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color:
                                    value ? cs.onSurface : cs.onSurfaceVariant),
                          ),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _BuiltInRow extends StatelessWidget {
  const _BuiltInRow({
    super.key,
    required this.field,
    required this.setting,
    required this.onChanged,
  });

  final BuiltInField field;
  final BuiltInFieldSetting setting;
  final ValueChanged<BuiltInFieldSetting> onChanged;

  @override
  Widget build(BuildContext context) {
    final (title, description) = describeBuiltInField(field);
    return _SwitchRow(
      switchKey: ValueKey('builtin-switch-${field.name}'),
      title: title,
      subtitle: !setting.enabled && field.secret
          ? 'Off: no chip or number, but still hidden behind dots.'
          : description,
      value: setting.enabled,
      onChanged: (on) => onChanged(setting.copyWith(enabled: on)),
      trailing: FieldNumberDropdown(
        key: ValueKey('builtin-number-${field.name}'),
        number: setting.number,
        onChanged: setting.enabled
            ? (n) => onChanged(setting.copyWith(number: () => n))
            : null,
      ),
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    super.key,
    required this.rule,
    required this.onEnabled,
    required this.onEdit,
    required this.onDelete,
  });

  final CustomFieldRule rule;
  final ValueChanged<bool> onEnabled;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  String get _summary {
    final parts = <String>[
      if (rule.phrases.isNotEmpty)
        rule.phrases.map((p) => '“$p”').join(', ')
      else
        'Every match of the pattern',
      if (rule.hasPattern) 'value: ${rule.pattern}',
      if (rule.secret) 'secret',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final number = rule.number;
    return _SwitchRow(
      switchKey: ValueKey('rule-switch-${rule.id}'),
      title: rule.name,
      subtitle: _summary,
      value: rule.enabled,
      onChanged: onEnabled,
      onTap: onEdit,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (number == null)
            Text('Auto', style: Theme.of(context).textTheme.bodySmall)
          else
            KeyCap(primaryShortcut('$number'), emphasized: rule.enabled),
          IconButton(
            key: ValueKey('rule-edit-${rule.id}'),
            tooltip: 'Edit',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            icon: const Icon(Icons.edit_outlined),
            onPressed: onEdit,
          ),
          IconButton(
            key: ValueKey('rule-delete-${rule.id}'),
            tooltip: 'Delete',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// Paste a sample and see its chips, numbered, as they would be on an item.
class _TryIt extends StatelessWidget {
  const _TryIt({required this.controller, required this.config});

  final TextEditingController controller;
  final FieldConfig config;

  String _chipText(ExtractedField field, Extraction extraction, String text) {
    if (field.secret) {
      return field.kind == FieldKind.card
          ? '${field.label} ${Masker.hiddenFieldText(field)}'
          : '${field.label} ••••';
    }
    var value = field.value;
    if (extraction.hasSecrets && field.kind != FieldKind.card) {
      value = Masker.maskWithin(text, field.span, extraction.secretSpans);
    }
    return visibleChipText(
        field, sanitizeUtf16(value.replaceAll(RegExp(r'\s*\n\s*'), ' ')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Try it',
          style: theme.textTheme.titleSmall
              ?.copyWith(color: cs.primary, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('fields-try-it'),
          controller: controller,
          minLines: 2,
          maxLines: 4,
          style: theme.textTheme.bodySmall,
          decoration: InputDecoration(
            hintText: 'Paste a sample note to see its fields and numbers',
            isDense: true,
            filled: true,
            fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.4),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final text = value.text;
            if (text.trim().isEmpty) return const SizedBox.shrink();
            final extraction = FieldExtractor.extract(text, config: config);
            if (extraction.fields.isEmpty) {
              return Text(
                'No fields in this text.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              );
            }
            return Wrap(
              key: const Key('fields-try-it-chips'),
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final field in extraction.fields)
                  FieldChip(
                    number: field.number,
                    icon: iconForField(field.kind),
                    text: _chipText(field, extraction, text),
                    masked: field.secret,
                    colorScheme: cs,
                    tooltip: '${primaryShortcut('${field.number}')}  '
                        '${field.label}${field.secret ? ' (hidden)' : ''}',
                    onTap: null,
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
