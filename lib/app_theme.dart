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
    textTheme: base.textTheme.apply(
      bodyColor: onSurface,
      displayColor: onSurface,
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(22)),
        side: BorderSide(color: outline),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? AppColors.darkSurfaceHigh : const Color(0xFFF8FAFD),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: primary, width: 1.5),
      ),
      labelStyle: TextStyle(
        color: dark ? AppColors.darkMuted : AppColors.muted,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(
          fontFamily: 'NotoSansSC',
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        side: BorderSide(color: outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        foregroundColor: onSurface,
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
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: 'NotoSansSC',
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? AppColors.darkSurfaceHigh : AppColors.navy,
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontFamily: 'NotoSansSC',
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    dividerTheme: DividerThemeData(color: outline, thickness: 1),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? AppColors.darkSurfaceHigh : AppColors.navy,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(
        color: Colors.white,
        fontFamily: 'NotoSansSC',
        fontSize: 12,
      ),
    ),
  );
}
