import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/app_lock.dart';

/// Shows [child] only while App Lock is unlocked. While locked, the items
/// aren't built at all, so nothing can leak through: no previews, no
/// shortcuts, no window snapshot with content.
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycleChanged);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _onLifecycleChanged(AppLifecycleState state) {
    final lock = ref.read(appLockProvider.notifier);
    switch (state) {
      case AppLifecycleState.resumed:
        lock.cameBack();
      case AppLifecycleState.inactive:
        lock.wentAway(hidden: false);
      case AppLifecycleState.hidden ||
            AppLifecycleState.paused ||
            AppLifecycleState.detached:
        lock.wentAway(hidden: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(appLockProvider.select((s) => s.locked),
        (wasLocked, locked) {
      if (locked && wasLocked == false) {
        // Dialogs and snackbars sit above the items; close them too.
        Navigator.of(context).popUntil((route) => route.isFirst);
        ScaffoldMessenger.of(context).clearSnackBars();
      }
    });
    final locked = ref.watch(appLockProvider.select((s) => s.locked));
    return locked ? const LockScreen() : widget.child;
  }
}

class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode(debugLabel: 'passcode');
  String? _message;
  bool _busy = false;
  bool _deviceAvailable = false;
  String _deviceName = 'Touch ID';
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _startTickerIfLockedOut();
    _checkDevice();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _checkDevice() async {
    final device = ref.read(deviceAuthenticatorProvider);
    final available = await device.isAvailable();
    final name = available ? await device.displayName() : _deviceName;
    if (!mounted) return;
    setState(() {
      _deviceAvailable = available;
      _deviceName = name;
    });
    // Offer Touch ID / Windows Hello straight away, once per lock.
    if (available && ref.read(appLockProvider).deviceUnlock) {
      _unlockWithDevice();
    }
  }

  Future<void> _unlockWithDevice() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    await ref.read(appLockProvider.notifier).unlockWithDevice();
    // Unlocked: the gate has already swapped this screen out.
    if (!mounted) return;
    setState(() => _busy = false);
    _focusNode.requestFocus();
  }

  Future<void> _submit() async {
    final passcode = _controller.text;
    if (_busy || passcode.isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final notifier = ref.read(appLockProvider.notifier);
    final result = await notifier.unlockWithPasscode(passcode);
    if (!mounted) return;
    _controller.clear();
    setState(() {
      _busy = false;
      _message = switch (result) {
        PasscodeResult.ok => null,
        PasscodeResult.lockedOut => null, // the countdown says it
        PasscodeResult.wrong => notifier.attemptsLeft <= 3
            ? 'Wrong passcode. ${notifier.attemptsLeft} '
                '${notifier.attemptsLeft == 1 ? 'try' : 'tries'} left before a short wait.'
            : 'Wrong passcode.',
      };
    });
    _startTickerIfLockedOut();
    _focusNode.requestFocus();
  }

  void _startTickerIfLockedOut() {
    _ticker?.cancel();
    if (ref.read(appLockProvider.notifier).lockoutRemaining == null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final over = ref.read(appLockProvider.notifier).lockoutRemaining == null;
      if (over) _ticker?.cancel();
      setState(() {});
      if (over) _focusNode.requestFocus();
    });
  }

  Future<void> _forgotPasscode() async {
    final lock = ref.read(appLockProvider);
    final erase = await showDialog<bool>(
      context: context,
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        return AlertDialog(
          title: const Text('Forgot your passcode?'),
          content: SizedBox(
            width: 360,
            child: Text([
              'Pastee can’t recover your passcode.',
              if (lock.deviceUnlock && _deviceAvailable)
                'You can still unlock with $_deviceName, then set a new passcode in Settings.',
              'Or erase all saved items and turn App Lock off. This can’t be undone.',
            ].join('\n\n')),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: cs.error,
                foregroundColor: cs.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Erase all items'),
            ),
          ],
        );
      },
    );
    if (erase != true || !mounted) return;
    await ref.read(pasteListProvider.notifier).clearAll();
    await ref.read(appLockProvider.notifier).disable();
  }

  void _hideIfSummoned() {
    if (ref.read(summonedProvider)) {
      ref.read(summonedProvider.notifier).state = false;
      ref.read(desktopBridgeProvider).hideWindow();
    }
  }

  String _format(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final lock = ref.watch(appLockProvider);
    final remaining = ref.read(appLockProvider.notifier).lockoutRemaining;
    final lockedOut = remaining != null;
    final showDevice = _deviceAvailable && lock.deviceUnlock;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _hideIfSummoned
      },
      child: Scaffold(
        backgroundColor: cs.surface,
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.lock_outline,
                        size: 34, color: cs.onPrimaryContainer),
                  ),
                  const SizedBox(height: 16),
                  Text('Pastee is locked', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(
                    lockedOut
                        ? 'Too many wrong passcodes.'
                        : 'Enter your passcode to see your items.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    autofocus: true,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    enabled: !lockedOut,
                    readOnly: _busy,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Passcode',
                      border: const OutlineInputBorder(),
                      errorText: lockedOut
                          ? 'Try again in ${_format(remaining)}'
                          : _message,
                      errorMaxLines: 2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: lockedOut || _busy ? null : _submit,
                      child: const Text('Unlock'),
                    ),
                  ),
                  if (showDevice) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _unlockWithDevice,
                        icon: const Icon(Icons.fingerprint),
                        label: Text('Unlock with $_deviceName'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _forgotPasscode,
                    child: const Text('Forgot passcode?'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
