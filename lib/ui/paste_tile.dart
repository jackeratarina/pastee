import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/paste_item.dart';
import '../services/field_extractor.dart';
import '../services/masking.dart';
import '../services/paste_titles.dart';
import '../services/text_utils.dart';
import 'shortcut_labels.dart';
import 'theme.dart';

IconData iconForField(FieldKind kind) => switch (kind) {
      FieldKind.password => Icons.key_outlined,
      FieldKind.token => Icons.vpn_key_outlined,
      FieldKind.otp => Icons.pin_outlined,
      FieldKind.card => Icons.credit_card,
      FieldKind.username => Icons.person_outline,
      FieldKind.email => Icons.email_outlined,
      FieldKind.url => Icons.link,
      FieldKind.ip => Icons.lan_outlined,
      FieldKind.phone => Icons.phone_outlined,
      FieldKind.code => Icons.tag,
      FieldKind.labeled => Icons.label_outline,
      FieldKind.line => Icons.text_snippet_outlined,
    };

class PasteTile extends StatefulWidget {
  const PasteTile({
    super.key,
    required this.item,
    required this.extraction,
    required this.isFirst,
    required this.maskSecrets,
    required this.revealed,
    this.flashGeneration = 0,
    this.flashFieldIndex = -1,
    this.editGeneration = 0,
    required this.onTap,
    required this.onTitleChanged,
    required this.onFieldCopy,
    required this.onDelete,
    required this.onToggleReveal,
    required this.onToggleSensitive,
    this.onEditingChanged,
  });

  final PasteItem item;
  final Extraction extraction;
  final bool isFirst;

  /// The "mask passwords and secrets" setting.
  final bool maskSecrets;

  /// The user revealed this item for a moment.
  final bool revealed;

  final int flashGeneration;

  /// -1 flashes the whole tile, 0–8 flashes one field chip.
  final int flashFieldIndex;
  final int editGeneration;
  final VoidCallback onTap;
  final ValueChanged<String> onTitleChanged;
  final void Function(String value, int fieldIndex) onFieldCopy;
  final VoidCallback onDelete;
  final VoidCallback onToggleReveal;
  final VoidCallback onToggleSensitive;
  final ValueChanged<bool>? onEditingChanged;

  /// Whether this item is currently drawn with its secrets hidden.
  bool get hidden =>
      !revealed && (item.sensitive || (maskSecrets && extraction.hasSecrets));

  @override
  State<PasteTile> createState() => _PasteTileState();
}

class _PasteTileState extends State<PasteTile>
    with SingleTickerProviderStateMixin {
  static const _previewChars = 600;

  late final TextEditingController _titleController =
      TextEditingController(text: widget.item.title);
  final FocusNode _titleFocusNode = FocusNode(debugLabel: 'title');
  bool _isEditingTitle = false;

  late final AnimationController _flashController = AnimationController(
    duration: const Duration(milliseconds: 600),
    vsync: this,
  );
  late final Animation<double> _flashOpacity =
      Tween<double>(begin: 0.5, end: 0.0).animate(
          CurvedAnimation(parent: _flashController, curve: Curves.easeOut));
  late int _lastFlashGeneration = widget.flashGeneration;
  late int _lastEditGeneration = widget.editGeneration;
  int _activeFlashField = -1;

  @override
  void initState() {
    super.initState();
    _titleFocusNode.addListener(_onTitleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant PasteTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.title != widget.item.title && !_isEditingTitle) {
      _titleController.text = widget.item.title;
    }
    if (widget.flashGeneration != 0 &&
        widget.flashGeneration != _lastFlashGeneration) {
      _lastFlashGeneration = widget.flashGeneration;
      _activeFlashField = widget.flashFieldIndex;
      _flashController.forward(from: 0);
    }
    if (widget.editGeneration != 0 &&
        widget.editGeneration != _lastEditGeneration) {
      _lastEditGeneration = widget.editGeneration;
      _startEditing();
    }
  }

  @override
  void dispose() {
    if (_isEditingTitle) {
      // Can't touch the parent's state while the tree is being torn down.
      final onEditingChanged = widget.onEditingChanged;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => onEditingChanged?.call(false));
    }
    _titleFocusNode.removeListener(_onTitleFocusChanged);
    _titleController.dispose();
    _titleFocusNode.dispose();
    _flashController.dispose();
    super.dispose();
  }

  void _onTitleFocusChanged() {
    if (!_titleFocusNode.hasFocus && _isEditingTitle) _submitTitle();
  }

  void _startEditing() {
    _titleController.text = widget.item.title;
    setState(() => _isEditingTitle = true);
    widget.onEditingChanged?.call(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isEditingTitle) return;
      _titleFocusNode.requestFocus();
      _titleController.selection = TextSelection(
          baseOffset: 0, extentOffset: _titleController.text.length);
    });
  }

  void _submitTitle() {
    if (!_isEditingTitle) return;
    final newTitle = _titleController.text.trim();
    if (newTitle.isNotEmpty && newTitle != widget.item.title) {
      widget.onTitleChanged(newTitle);
    } else {
      _titleController.text = widget.item.title;
    }
    _finishEditing();
  }

  /// Escape: drop the edit and keep the old title.
  void _cancelEditing() {
    if (!_isEditingTitle) return;
    _titleController.text = widget.item.title;
    _finishEditing();
  }

  void _finishEditing() {
    setState(() => _isEditingTitle = false);
    widget.onEditingChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final fields = widget.extraction.fields;
    final hidden = widget.hidden;
    final canReveal = widget.item.sensitive || widget.extraction.hasSecrets;

    Widget tile = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: widget.isFirst
            ? colorScheme.primaryContainer.withValues(alpha: 0.35)
            : colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: widget.isFirst
              ? colorScheme.primary.withValues(alpha: 0.4)
              : colorScheme.outlineVariant.withValues(alpha: 0.3),
          width: widget.isFirst ? 1.5 : 1,
        ),
      ),
      child: Stack(
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              canRequestFocus: false,
              onTap: _isEditingTitle ? null : widget.onTap,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildTitle(theme, colorScheme, hidden),
                              const SizedBox(height: 6),
                              _buildPreview(theme, colorScheme, hidden),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildActions(theme, colorScheme, canReveal),
                      ],
                    ),
                    if (fields.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _buildFieldChips(fields, colorScheme, hidden),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // Whole-tile flash (only when no single chip was copied).
          AnimatedBuilder(
            animation: _flashOpacity,
            builder: (context, child) {
              if (_flashController.isDismissed ||
                  _activeFlashField != -1 ||
                  _flashOpacity.value <= 0) {
                return const SizedBox.shrink();
              }
              return Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color:
                          Colors.yellow.withValues(alpha: _flashOpacity.value),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );

    if (!widget.isFirst) tile = Opacity(opacity: 0.55, child: tile);
    return tile;
  }

  Widget _buildTitle(ThemeData theme, ColorScheme colorScheme, bool hidden) {
    final style = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
      color: colorScheme.onSurface,
    );
    if (_isEditingTitle) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _cancelEditing
          },
          child: TextField(
            controller: _titleController,
            focusNode: _titleFocusNode,
            style: style,
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: colorScheme.primary),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
              ),
            ),
            onSubmitted: (_) => _submitTitle(),
          ),
        ),
      );
    }

    final title = displayTitle(widget.item, widget.extraction, hidden: hidden);
    return GestureDetector(
      onDoubleTap: _startEditing,
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
          ),
          const SizedBox(width: 4),
          _ActionButton(
            icon: Icons.edit_outlined,
            tooltip: 'Rename (${primaryShortcut('E')} or double-click)',
            onPressed: _startEditing,
            colorScheme: colorScheme,
          ),
        ],
      ),
    );
  }

  Widget _buildPreview(ThemeData theme, ColorScheme colorScheme, bool hidden) {
    final style = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
      height: 1.4,
    );
    if (hidden && widget.item.sensitive) {
      return Row(
        children: [
          Icon(Icons.lock_outline,
              size: 13, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Hidden. Click the eye to show it, or copy it as usual.',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(fontStyle: FontStyle.italic),
            ),
          ),
        ],
      );
    }

    final content = widget.item.content;
    // Laying out a multi-megabyte string just to show three lines is slow.
    final head = content.length > _previewChars
        ? content.substring(0, _previewChars)
        : content;
    if (!hidden || !widget.extraction.hasSecrets) {
      return Text(
        sanitizeUtf16(truncateGraphemes(head, 400)),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    final maskStyle = TextStyle(
      color: colorScheme.tertiary,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
    );
    return Text.rich(
      TextSpan(children: [
        for (final segment
            in Masker.segments(head, widget.extraction.secretSpans))
          TextSpan(
            text: segment.masked ? segment.text : sanitizeUtf16(segment.text),
            style: segment.masked ? maskStyle : null,
          ),
      ]),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }

  Widget _buildActions(
      ThemeData theme, ColorScheme colorScheme, bool canReveal) {
    // Fixed width so the rename buttons line up whether or not a tile has
    // the reveal button.
    return SizedBox(
      width: 3 * 28,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _formatTime(widget.item.createdAt),
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canReveal)
                _ActionButton(
                  icon: widget.revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  tooltip: widget.revealed
                      ? 'Hide again'
                      : 'Show hidden text (${primaryShortcut('R')})',
                  onPressed: widget.onToggleReveal,
                  colorScheme: colorScheme,
                ),
              _ActionButton(
                icon: widget.item.sensitive
                    ? Icons.lock
                    : Icons.lock_open_outlined,
                tooltip: widget.item.sensitive
                    ? 'Stop always hiding this item'
                    : 'Always hide this item',
                onPressed: widget.onToggleSensitive,
                colorScheme: colorScheme,
                highlighted: widget.item.sensitive,
              ),
              _ActionButton(
                icon: Icons.delete_outline,
                tooltip: 'Delete (Delete key)',
                onPressed: widget.onDelete,
                colorScheme: colorScheme,
                destructive: true,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFieldChips(
      List<ExtractedField> fields, ColorScheme colorScheme, bool hidden) {
    return AnimatedBuilder(
      animation: _flashController,
      builder: (context, _) {
        return Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (var i = 0; i < fields.length; i++)
              _FieldChip(
                index: i + 1,
                icon: iconForField(fields[i].kind),
                text: _chipText(fields[i], hidden),
                masked: _chipMasked(fields[i], hidden),
                colorScheme: colorScheme,
                tooltip: _chipTooltip(fields[i], i, hidden),
                flashOpacity:
                    _activeFlashField == i ? _flashOpacity.value : 0.0,
                onTap: () => widget.onFieldCopy(fields[i].value, i),
              ),
          ],
        );
      },
    );
  }

  bool _chipMasked(ExtractedField field, bool hidden) =>
      hidden && (field.secret || widget.item.sensitive);

  String _chipText(ExtractedField field, bool hidden) {
    if (_chipMasked(field, hidden)) {
      return field.kind == FieldKind.card
          ? '${field.label} ${Masker.hiddenFieldText(field)}'
          : '${field.label} ••••';
    }
    return truncateGraphemes(_visibleValue(field, hidden), 24);
  }

  String _chipTooltip(ExtractedField field, int index, bool hidden) {
    final keys = primaryShortcut('${index + 1}');
    if (_chipMasked(field, hidden)) return '$keys  ${field.label} (hidden)';
    return '$keys  ${field.label}: ${truncateGraphemes(_visibleValue(field, hidden), 80)}';
  }

  /// A non-secret field can still contain a secret, like a database URL with
  /// its password in it.
  String _visibleValue(ExtractedField field, bool hidden) {
    var text = field.value;
    if (hidden &&
        widget.extraction.hasSecrets &&
        field.kind != FieldKind.card) {
      text = Masker.maskWithin(
          widget.item.content, field.span, widget.extraction.secretSpans);
    }
    return sanitizeUtf16(text.replaceAll(RegExp(r'\s*\n\s*'), ' '));
  }

  String _formatTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}

// ── small widgets ────────────────────────────────────────

class _FieldChip extends StatelessWidget {
  const _FieldChip({
    required this.index,
    required this.icon,
    required this.text,
    required this.masked,
    required this.colorScheme,
    required this.tooltip,
    this.flashOpacity = 0.0,
    required this.onTap,
  });

  final int index;
  final IconData icon;
  final String text;
  final bool masked;
  final ColorScheme colorScheme;
  final String tooltip;
  final double flashOpacity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final base = masked
        ? colorScheme.tertiaryContainer.withValues(alpha: 0.6)
        : colorScheme.secondaryContainer.withValues(alpha: 0.45);
    final bgColor = flashOpacity > 0
        ? Color.lerp(base, Colors.yellow, flashOpacity)!
        : base;
    final fg = masked
        ? colorScheme.onTertiaryContainer
        : colorScheme.onSecondaryContainer;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          canRequestFocus: false,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: flashOpacity > 0
                    ? Colors.yellow.withValues(alpha: 0.6)
                    : colorScheme.outlineVariant.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 16,
                  height: 16,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '$index',
                    style: TextStyle(
                      color: colorScheme.onPrimary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(icon, size: 12, color: fg),
                const SizedBox(width: 3),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 11,
                    color: fg,
                    fontFamily: AppTheme.monoFont,
                    fontFamilyFallback: AppTheme.monoFallback,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.colorScheme,
    this.destructive = false,
    this.highlighted = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final ColorScheme colorScheme;
  final bool destructive;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            canRequestFocus: false,
            onTap: onPressed,
            hoverColor: destructive
                ? colorScheme.errorContainer
                : colorScheme.primaryContainer.withValues(alpha: 0.6),
            child: Center(
              child: Icon(
                icon,
                size: 16,
                color: highlighted
                    ? colorScheme.tertiary
                    : colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
