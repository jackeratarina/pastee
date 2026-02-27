import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:pastee/model/paste_item.dart';
import 'package:pastee/services/field_extractor.dart';

class PasteTile extends StatefulWidget {
  final PasteItem item;
  final bool isFirst;
  final int flashGeneration;

  /// -1 = whole tile flash, 0-8 = specific field chip flash
  final int flashFieldIndex;
  final int editGeneration;
  final VoidCallback onTap;
  final ValueChanged<String> onTitleChanged;
  final void Function(String value, int fieldIndex) onFieldCopy;
  final VoidCallback onDelete;
  final ValueChanged<bool>? onEditingChanged;

  const PasteTile({
    super.key,
    required this.item,
    required this.isFirst,
    this.flashGeneration = 0,
    this.flashFieldIndex = -1,
    this.editGeneration = 0,
    required this.onTap,
    required this.onTitleChanged,
    required this.onFieldCopy,
    required this.onDelete,
    this.onEditingChanged,
  });

  @override
  State<PasteTile> createState() => _PasteTileState();
}

class _PasteTileState extends State<PasteTile>
    with SingleTickerProviderStateMixin {
  late TextEditingController _titleController;
  bool _isEditingTitle = false;
  final FocusNode _titleFocusNode = FocusNode();

  late AnimationController _flashController;
  late Animation<double> _flashOpacity;
  int _lastFlashGeneration = 0;
  int _lastEditGeneration = 0;
  int _activeFlashField = -1;

  List<ExtractedField>? _cachedFields;
  String? _cachedContent;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.item.title);
    _titleFocusNode.addListener(_onTitleFocusChanged);

    _flashController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _flashOpacity = Tween<double>(begin: 0.5, end: 0.0).animate(
      CurvedAnimation(parent: _flashController, curve: Curves.easeOut),
    );
    _lastFlashGeneration = widget.flashGeneration;
    _lastEditGeneration = widget.editGeneration;
  }

  @override
  void didUpdateWidget(covariant PasteTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.title != widget.item.title && !_isEditingTitle) {
      _titleController.text = widget.item.title;
    }
    if (oldWidget.item.content != widget.item.content) {
      _cachedFields = null;
      _cachedContent = null;
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
      widget.onEditingChanged?.call(false);
    }
    _titleFocusNode.removeListener(_onTitleFocusChanged);
    _titleController.dispose();
    _titleFocusNode.dispose();
    _flashController.dispose();
    super.dispose();
  }

  List<ExtractedField> get _fields {
    if (_cachedContent != widget.item.content || _cachedFields == null) {
      _cachedContent = widget.item.content;
      _cachedFields = FieldExtractor.extract(widget.item.content);
    }
    return _cachedFields!;
  }

  void _onTitleFocusChanged() {
    if (!_titleFocusNode.hasFocus && _isEditingTitle) {
      _submitTitle();
    }
  }

  void _startEditing() {
    setState(() => _isEditingTitle = true);
    widget.onEditingChanged?.call(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _titleFocusNode.requestFocus();
      _titleController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _titleController.text.length,
      );
    });
  }

  void _submitTitle() {
    final newTitle = _titleController.text.trim();
    if (newTitle.isNotEmpty && newTitle != widget.item.title) {
      widget.onTitleChanged(newTitle);
    } else {
      _titleController.text = widget.item.title;
    }
    setState(() => _isEditingTitle = false);
    widget.onEditingChanged?.call(false);
  }

  bool get _isMacOS {
    try {
      return Platform.isMacOS;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final fields = _fields;

    Widget tile = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: widget.isFirst
            ? colorScheme.primaryContainer.withOpacity(0.35)
            : colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: widget.isFirst
              ? colorScheme.primary.withOpacity(0.4)
              : colorScheme.outlineVariant.withOpacity(0.3),
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
                              _buildTitle(theme, colorScheme),
                              const SizedBox(height: 6),
                              Text(
                                widget.item.content,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              _formatTime(widget.item.createdAt),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant
                                    .withOpacity(0.6),
                              ),
                            ),
                            const SizedBox(height: 8),
                            _ActionButton(
                              icon: Icons.delete_outline,
                              tooltip: 'Delete',
                              onPressed: widget.onDelete,
                              colorScheme: colorScheme,
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (fields.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _buildFieldChips(fields, theme, colorScheme),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // Whole-tile flash overlay (only when _activeFlashField == -1)
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
                      color: Colors.yellow.withOpacity(_flashOpacity.value),
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

    if (!widget.isFirst) {
      tile = Opacity(opacity: 0.55, child: tile);
    }

    return tile;
  }

  Widget _buildFieldChips(
    List<ExtractedField> fields,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final mod = _isMacOS ? '⌘' : 'Ctrl+';
    return AnimatedBuilder(
      animation: _flashController,
      builder: (context, _) {
        return Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (int i = 0; i < fields.length; i++)
              _FieldChip(
                index: i + 1,
                field: fields[i],
                colorScheme: colorScheme,
                tooltip: '$mod${i + 1}  ${fields[i].value}',
                flashOpacity:
                    _activeFlashField == i ? _flashOpacity.value : 0.0,
                onTap: () => widget.onFieldCopy(fields[i].value, i),
              ),
          ],
        );
      },
    );
  }

  Widget _buildTitle(ThemeData theme, ColorScheme colorScheme) {
    if (_isEditingTitle) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: TextField(
          controller: _titleController,
          focusNode: _titleFocusNode,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
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
      );
    }

    return GestureDetector(
      onDoubleTap: _startEditing,
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 4),
          _ActionButton(
            icon: Icons.edit_outlined,
            tooltip: 'Edit title (⌘E or double-click)',
            onPressed: _startEditing,
            colorScheme: colorScheme,
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}

// ── small widgets ────────────────────────────────────────

class _FieldChip extends StatelessWidget {
  final int index;
  final ExtractedField field;
  final ColorScheme colorScheme;
  final String tooltip;
  final double flashOpacity;
  final VoidCallback onTap;

  const _FieldChip({
    required this.index,
    required this.field,
    required this.colorScheme,
    required this.tooltip,
    this.flashOpacity = 0.0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final valuePreview = field.value.length > 24
        ? '${field.value.substring(0, 22)}…'
        : field.value;

    final bgColor = flashOpacity > 0
        ? Color.lerp(
            colorScheme.secondaryContainer.withOpacity(0.45),
            Colors.yellow,
            flashOpacity,
          )!
        : colorScheme.secondaryContainer.withOpacity(0.45);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
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
                    ? Colors.yellow.withOpacity(0.6)
                    : colorScheme.outlineVariant.withOpacity(0.25),
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
                Icon(field.icon,
                    size: 12, color: colorScheme.onSecondaryContainer),
                const SizedBox(width: 3),
                Text(
                  valuePreview,
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSecondaryContainer,
                    fontFamily: 'monospace',
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
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final ColorScheme colorScheme;

  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.colorScheme,
  });

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
            hoverColor: colorScheme.errorContainer,
            child: Center(
              child: Icon(icon, size: 16,
                  color: colorScheme.onSurfaceVariant.withOpacity(0.6)),
            ),
          ),
        ),
      ),
    );
  }
}
