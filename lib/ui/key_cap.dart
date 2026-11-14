import 'package:flutter/material.dart';

import 'theme.dart';

/// A small keyboard-key badge, optionally followed by what the key does.
class KeyCap extends StatelessWidget {
  const KeyCap(this.keys, {super.key, this.label, this.emphasized = false});

  final String keys;
  final String? label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      decoration: BoxDecoration(
        color: emphasized
            ? cs.primaryContainer.withValues(alpha: 0.7)
            : cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            keys,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              fontFamily: AppTheme.monoFont,
              fontFamilyFallback: AppTheme.monoFallback,
              color: emphasized
                  ? cs.onPrimaryContainer
                  : cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
          if (label != null) ...[
            const SizedBox(width: 3),
            Text(
              label!,
              style: TextStyle(
                fontSize: 10,
                color: emphasized
                    ? cs.onPrimaryContainer.withValues(alpha: 0.8)
                    : cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
