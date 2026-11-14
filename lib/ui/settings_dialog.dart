import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/hotkey.dart';
import '../providers/providers.dart';
import '../services/app_lock.dart';
import '../version.dart';
import 'key_cap.dart';
import 'passcode_dialogs.dart';
import 'shortcut_labels.dart';
import 'theme.dart';

Future<void> showSettingsDialog(BuildContext context) {
  return showDialog<void>(
      context: context, builder: (_) => const SettingsDialog());
}

class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key});

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  static const _off = 'off';
  static const _custom = 'custom';

  final FocusNode _recorderFocus = FocusNode(debugLabel: 'shortcut recorder');
  late final HotKeyNotifier _hotKeys = ref.read(hotKeyProvider.notifier);
  bool _recording = false;
  String? _recordMessage;
  bool _deviceAvailable = false;
  String _deviceName = 'Touch ID';

  static final _modifierKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.fn,
  };

  @override
  void initState() {
    super.initState();
    _checkDevice();
  }

  Future<void> _checkDevice() async {
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

  void _notify(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), width: 340),
    );
  }

  Future<void> _setUpLock() async {
    final passcode = await showNewPasscodeDialog(context);
    if (passcode == null || !mounted) return;
    await ref.read(appLockProvider.notifier).setPasscode(passcode);
    if (mounted) _notify('App Lock is on');
  }

  Future<void> _changePasscode() async {
    if (!await confirmPasscode(context, title: 'Change passcode')) return;
    if (!mounted) return;
    final passcode =
        await showNewPasscodeDialog(context, title: 'New passcode');
    if (passcode == null || !mounted) return;
    await ref.read(appLockProvider.notifier).setPasscode(passcode);
    if (mounted) _notify('Passcode changed');
  }

  Future<void> _turnOffLock() async {
    if (!await confirmPasscode(context,
        title: 'Turn off App Lock', action: 'Turn off')) {
      return;
    }
    await ref.read(appLockProvider.notifier).disable();
    if (mounted) _notify('App Lock is off');
  }

  Future<void> _setDeviceUnlock(bool on) async {
    final lock = ref.read(appLockProvider.notifier);
    if (on) {
      // Adding another way in needs the passcode first: on a Mac the system
      // prompt also accepts the login password.
      if (!await confirmPasscode(context,
          title: 'Turn on $_deviceName', action: 'Continue')) {
        return;
      }
      // Then make sure it actually works on this computer.
      final ok = await lock.testDevice('Use $_deviceName to unlock Pastee');
      if (!ok) {
        if (mounted) _notify('$_deviceName didn’t confirm it was you');
        return;
      }
    }
    await lock.setDeviceUnlock(on);
  }

  /// Choosing a stricter relock is free; a looser one needs the passcode.
  Future<void> _setTimeout(LockTimeout timeout) async {
    final current = ref.read(appLockProvider).timeout;
    if (timeout.index > current.index &&
        !await confirmPasscode(context,
            title: 'Lock Pastee less often', action: 'Change')) {
      return;
    }
    await ref.read(appLockProvider.notifier).setTimeout(timeout);
  }

  String _timeoutLabel(LockTimeout timeout) {
    // On a Mac, closing the window doesn't quit Pastee, so say what this means.
    if (timeout == LockTimeout.onlyAtLaunch && isMacPlatform) {
      return 'Only when Pastee starts (not when closed)';
    }
    return timeout.label;
  }

  @override
  void dispose() {
    if (_recording) _hotKeys.resume();
    _recorderFocus.dispose();
    super.dispose();
  }

  void _startRecording() {
    setState(() {
      _recording = true;
      _recordMessage = null;
    });
    // Release the current shortcut so pressing it here records it instead of
    // hiding the window.
    _hotKeys.pause();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recorderFocus.requestFocus();
    });
  }

  Future<void> _stopRecording([HotKeySpec? spec]) async {
    setState(() => _recording = false);
    final current = ref.read(settingsProvider).summonHotKey;
    if (spec != null && spec != current) {
      await ref.read(settingsProvider.notifier).setSummonHotKey(spec);
    } else {
      await _hotKeys.resume();
    }
  }

  KeyEventResult _onRecorderKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _stopRecording();
      return KeyEventResult.handled;
    }
    if (_modifierKeys.contains(key)) return KeyEventResult.handled;

    final keyboard = HardwareKeyboard.instance;
    final modifiers = {
      if (keyboard.isControlPressed) KeyModifier.control,
      if (keyboard.isAltPressed) KeyModifier.alt,
      if (keyboard.isShiftPressed) KeyModifier.shift,
      if (keyboard.isMetaPressed) KeyModifier.meta,
    };
    final spec = HotKeySpec.fromKeyEvent(event, modifiers);
    if (spec == null) {
      setState(() => _recordMessage =
          'That key can’t be used. Try a letter, a number, Space or an F-key.');
      return KeyEventResult.handled;
    }
    final problem = spec.problem;
    if (problem != null) {
      setState(() => _recordMessage = problem);
      return KeyEventResult.handled;
    }
    _stopRecording(spec);
    return KeyEventResult.handled;
  }

  String _choiceFor(HotKeySpec? spec, List<HotKeyPreset> presets) {
    if (spec == null) return _off;
    final index = presets.indexWhere((p) => p.spec == spec);
    return index >= 0 ? 'preset:$index' : _custom;
  }

  void _onChoice(String? choice, List<HotKeyPreset> presets) {
    if (choice == null) return;
    final settings = ref.read(settingsProvider.notifier);
    if (choice == _off) {
      settings.setSummonHotKey(null);
    } else if (choice == _custom) {
      _startRecording();
    } else {
      settings.setSummonHotKey(presets[int.parse(choice.split(':').last)].spec);
    }
  }

  Future<void> _confirmDeleteAll() async {
    final count = ref.read(pasteListProvider).length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all items?'),
        content: Text(
            'This removes all $count saved ${count == 1 ? 'item' : 'items'}. It can’t be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(pasteListProvider.notifier).clearAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('Deleted $count ${count == 1 ? 'item' : 'items'}'),
          width: 300),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = ref.watch(settingsProvider);
    final status = ref.watch(hotKeyProvider);
    final report = ref.watch(storageReportProvider);
    final presets = recommendedHotKeys();
    final current = settings.summonHotKey;
    final isCustom = current != null && !presets.any((p) => p.spec == current);

    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
              child: Row(
                children: [
                  Text('Settings', style: theme.textTheme.titleLarge),
                  const Spacer(),
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
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SectionTitle('App Lock'),
                    _buildAppLock(theme, cs),
                    const SizedBox(height: 20),
                    const _SectionTitle('Summon shortcut'),
                    _HotKeyStatusLine(status: status),
                    const SizedBox(height: 4),
                    RadioGroup<String>(
                      groupValue: _choiceFor(current, presets),
                      onChanged: (choice) => _onChoice(choice, presets),
                      child: Column(
                        children: [
                          for (var i = 0; i < presets.length; i++)
                            RadioListTile<String>(
                              value: 'preset:$i',
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Row(
                                children: [
                                  KeyCap(presets[i].spec.display,
                                      emphasized: true),
                                  if (presets[i].recommended) ...[
                                    const SizedBox(width: 8),
                                    Text('Recommended',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                                color: cs.primary,
                                                fontWeight: FontWeight.w600)),
                                  ],
                                ],
                              ),
                              subtitle: Text(presets[i].note),
                            ),
                          RadioListTile<String>(
                            value: _custom,
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: isCustom
                                ? Row(children: [
                                    KeyCap(current.display, emphasized: true),
                                    const SizedBox(width: 8),
                                    const Text('Your own'),
                                  ])
                                : const Text('Your own shortcut…'),
                            subtitle: const Text(
                                'Record any combination with two modifier keys.'),
                            secondary: TextButton(
                              onPressed: _recording ? null : _startRecording,
                              child: const Text('Record'),
                            ),
                          ),
                          const RadioListTile<String>(
                            value: _off,
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('Off'),
                            subtitle: Text(
                                'Pastee only reacts while its window is in front.'),
                          ),
                        ],
                      ),
                    ),
                    if (_recording) _buildRecorder(theme, cs),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Hide Pastee after copying'),
                      subtitle: const Text(
                          'Only when you opened it with the shortcut, so the next paste lands in the app you came from.'),
                      value: settings.hideAfterCopy,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setHideAfterCopy(v),
                    ),
                    if (isMacPlatform)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'Closing the window keeps Pastee running so the shortcut keeps working. Quit with ⌘Q.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ),
                    const SizedBox(height: 20),
                    const _SectionTitle('Privacy'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Hide passwords and secrets'),
                      subtitle: const Text(
                          'Detected passwords, API keys, card numbers and one-time codes show as •••• until you click the eye. Copying always copies the real text.'),
                      value: settings.maskSecrets,
                      onChanged: (v) =>
                          ref.read(settingsProvider.notifier).setMaskSecrets(v),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                            report.encrypted
                                ? Icons.lock_outline
                                : Icons.lock_open,
                            size: 16,
                            color: cs.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                report.encrypted
                                    ? 'Items are stored encrypted on this computer and never leave it.'
                                    : 'Items are kept in memory only.',
                                style: theme.textTheme.bodySmall,
                              ),
                              if (report.dataPath != null)
                                SelectableText(
                                  report.dataPath!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontFamily: AppTheme.monoFont,
                                    fontFamilyFallback: AppTheme.monoFallback,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _confirmDeleteAll,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                      label: const Text('Delete all items…'),
                      style:
                          OutlinedButton.styleFrom(foregroundColor: cs.error),
                    ),
                    const SizedBox(height: 20),
                    const _SectionTitle('Appearance'),
                    SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                            value: ThemeMode.system,
                            label: Text('System'),
                            icon: Icon(Icons.brightness_auto_outlined)),
                        ButtonSegment(
                            value: ThemeMode.light,
                            label: Text('Light'),
                            icon: Icon(Icons.light_mode_outlined)),
                        ButtonSegment(
                            value: ThemeMode.dark,
                            label: Text('Dark'),
                            icon: Icon(Icons.dark_mode_outlined)),
                      ],
                      selected: {settings.themeMode},
                      onSelectionChanged: (s) => ref
                          .read(settingsProvider.notifier)
                          .setThemeMode(s.first),
                    ),
                    const SizedBox(height: 20),
                    const _SectionTitle('Keyboard shortcuts in Pastee'),
                    for (final (keys, action) in inAppShortcuts())
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                                width: 96,
                                child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: KeyCap(keys))),
                            Expanded(
                                child: Text(action,
                                    style: theme.textTheme.bodySmall)),
                          ],
                        ),
                      ),
                    const SizedBox(height: 20),
                    Text('Pastee $appVersion',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppLock(ThemeData theme, ColorScheme cs) {
    final lock = ref.watch(appLockProvider);
    if (!lock.enabled) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ask for a passcode${_deviceAvailable ? ' or $_deviceName' : ''} before Pastee shows your items.',
            style:
                theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _setUpLock,
            icon: const Icon(Icons.lock_outline, size: 18),
            label: const Text('Set a passcode…'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.lock, size: 16, color: Colors.green.shade600),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'On. Pastee asks for your passcode when it starts'
                '${lock.timeout == LockTimeout.onlyAtLaunch ? '.' : ' and when it locks again.'}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.green.shade700),
              ),
            ),
          ],
        ),
        if (_deviceAvailable)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text('Unlock with $_deviceName'),
            subtitle: Text(isMacPlatform
                ? 'Your Mac password also works in that prompt. So does the passcode.'
                : 'Your Windows Hello PIN also works in that prompt. So does the passcode.'),
            value: lock.deviceUnlock,
            onChanged: _setDeviceUnlock,
          ),
        Row(
          children: [
            Text('Lock again', style: theme.textTheme.bodyMedium),
            const SizedBox(width: 16),
            Expanded(
              child: DropdownButton<LockTimeout>(
                isExpanded: true,
                value: lock.timeout,
                onChanged: (t) {
                  if (t != null) _setTimeout(t);
                },
                items: [
                  for (final t in LockTimeout.values)
                    DropdownMenuItem(
                      value: t,
                      child: Text(_timeoutLabel(t),
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
                onPressed: _changePasscode,
                child: const Text('Change passcode…')),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                ref.read(appLockProvider.notifier).lock();
              },
              icon: const Icon(Icons.lock_outline, size: 18),
              label: Text('Lock now (${primaryShortcut('L')})'),
            ),
            TextButton(
              onPressed: _turnOffLock,
              style: TextButton.styleFrom(foregroundColor: cs.error),
              child: const Text('Turn off…'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRecorder(ThemeData theme, ColorScheme cs) {
    return Focus(
      focusNode: _recorderFocus,
      onKeyEvent: _onRecorderKey,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.primary, width: 1.5),
        ),
        child: Row(
          children: [
            Icon(Icons.keyboard_outlined, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Press the shortcut you want…',
                      style: theme.textTheme.bodyMedium),
                  Text(
                    _recordMessage ?? 'Esc cancels.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _recordMessage != null
                          ? cs.error
                          : cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
                onPressed: () => _stopRecording(), child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _HotKeyStatusLine extends StatelessWidget {
  const _HotKeyStatusLine({required this.status});

  final HotKeyStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final (IconData icon, Color color, String text) = switch (status) {
      HotKeyStatus(supported: false) => (
          Icons.info_outline,
          cs.onSurfaceVariant,
          'The summon shortcut works in the macOS and Windows apps.',
        ),
      HotKeyStatus(error: final String error) => (
          Icons.error_outline,
          cs.error,
          error
        ),
      HotKeyStatus(active: true, spec: final HotKeySpec spec) => (
          Icons.check_circle_outline,
          Colors.green.shade600,
          'Press ${spec.display} in any app to show or hide Pastee.',
        ),
      HotKeyStatus(spec: null) => (
          Icons.keyboard_hide_outlined,
          cs.onSurfaceVariant,
          'Off.'
        ),
      _ => (
          Icons.hourglass_empty,
          cs.onSurfaceVariant,
          'Setting up the shortcut…'
        ),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
            child: Text(text,
                style: theme.textTheme.bodySmall?.copyWith(color: color))),
      ],
    );
  }
}
