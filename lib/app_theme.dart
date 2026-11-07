import 'package:flutter/material.dart';

abstract final class AppColors {
  static const ink = Color(0xFF1C2030);
  static const navy = Color(0xFF171A27);
  static const navySoft = Color(0xFF252A3B);
  static const blue = Color(0xFF5268F2);
  static const blueSoft = Color(0xFFF0F2FF);
  static const cyan = Color(0xFF48C9B0);
  static const mint = Color(0xFF78D7C7);
  static const canvas = Color(0xFFF7F8FC);
  static const line = Color(0xFFE7E9F2);
  static const muted = Color(0xFF73798C);
  static const success = Color(0xFF2CAF7A);
  static const warning = Color(0xFFE19B39);
  static const danger = Color(0xFFD65757);

  static const darkCanvas = Color(0xFF081411);
  static const darkSurface = Color(0xFF10211D);
  static const darkSurfaceHigh = Color(0xFF172C27);
  static const darkLine = Color(0xFF29413A);
  static const darkText = Color(0xFFEAF5F2);
  static const darkMuted = Color(0xFF9CB0AA);
}

ThemeData buildTheme({Brightness brightness = Brightness.light}) {
  final dark = brightness == Brightness.dark;
  final primary = dark ? AppColors.mint : const Color(0xFF238E82);
  final surface = dark ? AppColors.darkSurface : Colors.white;
  final onSurface = dark ? AppColors.darkText : AppColors.ink;
  final outline = dark ? AppColors.darkLine : AppColors.line;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.cyan,
    brightness: brightness,
    primary: primary,
    secondary: dark ? const Color(0xFF9AA8FF) : AppColors.blue,
    surface: surface,
    onSurface: onSurface,
    outline: outline,
    error: dark ? const Color(0xFFFFB4AB) : AppColors.danger,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? AppColors.darkCanvas : AppColors.canvas,
    fontFamily: 'NotoSansSC',
    fontFamilyFallback: const ['Segoe UI', 'Microsoft YaHei', 'Roboto'],
  );
  return base.copyWith(
    textTheme: base.textTheme
        .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface)
        .copyWith(
          headlineSmall: base.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: scheme.surfaceContainerLow,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? AppColors.darkSurfaceHigh : const Color(0xFFF1F3F8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 0,
        textStyle: const TextStyle(
          fontFamily: 'NotoSansSC',
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        foregroundColor: scheme.onSurface,
        textStyle: const TextStyle(
          fontFamily: 'NotoSansSC',
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontFamily: 'NotoSansSC', fontWeight: FontWeight.w700),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(
        color: scheme.onInverseSurface,
        fontFamily: 'NotoSansSC',
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(
        color: scheme.onInverseSurface,
        fontFamily: 'NotoSansSC',
        fontSize: 12,
      ),
    ),
  );
}
