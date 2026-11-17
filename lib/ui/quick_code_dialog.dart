import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/quick_code.dart';

/// Asks for the quick code of one field.
///
/// Returns the new code, '' to remove the current one, or null when the user
/// cancels. [problemWith] explains why a code can't be used, or returns null.
Future<String?> showQuickCodeDialog(
  BuildContext context, {
  required String fieldLabel,
  String? current,
  required String? Function(String code) problemWith,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => QuickCodeDialog(
      fieldLabel: fieldLabel,
      current: current,
      problemWith: problemWith,
    ),
  );
}

class QuickCodeDialog extends StatefulWidget {
  const QuickCodeDialog({
    super.key,
    required this.fieldLabel,
    this.current,
    required this.problemWith,
  });

  final String fieldLabel;
  final String? current;
  final String? Function(String code) problemWith;

  @override
  State<QuickCodeDialog> createState() => _QuickCodeDialogState();
}

class _QuickCodeDialogState extends State<QuickCodeDialog> {
  late final TextEditingController _controller = TextEditingController(
      text: widget.current ?? '')
    ..selection =
        TextSelection(baseOffset: 0, extentOffset: widget.current?.length ?? 0);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final code = _controller.text.trim();
    final problem = widget.problemWith(code);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Quick code for ${widget.fieldLabel}'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Type the code in the search bar and press Enter: Pastee copies '
              'this ${widget.fieldLabel} and goes back to the app you were in.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('quickCode'),
              controller: _controller,
              autofocus: true,
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'\s')),
                LengthLimitingTextInputFormatter(QuickCode.maxLength),
              ],
              decoration: InputDecoration(
                labelText: 'Quick code',
                hintText: 'e.g. st2',
                helperText: 'One character or more. Capitals don’t matter.',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(''),
            child: const Text('Remove code'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
