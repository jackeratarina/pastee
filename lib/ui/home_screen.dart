import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pastee/providers/providers.dart';
import 'package:pastee/services/field_extractor.dart';
import 'package:pastee/ui/paste_tile.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final ScrollController _scrollController = ScrollController();
  final FocusNode _searchFocusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _listFocusNode = FocusNode();
  Timer? _debounce;

  // Flash state: which item, which field (-1 = whole tile), generation counter
  String? _flashItemId;
  int _flashFieldIndex = -1;
  int _flashGeneration = 0;
  Timer? _flashTimer;

  // Title editing: tracked via callback from PasteTile
  bool _isTitleEditing = false;

  // Edit-title trigger for first item (increment to trigger)
  int _editGeneration = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    _listFocusNode.dispose();
    _debounce?.cancel();
    _flashTimer?.cancel();
    super.dispose();
  }

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
      ref.read(searchQueryProvider.notifier).state = query;
    });
  }

  // ── copy / paste / cut / delete ──────────────────────────

  Future<void> _pasteFromClipboard() async {
    final clipboard = ref.read(clipboardServiceProvider);
    final text = await clipboard.getText();
    if (text == null || text.trim().isEmpty) return;

    final notifier = ref.read(pasteListProvider.notifier);
    if (notifier.containsContent(text)) {
      if (mounted) _showSnackBar('Already in list');
      return;
    }

    await notifier.addFromClipboard(text);
    if (_scrollController.hasClients) {
      _scrollController.animateTo(0,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
    _restoreFocus();
  }

  Future<void> _copyFirstItem() async {
    final items = ref.read(filteredPasteListProvider);
    if (items.isEmpty) return;

    final clipboard = ref.read(clipboardServiceProvider);
    await clipboard.setText(items[0].content);
    _triggerFlash(items[0].id, -1);
    _restoreFocus();

    if (mounted) _showSnackBar('Copied to clipboard');
  }

  Future<void> _copyExtractedField(int fieldNumber) async {
    final items = ref.read(filteredPasteListProvider);
    if (items.isEmpty) return;

    final item = items[0];
    final fields = FieldExtractor.extract(item.content);
    if (fieldNumber < 1 || fieldNumber > fields.length) {
      if (mounted) _showSnackBar('No field $fieldNumber');
      return;
    }

    final field = fields[fieldNumber - 1];
    final clipboard = ref.read(clipboardServiceProvider);
    await clipboard.setText(field.value);
    _triggerFlash(item.id, fieldNumber - 1);
    _restoreFocus();

    final preview = field.value.length > 30
        ? '${field.value.substring(0, 28)}…'
        : field.value;
    if (mounted) _showSnackBar('${field.type}: $preview');
  }

  Future<void> _copyFieldValue(
      String value, String itemId, int fieldIndex) async {
    final clipboard = ref.read(clipboardServiceProvider);
    await clipboard.setText(value);
    _triggerFlash(itemId, fieldIndex);
    _restoreFocus();

    final preview =
        value.length > 30 ? '${value.substring(0, 28)}…' : value;
    if (mounted) _showSnackBar('Copied: $preview');
  }

  Future<void> _cutFirstItem() async {
    final items = ref.read(filteredPasteListProvider);
    if (items.isEmpty) return;

    final clipboard = ref.read(clipboardServiceProvider);
    await clipboard.setText(items[0].content);
    await ref.read(pasteListProvider.notifier).deleteItem(items[0].id);
    _restoreFocus();

    if (mounted) _showSnackBar('Cut to clipboard');
  }

  Future<void> _deleteFirstItem() async {
    final items = ref.read(filteredPasteListProvider);
    if (items.isEmpty) return;

    await ref.read(pasteListProvider.notifier).deleteItem(items[0].id);
    _restoreFocus();

    if (mounted) _showSnackBar('Item removed');
  }

  Future<void> _onItemTap(String itemId, String content) async {
    final clipboard = ref.read(clipboardServiceProvider);
    await clipboard.setText(content);
    _triggerFlash(itemId, -1);
    _restoreFocus();

    if (mounted) _showSnackBar('Copied to clipboard');
  }

  void _editFirstTitle() {
    final items = ref.read(filteredPasteListProvider);
    if (items.isEmpty) return;
    setState(() => _editGeneration++);
  }

  // ── focus management ─────────────────────────────────────

  void _restoreFocus() {
    if (!mounted) return;
    if (!_searchFocusNode.hasFocus && !_isTitleEditing) {
      _listFocusNode.requestFocus();
    }
  }

  void _focusSearch() => _searchFocusNode.requestFocus();

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
        width: 280,
      ),
    );
  }

  // ── platform ─────────────────────────────────────────────

  bool get _isMacOS {
    try {
      return Platform.isMacOS;
    } catch (_) {
      return false;
    }
  }

  bool get _isModifierKey => _isMacOS
      ? HardwareKeyboard.instance.isMetaPressed
      : HardwareKeyboard.instance.isControlPressed;

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

  // ── key handler ──────────────────────────────────────────

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    // Modifier shortcuts
    if (_isModifierKey) {
      // Cmd+F always works
      if (key == LogicalKeyboardKey.keyF) {
        _focusSearch();
        return KeyEventResult.handled;
      }

      // Cmd+E always edits first item title
      if (key == LogicalKeyboardKey.keyE) {
        _editFirstTitle();
        return KeyEventResult.handled;
      }

      // While editing a title, let text field handle Cmd+C/V/A/X natively
      if (_isTitleEditing) return KeyEventResult.ignored;

      // Modifier + digit → copy Nth extracted field from first item
      final digit = _digitKeys[key];
      if (digit != null) {
        _copyExtractedField(digit);
        return KeyEventResult.handled;
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
    }

    // Escape from title editing
    if (_isTitleEditing) {
      if (key == LogicalKeyboardKey.escape) {
        _listFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Escape from search
    if (_searchFocusNode.hasFocus) {
      if (key == LogicalKeyboardKey.escape) {
        _searchController.clear();
        ref.read(searchQueryProvider.notifier).state = '';
        _listFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Non-modifier shortcuts (list focused)
    if (key == LogicalKeyboardKey.escape) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      _deleteFirstItem();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // ── build ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(filteredPasteListProvider);
    final isDark = ref.watch(themeProvider);
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
            _buildHeader(theme, colorScheme, isDark, items.length),
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
                          isFirst: isFirst,
                          flashGeneration: item.id == _flashItemId
                              ? _flashGeneration
                              : 0,
                          flashFieldIndex: item.id == _flashItemId
                              ? _flashFieldIndex
                              : -1,
                          editGeneration:
                              isFirst ? _editGeneration : 0,
                          onTap: () =>
                              _onItemTap(item.id, item.content),
                          onTitleChanged: (t) => ref
                              .read(pasteListProvider.notifier)
                              .updateTitle(item.id, t),
                          onFieldCopy: (v, fi) =>
                              _copyFieldValue(v, item.id, fi),
                          onDelete: () => ref
                              .read(pasteListProvider.notifier)
                              .deleteItem(item.id),
                          onEditingChanged: (editing) {
                            setState(
                                () => _isTitleEditing = editing);
                            if (!editing) _restoreFocus();
                          },
                        );
                      },
                    ),
            ),
            _buildSearchBar(theme, colorScheme),
          ],
        ),
      ),
    );
  }

  // ── header ───────────────────────────────────────────────

  Widget _buildHeader(
    ThemeData theme,
    ColorScheme colorScheme,
    bool isDark,
    int itemCount,
  ) {
    final mod = _isMacOS ? '⌘' : '^';
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(
              color: colorScheme.outlineVariant.withOpacity(0.3)),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.content_paste_rounded,
              color: colorScheme.primary, size: 22),
          const SizedBox(width: 10),
          Text('Pastee',
              style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface)),
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
          const Spacer(),
          _hint(colorScheme, '${mod}V', 'Paste'),
          const SizedBox(width: 6),
          _hint(colorScheme, '${mod}C', 'Copy'),
          const SizedBox(width: 6),
          _hint(colorScheme, '${mod}1-9', 'Field'),
          const SizedBox(width: 6),
          _hint(colorScheme, '${mod}X', 'Cut'),
          const SizedBox(width: 6),
          _hint(colorScheme, '${mod}E', 'Edit'),
          const SizedBox(width: 6),
          _hint(colorScheme, '${mod}F', 'Find'),
          const SizedBox(width: 10),
          Tooltip(
            message:
                isDark ? 'Switch to light mode' : 'Switch to dark mode',
            child: SizedBox(
              width: 34,
              height: 34,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  canRequestFocus: false,
                  onTap: () {
                    ref.read(themeProvider.notifier).toggle();
                    _restoreFocus();
                  },
                  child: Center(
                    child: Icon(
                        isDark
                            ? Icons.light_mode_outlined
                            : Icons.dark_mode_outlined,
                        size: 20,
                        color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hint(ColorScheme cs, String keys, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(keys,
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                  color: cs.onSurfaceVariant.withOpacity(0.7))),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 10,
                  color: cs.onSurfaceVariant.withOpacity(0.5))),
        ],
      ),
    );
  }

  // ── empty / search ───────────────────────────────────────

  Widget _buildEmptyState(ThemeData theme, ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.content_paste_off_outlined,
              size: 64,
              color: colorScheme.onSurfaceVariant.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text('No items yet',
              style: theme.textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant.withOpacity(0.5))),
          const SizedBox(height: 8),
          Text(
              _isMacOS
                  ? 'Press ⌘V to paste from clipboard'
                  : 'Press Ctrl+V to paste from clipboard',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant.withOpacity(0.4))),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
              color: colorScheme.outlineVariant.withOpacity(0.3)),
        ),
      ),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        onChanged: _onSearchChanged,
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: colorScheme.onSurface),
        decoration: InputDecoration(
          hintText: 'Search items… (${_isMacOS ? "⌘F" : "Ctrl+F"})',
          hintStyle: TextStyle(
              color: colorScheme.onSurfaceVariant.withOpacity(0.4),
              fontSize: 13),
          prefixIcon: Icon(Icons.search,
              size: 20,
              color: colorScheme.onSurfaceVariant.withOpacity(0.5)),
          suffixIcon: _searchController.text.isNotEmpty
              ? GestureDetector(
                  onTap: () {
                    _searchController.clear();
                    ref.read(searchQueryProvider.notifier).state = '';
                    setState(() {});
                  },
                  child: const Icon(Icons.clear, size: 18),
                )
              : null,
          isDense: true,
          filled: true,
          fillColor: colorScheme.surfaceVariant.withOpacity(0.4),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                  color: colorScheme.primary.withOpacity(0.5),
                  width: 1.5)),
        ),
      ),
    );
  }
}
