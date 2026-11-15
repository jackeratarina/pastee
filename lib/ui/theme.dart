import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const _seed = Color(0xFF6750A4);

  static ThemeData light() => _build(
      ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.light));

  static ThemeData dark() => _build(
      ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark));

  /// A monospace family that exists on the platform ("monospace" is not a real
  /// font name on macOS or Windows; on Linux, fontconfig maps it to the
  /// system's monospace font).
  static String get monoFont => switch (defaultTargetPlatform) {
        TargetPlatform.macOS => 'Menlo',
        TargetPlatform.linux => 'monospace',
        _ => 'Consolas',
      };

  static const monoFallback = ['Menlo', 'Consolas', 'Courier New', 'monospace'];

  static ThemeData _build(ColorScheme colorScheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: WidgetStateProperty.all(true),
        thickness: WidgetStateProperty.all(6),
        radius: const Radius.circular(3),
      ),
      tooltipTheme:
          const TooltipThemeData(waitDuration: Duration(milliseconds: 400)),
    );
  }
}
