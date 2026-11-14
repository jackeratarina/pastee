import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
  AppLifecycleState? _lastState;
  DateTime _lastActivity = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycleChanged);
    HardwareKeyboard.instance.addHandler(_onKey);
    // App Lock assumes Pastee starts in front; tell it if it doesn't.
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) {
      _lastState = state;
      ref
          .read(appLockProvider.notifier)
          .wentAway(hidden: state != AppLifecycleState.inactive);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _lifecycle.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    _activity();
    return false; // only watching, never handling
  }

  /// Any input while unlocked restarts App Lock's idle countdown.
  void _activity() {
    final now = DateTime.now();
    if (now.difference(_lastActivity) < const Duration(seconds: 1)) return;
    _lastActivity = now;
    ref.read(appLockProvider.notifier).userActive();
  }

  void _onLifecycleChanged(AppLifecycleState state) {
    final previous = _lastState;
    _lastState = state;
    final lock = ref.read(appLockProvider.notifier);
    switch (state) {
      case AppLifecycleState.resumed:
        lock.cameBack();
        ref.read(windowControllerProvider).cameToFront();
      case AppLifecycleState.inactive:
        lock.wentAway(hidden: false);
      case AppLifecycleState.hidden ||
            AppLifecycleState.paused ||
            AppLifecycleState.detached:
        lock.wentAway(hidden: true);
        // Hidden some other way (minimize button, ⌘H, closing on macOS):
        // cover the items in case the OS takes a fresh snapshot.
        if (ref.read(appLockProvider).enabled) {
          ref.read(privacyCoverProvider.notifier).state = true;
          SchedulerBinding.instance.scheduleForcedFrame();
        }
    }
    // A summoned Pastee stops being "summoned" once you leave it.
    final lostFocus = previous == AppLifecycleState.resumed &&
        state == AppLifecycleState.inactive;
    if (state == AppLifecycleState.hidden || lostFocus) {
      ref.read(summonedProvider.notifier).state = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(appLockProvider.select((s) => s.locked),
        (wasLocked, locked) {
      if (locked && wasLocked == false) {
        // Dialogs and snackbars sit above the items; close them now, without
        // an exit animation that would keep them on screen a moment longer.
        Navigator.of(context).popUntil((route) => route.isFirst);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..removeCurrentSnackBar();
        ref.read(searchQueryProvider.notifier).state = '';
        // Locked while hidden: draw the lock screen anyway, so that's what a
        // window snapshot shows.
        if (WidgetsBinding.instance.lifecycleState !=
            AppLifecycleState.resumed) {
          SchedulerBinding.instance.scheduleForcedFrame();
        }
      }
    });
    final locked = ref.watch(appLockProvider.select((s) => s.locked));
    if (locked) return const LockScreen();
    final covered = ref.watch(privacyCoverProvider);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _activity(),
      onPointerHover: (_) => _activity(),
      onPointerSignal: (_) => _activity(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (covered) const Positioned.fill(child: _PrivacyCover()),
        ],
      ),
    );
  }
}

/// What a hidden Pastee leaves behind when App Lock is on: nothing readable.
class _PrivacyCover extends StatelessWidget {
  const _PrivacyCover();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AbsorbPointer(
      child: ColoredBox(
        color: cs.surface,
        child: Center(
          child: Icon(Icons.content_paste_rounded,
              size: 48, color: cs.primary.withValues(alpha: 0.35)),
        ),
      ),
    );
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
  late final AppLifecycleListener _lifecycle;
  String? _message;
  bool _busy = false;
  bool _deviceAvailable = false;
  String _deviceName = 'Touch ID';
  bool _promptOnResume = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Touch ID / Windows Hello is offered when someone brings Pastee to the
    // front: never at the moment it locks (face unlock would undo ⌘L at
    // once) and never while it's hidden. The system prompt itself only makes
    // Pastee inactive, not hidden, so cancelling it doesn't re-prompt.
    _lifecycle = AppLifecycleListener(
      onShow: () => _promptOnResume = true,
      onResume: () {
        if (!_promptOnResume) return;
        _promptOnResume = false;
        _autoPrompt();
      },
    );
    _startTickerIfLockedOut();
    _checkDevice();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
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
    // At launch, offer it straight away if Pastee is already in front.
    if (ref.read(appLockProvider.notifier).isLaunchLock) {
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == null || state == AppLifecycleState.resumed) {
        _autoPrompt();
      } else {
        _promptOnResume = true;
      }
    }
  }

  void _autoPrompt() {
    if (!mounted || _busy || !_deviceAvailable) return;
    if (!ref.read(appLockProvider).deviceUnlock) return;
    _unlockWithDevice();
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
      builder: (_) => _ErasePasscodeDialog(
        deviceHint: lock.deviceUnlock && _deviceAvailable ? _deviceName : null,
      ),
    );
    if (erase != true || !mounted) return;
    await ref.read(pasteListProvider.notifier).clearAll();
    await ref.read(appLockProvider.notifier).disable();
  }

  void _hideIfSummoned() {
    if (ref.read(summonedProvider)) ref.read(windowControllerProvider).hide();
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

/// Erasing everything takes typing ERASE, so a passer-by can't wipe your
/// items with two clicks.
class _ErasePasscodeDialog extends StatefulWidget {
  const _ErasePasscodeDialog({this.deviceHint});

  /// "Touch ID" etc. if that can still unlock.
  final String? deviceHint;

  @override
  State<_ErasePasscodeDialog> createState() => _ErasePasscodeDialogState();
}

class _ErasePasscodeDialogState extends State<_ErasePasscodeDialog> {
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  bool get _confirmed => _confirm.text.trim().toUpperCase() == 'ERASE';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Forgot your passcode?'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text([
              'Pastee can’t recover your passcode.',
              if (widget.deviceHint != null)
                'You can still unlock with ${widget.deviceHint}, then set a new passcode in Settings.',
              'Or erase all saved items and turn App Lock off. This can’t be undone.',
            ].join('\n\n')),
            const SizedBox(height: 16),
            TextField(
              controller: _confirm,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Type ERASE to confirm',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
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
          onPressed: _confirmed ? () => Navigator.pop(context, true) : null,
          child: const Text('Erase all items'),
        ),
      ],
    );
  }
}
