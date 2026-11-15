import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/paste_item.dart';
import '../providers/field_config_provider.dart';
import '../providers/providers.dart';
import '../services/clipboard_service.dart';
import '../services/field_extractor.dart';
import '../services/paste_titles.dart';
import '../services/text_utils.dart';
import 'key_cap.dart';
import 'paste_tile.dart';
import 'settings_dialog.dart';
import 'shortcut_labels.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Revealed secrets hide themselves again after this long.
  static const revealDuration = Duration(seconds: 20);

  final ScrollController _scrollController = ScrollController();
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'search');
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _listFocusNode = FocusNode(debugLabel: 'list');
  Timer? _debounce;
  Timer? _hideTimer;

  // Flash state: which item, which field (-1 = whole tile), generation counter.
  String? _flashItemId;
  int _flashFieldIndex = -1;
  int _flashGeneration = 0;
  Timer? _flashTimer;

  // Title editing is reported by the tile.
  bool _isTitleEditing = false;

  // Incremented to make the top tile start editing its title.
  int _editGeneration = 0;

  /// Items whose hidden text is showing, each with its re-hide timer.
  final Map<String, Timer> _revealed = {};

  late final AppLifecycleListener _lifecycle;
  AppLifecycleState? _lastLifecycleState;
  bool _settingsOpen = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycleChanged);
    ref.listenManual<bool>(summonedProvider, (previous, summoned) {
      if (summoned && previous != true) _onSummoned();
      if (!summoned) _hideRevealed();
    });
    ref.listenManual<HotKeyStatus>(hotKeyProvider, (previous, next) {
      if (next.error != null && next.error != previous?.error) {
        _showSnackBar(
          next.error!,
          duration: const Duration(seconds: 6),
          action: SnackBarAction(label: 'Change', onPressed: _openSettings),
        );
      }
    });
    // Turning masking back on (here or in Settings) hides anything revealed.
    ref.listenManual<bool>(settingsProvider.select((s) => s.maskSecrets),
        (_, __) => _hideRevealed());
    WidgetsBinding.instance.addPostFrameCallback((_) => _showStorageNotices());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _scrollController.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    _listFocusNode.dispose();
    _debounce?.cancel();
    _hideTimer?.cancel();
    _flashTimer?.cancel();
    for (final timer in _revealed.values) {
      timer.cancel();
    }
    super.dispose();
  }

  // ── summoning, focus and visibility ──────────────────────

  void _onSummoned() {
    if (!mounted) return;
    if (!_searchFocusNode.hasFocus && !_isTitleEditing) {
      _listFocusNode.requestFocus();
    }
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  void _onLifecycleChanged(AppLifecycleState state) {
    final previous = _lastLifecycleState;
    _lastLifecycleState = state;
    final lostFocus = previous == AppLifecycleState.resumed &&
        state == AppLifecycleState.inactive;
    if (state == AppLifecycleState.hidden || lostFocus) _hideRevealed();
  }

  void _hideWindow() {
    _hideRevealed();
    ref.read(windowControllerProvider).hide();
  }

  /// After copying from a summoned Pastee, get out of the way so the next
  /// paste lands in the app you came from.
  void _hideAfterCopyIfSummoned() {
    if (!ref.read(settingsProvider).hideAfterCopy ||
        !ref.read(summonedProvider)) {
      return;
    }
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted && ref.read(summonedProvider)) _hideWindow();
    });
  }

  void _restoreFocus() {
    if (!mounted) return;
    if (!_searchFocusNode.hasFocus && !_isTitleEditing) {
      _listFocusNode.requestFocus();
    }
  }

  void _focusSearch() => _searchFocusNode.requestFocus();

  Future<void> _openSettings() async {
    if (_settingsOpen || !mounted) return;
    _settingsOpen = true;
    await showSettingsDialog(context);
    _settingsOpen = false;
    _restoreFocus();
  }

  // ── reveal / hide ─────────────────────────────────────────

  bool _isHidden(PasteItem item, Extraction extraction) =>
      !_revealed.containsKey(item.id) &&
      (item.sensitive ||
          (ref.read(settingsProvider).maskSecrets && extraction.hasSecrets));

  void _toggleReveal(String id) {
    final timer = _revealed.remove(id);
    if (timer != null) {
      timer.cancel();
      setState(() {});
      return;
    }
    setState(() {
      _revealed[id] = Timer(revealDuration, () {
        if (mounted) setState(() => _revealed.remove(id));
      });
    });
  }

  void _toggleRevealFirst() {
    _flushSearch();
    final items = ref.read(filteredPasteListProvider);
    if (items.isEmpty) return;
    final item = items.first;
    if (!item.sensitive && !extractFields(ref, item.content).hasSecrets) {
      _showSnackBar('Nothing is hidden in the top item');
      return;
    }
    _toggleReveal(item.id);
  }

  void _hideRevealed() {
    if (_revealed.isEmpty) return;
    for (final timer in _revealed.values) {
      timer.cancel();
    }
    if (mounted) setState(_revealed.clear);
  }

  Future<void> _toggleSensitive(PasteItem item) async {
    final sensitive = !item.sensitive;
    await ref.read(pasteListProvider.notifier).setSensitive(item.id, sensitive);
    _revealed.remove(item.id)?.cancel();
    if (!mounted) return;
    setState(() {});
    _showSnackBar(sensitive
        ? 'This item stays hidden until you reveal it'
        : 'No longer always hidden');
    _restoreFocus();
  }

  // ── copy / paste / cut / delete / undo ───────────────────

  void _triggerFlash(String itemId, [int fieldIndex = -1]) {
    _flashTimer?.cancel();
    setState(() {
      _flashItemId = itemId;
      _flashFieldIndex = fieldIndex;
      _flashGeneration++;
    });
    _flashTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _flashItemId = null);
    });
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) ref.read(searchQueryProvider.notifier).state = query;
    });
  }

  /// Applies a search that is still waiting for its debounce, so Enter or
  /// ⌘1–9 pressed right after typing act on the item the user is looking for.
  void _flushSearch() {
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      ref.read(searchQueryProvider.notifier).state = _searchController.text;
    }
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchController.clear();
    ref.read(searchQueryProvider.notifier).state = '';
  }

  /// Typing while the list has focus starts a search.
  void _typeIntoSearch(String character) {
    final text = _searchController.text + character;
    _searchController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _searchFocusNode.requestFocus();
    _onSearchChanged(text);
    setState(() {});
  }

  Future<void> _pasteFromClipboard() async {
    final text = await ref.read(clipboardServiceProvider).getText();
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) {
      _showSnackBar('The clipboard has no text to save');
      return;
    }
    final notifier = ref.read(pasteListProvider.notifier);
    final existing = notifier.findByContent(text);
    if (existing != null) {
      if (ref.read(filteredPasteListProvider).any((i) => i.id == existing.id)) {
        _triggerFlash(existing.id);
      }
      _showSnackBar('Already in the list');
      return;
    }
    // Show the new item even if a search was hiding it.
    if (_searchController.text.isNotEmpty) _clearSearch();
    try {
      await notifier.addFromClipboard(text);
    } catch (error) {
      _showSnackBar('Couldn’t save the item: $error',
          duration: const Duration(seconds: 6));
      return;
    }
    if (_scrollController.hasClients) {
      _scrollController.animateTo(0,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
    _restoreFocus();
  }

  /// Copies of these get the clipboard's secret treatment: kept out of
  /// clipboard history and cleared again after a while.
  bool _isSecretItem(PasteItem item) =>
      item.sensitive || extractFields(ref, item.content).hasSecrets;

  String _withClearNote(String message, Duration? clearsIn) => clearsIn == null
      ? message
      : '$message · clears in ${describeClearDelay(clearsIn)}';

  Future<void> _copyItem(PasteItem item) async {
    final clearsIn = await ref
        .read(clipboardServiceProvider)
        .setText(item.content, secret: _isSecretItem(item));
    if (!mounted) return;
    _triggerFlash(item.id);
    _restoreFocus();
    _showSnackBar(_withClearNote('Copied to clipboard', clearsIn));
    _hideAfterCopyIfSummoned();
  }

  Future<void> _copyFirstItem() async {
    _flushSearch();
    final items = ref.read(filteredPasteListProvider);
    if (items.isEmpty) return;
    await _copyItem(items.first);
  }

  Future<void> _copyField(PasteItem item, int index) async {
    final extraction = extractFields(ref, item.content);
    if (index < 0 || index >= extraction.fields.length) {
      _showSnackBar('The top item has no field ${index + 1}');
      return;
    }
    final field = extraction.fields[index];
    final clearsIn = await ref
        .read(clipboardServiceProvider)
        .setText(field.value, secret: field.secret || item.sensitive);
    if (!mounted) return;
    _triggerFlash(item.id, index);
    _restoreFocus();
    if (_isHidden(item, extraction)) {
      _showSnackBar(_withClearNote(
          'Copied ${item.sensitive ? safeFieldLabel(field) : field.label}',
          clearsIn));
    } else {
      final preview = truncateGraphemes(
          sanitizeUtf16(field.value.replaceAll('\n', ' ')), 30);
      _showSnackBar(
          _withClearNote('Copied ${field.label}: $preview', clearsIn));
    }
    _hideAfterCopyIfSummoned();
  }

  Future<void> _copyFieldOfFirst(int index) async {
    _flushSearch();
    final items = ref.read(filteredPasteListProvider);
    if (items.isEmpty) return;
    // ⌘N copies the field numbered N, which isn't always the Nth chip: a
    // field can have its own number (Settings → Fields & numbers).
    final fields = extractFields(ref, items.first.content).fields;
    final position = fields.indexWhere((f) => f.number == index + 1);
    if (position < 0) {
      _showSnackBar('The top item has no field ${index + 1}');
      return;
    }
    await _copyField(items.first, position);
  }

  Future<void> _cutFirstItem() async {
    _flushSearch();
    final items = ref.read(filteredPasteListProvider);
    if (items.isEmpty) return;
    final item = items.first;
    final clearsIn = await ref
        .read(clipboardServiceProvider)
        .setText(item.content, secret: _isSecretItem(item));
    await _deleteItem(item,
        message: _withClearNote('Cut to clipboard', clearsIn));
  }

  Future<void> _deleteFirstItem() async {
    _flushSearch();
    final items = ref.read(filteredPasteListProvider);
    if (items.isEmpty) return;
    await _deleteItem(items.first);
  }

  Future<void> _deleteItem(PasteItem item,
      {String message = 'Item deleted'}) async {
    final PasteItem? removed;
    try {
      removed = await ref.read(pasteListProvider.notifier).deleteItem(item.id);
    } catch (error) {
      _showSnackBar('Couldn’t delete the item: $error',
          duration: const Duration(seconds: 6));
      return;
    }
    if (removed == null || !mounted) return;
    _revealed.remove(item.id)?.cancel();
    _restoreFocus();
    _showSnackBar(
      message,
      duration: const Duration(seconds: 4),
      action: SnackBarAction(label: 'Undo', onPressed: _undo),
    );
  }

  Future<void> _undo() async {
    final item = await ref.read(pasteListProvider.notifier).undoDelete();
    if (!mounted) return;
    if (item == null) {
      _showSnackBar('Nothing to undo');
      return;
    }
    _triggerFlash(item.id);
    _restoreFocus();
    final title =
        displayTitle(item, extractFields(ref, item.content), hidden: true);
    _showSnackBar('Restored “${truncateGraphemes(title, 30)}”');
  }

  void _editFirstTitle() {
    _flushSearch();
    if (ref.read(filteredPasteListProvider).isEmpty) return;
    setState(() => _editGeneration++);
  }

  void _lockNow() {
    if (ref.read(appLockProvider).enabled) {
      ref.read(appLockProvider.notifier).lock();
    } else {
      _showSnackBar(
        'Set a passcode in Settings to lock Pastee',
        duration: const Duration(seconds: 4),
        action: SnackBarAction(label: 'Settings', onPressed: _openSettings),
      );
    }
  }

  void _toggleTheme() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    ref
        .read(settingsProvider.notifier)
        .setThemeMode(dark ? ThemeMode.light : ThemeMode.dark);
    _restoreFocus();
  }

  void _toggleMasking() {
    final settings = ref.read(settingsProvider);
    ref.read(settingsProvider.notifier).setMaskSecrets(!settings.maskSecrets);
    _hideRevealed();
    _restoreFocus();
  }

  void _showStorageNotices() {
    if (!mounted || ref.read(storageNoticeShownProvider)) return;
    ref.read(storageNoticeShownProvider.notifier).state = true;
    final report = ref.read(storageReportProvider);
    if (report.unreadableBackup != null) {
      final keyNote = report.unreadableKeyBackup == null
          ? ''
          : ' and the old key at ${report.unreadableKeyBackup}';
      _showSnackBar(
        'Saved items could not be unlocked, so Pastee started a new list. '
        'The old items were kept at ${report.unreadableBackup}$keyNote.',
        duration: const Duration(seconds: 12),
      );
    } else if (report.migratedCount > 0) {
      final n = report.migratedCount;
      _showSnackBar(
          'Moved $n ${n == 1 ? 'item' : 'items'} into encrypted storage',
          duration: const Duration(seconds: 4));
    }
  }

  void _showSnackBar(String message,
      {Duration? duration, SnackBarAction? action}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final available = MediaQuery.sizeOf(context).width - 32;
    final wanted = message.length > 44 || action != null ? 440.0 : 300.0;
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: duration ?? const Duration(seconds: 1),
        width: math.max(160, math.min(wanted, available)),
        action: action,
      ),
    );
  }

  // ── keyboard ─────────────────────────────────────────────

  static final _digitKeys = {
    LogicalKeyboardKey.digit1: 1,
    LogicalKeyboardKey.digit2: 2,
    LogicalKeyboardKey.digit3: 3,
    LogicalKeyboardKey.digit4: 4,
    LogicalKeyboardKey.digit5: 5,
    LogicalKeyboardKey.digit6: 6,
    LogicalKeyboardKey.digit7: 7,
    LogicalKeyboardKey.digit8: 8,
    LogicalKeyboardKey.digit9: 9,
  };

  /// ⌘ on macOS, Ctrl on Windows. AltGr reaches apps as Ctrl+Alt and types
  /// characters such as @ { [ on many layouts, so Ctrl+Alt doesn't count.
  bool get _primaryModifierPressed {
    final keyboard = HardwareKeyboard.instance;
    if (isMacPlatform) return keyboard.isMetaPressed;
    return keyboard.isControlPressed && !keyboard.isAltPressed;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    final inSearch = _searchFocusNode.hasFocus;
    final inTitle = _isTitleEditing;

    // Holding a key never repeats an action: one press, one paste, copy or
    // delete. Text fields still get repeats (holding Backspace keeps erasing).
    if (event is KeyRepeatEvent) {
      return inSearch || inTitle
          ? KeyEventResult.ignored
          : KeyEventResult.handled;
    }

    final key = event.logicalKey;

    if (_primaryModifierPressed) {
      if (key == LogicalKeyboardKey.keyF) {
        _focusSearch();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyE) {
        _editFirstTitle();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.comma) {
        _openSettings();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyR) {
        _toggleRevealFirst();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyL) {
        _lockNow();
        return KeyEventResult.handled;
      }

      // The title field handles its own copy, paste, cut and undo.
      if (inTitle) return KeyEventResult.ignored;

      final digit = _digitKeys[key];
      if (digit != null) {
        _copyFieldOfFirst(digit - 1);
        return KeyEventResult.handled;
      }

      if (inSearch) {
        // Cut, paste, select-all and undo edit the search text. Copy does too
        // when text is selected; otherwise it copies the top result.
        final selection = _searchController.selection;
        final hasSelection = selection.isValid && !selection.isCollapsed;
        if (key == LogicalKeyboardKey.keyC && !hasSelection) {
          _copyFirstItem();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }

      if (key == LogicalKeyboardKey.keyV) {
        _pasteFromClipboard();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyC) {
        _copyFirstItem();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyX) {
        _cutFirstItem();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyZ) {
        _undo();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // The tile handles Enter and Escape while renaming.
    if (inTitle) return KeyEventResult.ignored;

    final isEnter = key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;

    if (inSearch) {
      if (key == LogicalKeyboardKey.escape) {
        _clearSearch();
        _listFocusNode.requestFocus();
        setState(() {});
        return KeyEventResult.handled;
      }
      if (isEnter) {
        _copyFirstItem();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _listFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // The list has focus.
    if (key == LogicalKeyboardKey.escape) {
      if (ref.read(summonedProvider)) _hideWindow();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      _deleteFirstItem();
      return KeyEventResult.handled;
    }
    if (isEnter) {
      _copyFirstItem();
      return KeyEventResult.handled;
    }
    final character = event.character;
    final keyboard = HardwareKeyboard.instance;
    if (character != null &&
        character.trim().isNotEmpty &&
        !character.runes.any((r) => r < 0x20 || r == 0x7F) &&
        !keyboard.isControlPressed &&
        !keyboard.isMetaPressed) {
      _typeIntoSearch(character);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ── build ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(filteredPasteListProvider);
    final settings = ref.watch(settingsProvider);
    final fieldConfig = ref.watch(fieldConfigProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Focus(
      autofocus: true,
      focusNode: _listFocusNode,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        body: Column(
          children: [
            _buildHeader(theme, colorScheme, items.length),
            Expanded(
              child: items.isEmpty
                  ? _buildEmptyState(theme, colorScheme)
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: items.length,
                      padding: const EdgeInsets.only(top: 4, bottom: 16),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final isFirst = index == 0;
                        return PasteTile(
                          key: ValueKey(item.id),
                          item: item,
                          extraction: FieldExtractor.extract(item.content,
                              config: fieldConfig),
                          isFirst: isFirst,
                          maskSecrets: settings.maskSecrets,
                          revealed: _revealed.containsKey(item.id),
                          flashGeneration:
                              item.id == _flashItemId ? _flashGeneration : 0,
                          flashFieldIndex:
                              item.id == _flashItemId ? _flashFieldIndex : -1,
                          editGeneration: isFirst ? _editGeneration : 0,
                          onTap: () => _copyItem(item),
                          onTitleChanged: (t) => ref
                              .read(pasteListProvider.notifier)
                              .updateTitle(item.id, t),
                          onFieldCopy: (_, fieldIndex) =>
                              _copyField(item, fieldIndex),
                          onDelete: () => _deleteItem(item),
                          onToggleReveal: () => _toggleReveal(item.id),
                          onToggleSensitive: () => _toggleSensitive(item),
                          onEditingChanged: (editing) {
                            if (!mounted) return;
                            setState(() => _isTitleEditing = editing);
                            if (!editing) _restoreFocus();
                          },
                        );
                      },
                    ),
            ),
            _buildSearchBar(theme, colorScheme),
            _buildHints(),
          ],
        ),
      ),
    );
  }

  // ── header ───────────────────────────────────────────────

  Widget _buildHeader(ThemeData theme, ColorScheme colorScheme, int itemCount) {
    final hotKey = ref.watch(hotKeyProvider);
    final maskSecrets =
        ref.watch(settingsProvider.select((s) => s.maskSecrets));
    final isDark = theme.brightness == Brightness.dark;
    final spec = hotKey.spec;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.content_paste_rounded,
              color: colorScheme.primary, size: 22),
          const SizedBox(width: 10),
          Text('Pastee',
              style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700, color: colorScheme.onSurface)),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('$itemCount',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600)),
          ),
          if (hotKey.active && spec != null)
            // Right-aligned in the free space, and scaled down rather than
            // overflowing if a long custom shortcut meets a narrow window.
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Tooltip(
                      message:
                          'Press ${spec.display} in any app to show or hide Pastee',
                      child: KeyCap(
                        spec.display,
                        label: constraints.maxWidth >= 150 ? 'Summon' : null,
                        emphasized: true,
                      ),
                    ),
                  ),
                ),
              ),
            )
          else ...[
            const Spacer(),
            if (hotKey.error != null)
              _HeaderButton(
                icon: Icons.keyboard_alt_outlined,
                tooltip:
                    'The summon shortcut isn’t working. Click to pick another.',
                color: colorScheme.error,
                onTap: _openSettings,
              ),
          ],
          const SizedBox(width: 6),
          _HeaderButton(
            icon: maskSecrets
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            tooltip: maskSecrets
                ? 'Passwords and secrets are hidden. Click to show them.'
                : 'Passwords and secrets are visible. Click to hide them.',
            onTap: _toggleMasking,
          ),
          _HeaderButton(
            icon: isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            tooltip: isDark ? 'Switch to light mode' : 'Switch to dark mode',
            onTap: _toggleTheme,
          ),
          if (ref.watch(appLockProvider.select((s) => s.enabled)))
            _HeaderButton(
              icon: Icons.lock_outline,
              tooltip: 'Lock Pastee (${primaryShortcut('L')})',
              onTap: _lockNow,
            ),
          _HeaderButton(
            icon: Icons.settings_outlined,
            tooltip: 'Settings (${primaryShortcut(',')})',
            onTap: _openSettings,
          ),
        ],
      ),
    );
  }

  // ── empty / search / hints ───────────────────────────────

  Widget _buildEmptyState(ThemeData theme, ColorScheme colorScheme) {
    final searching = ref.watch(searchQueryProvider).isNotEmpty;
    final hotKey = ref.watch(hotKeyProvider);
    final faded = colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
                searching ? Icons.search_off : Icons.content_paste_off_outlined,
                size: 64,
                color: faded.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(searching ? 'Nothing matches your search' : 'No items yet',
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: faded.withValues(alpha: 0.5))),
            const SizedBox(height: 8),
            Text(
              searching
                  ? 'Press Esc to clear the search'
                  : 'Copy something, then press ${primaryShortcut('V')} here to save it',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: faded.withValues(alpha: 0.5)),
            ),
            if (!searching && hotKey.active && hotKey.spec != null) ...[
              const SizedBox(height: 4),
              Text(
                'Press ${hotKey.spec!.display} in any app to bring Pastee back',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: faded.withValues(alpha: 0.5)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
        ),
      ),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        onChanged: (query) {
          _onSearchChanged(query);
          setState(() {});
        },
        style:
            theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurface),
        decoration: InputDecoration(
          hintText: 'Search… (${primaryShortcut('F')}, or just start typing)',
          hintStyle: TextStyle(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              fontSize: 13),
          prefixIcon: Icon(Icons.search,
              size: 20,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _clearSearch();
                    setState(() {});
                  },
                )
              : null,
          isDense: true,
          filled: true,
          fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                  color: colorScheme.primary.withValues(alpha: 0.5),
                  width: 1.5)),
        ),
      ),
    );
  }

  Widget _buildHints() {
    final hints = [
      (primaryShortcut('V'), 'Paste'),
      (primaryShortcut('C'), 'Copy'),
      (primaryShortcut('1–9'), 'Field'),
      (primaryShortcut('X'), 'Cut'),
      (primaryShortcut('Z'), 'Undo'),
      (primaryShortcut('F'), 'Find'),
      (primaryShortcut(','), 'Settings'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (keys, label) in hints) KeyCap(keys, label: label)
          ],
        ),
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 34,
        height: 34,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            canRequestFocus: false,
            onTap: onTap,
            child: Center(
              child: Icon(icon, size: 20, color: color ?? cs.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }
}
