import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/app_lock.dart';
import '../services/passcode.dart';

/// Asks for a new passcode twice. Returns it, or null if cancelled.
Future<String?> showNewPasscodeDialog(BuildContext context,
    {String title = 'Set a passcode'}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NewPasscodeDialog(title: title),
  );
}

/// Asks for the current passcode (or Touch ID / Windows Hello, if that's on)
/// before a change to App Lock. True if confirmed.
Future<bool> confirmPasscode(BuildContext context,
    {required String title, String action = 'Continue'}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => _ConfirmPasscodeDialog(title: title, action: action),
  );
  return confirmed ?? false;
}

class _NewPasscodeDialog extends StatefulWidget {
  const _NewPasscodeDialog({required this.title});

  final String title;

  @override
  State<_NewPasscodeDialog> createState() => _NewPasscodeDialogState();
}

class _NewPasscodeDialogState extends State<_NewPasscodeDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  final _secondFocus = FocusNode();
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    _secondFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final passcode = _first.text;
    if (passcode.length < PasscodeHash.minLength) {
      setState(
          () => _error = 'Use at least ${PasscodeHash.minLength} characters.');
      return;
    }
    if (passcode != _second.text) {
      setState(() => _error = 'The two passcodes don’t match.');
      return;
    }
    Navigator.pop(context, passcode);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'You’ll enter it whenever Pastee is locked. Letters, numbers and '
              'symbols all work. Pastee can’t recover it if you forget it.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _first,
              autofocus: true,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'New passcode',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _secondFocus.requestFocus(),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _second,
              focusNode: _secondFocus,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Repeat the passcode',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

class _ConfirmPasscodeDialog extends ConsumerStatefulWidget {
  const _ConfirmPasscodeDialog({required this.title, required this.action});

  final String title;
  final String action;

  @override
  ConsumerState<_ConfirmPasscodeDialog> createState() =>
      _ConfirmPasscodeDialogState();
}

class _ConfirmPasscodeDialogState
    extends ConsumerState<_ConfirmPasscodeDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _deviceAvailable = false;
  String _deviceName = 'Touch ID';

  @override
  void initState() {
    super.initState();
    _checkDevice();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _checkDevice() async {
    if (!ref.read(appLockProvider).deviceUnlock) return;
    final device = ref.read(deviceAuthenticatorProvider);
    final available = await device.isAvailable();
    final name = available ? await device.displayName() : _deviceName;
    if (mounted) {
      setState(() {
        _deviceAvailable = available;
        _deviceName = name;
      });
    }
  }

  Future<void> _submit() async {
    if (_busy || _controller.text.isEmpty) return;
    setState(() => _busy = true);
    final notifier = ref.read(appLockProvider.notifier);
    final result = await notifier.checkPasscode(_controller.text);
    if (!mounted) return;
    if (result == PasscodeResult.ok) {
      Navigator.pop(context, true);
      return;
    }
    _controller.clear();
    final wait = notifier.lockoutRemaining;
    setState(() {
      _busy = false;
      _error = wait != null
          ? 'Too many wrong passcodes. Try again in ${wait.inMinutes}:${(wait.inSeconds % 60).toString().padLeft(2, '0')}.'
          : 'Wrong passcode.';
    });
  }

  Future<void> _useDevice() async {
    setState(() => _busy = true);
    final ok = await ref
        .read(appLockProvider.notifier)
        .confirmWithDevice(widget.title);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              readOnly: _busy,
              decoration: InputDecoration(
                labelText: 'Current passcode',
                border: const OutlineInputBorder(),
                errorText: _error,
                errorMaxLines: 2,
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_deviceAvailable) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _useDevice,
                  icon: const Icon(Icons.fingerprint),
                  label: Text('Use $_deviceName'),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: _busy ? null : _submit, child: Text(widget.action)),
      ],
    );
  }
}
