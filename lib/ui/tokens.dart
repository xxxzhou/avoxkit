import 'package:flutter/material.dart';

class AkColors {
  static const bg = Color(0xFF0B0B0A);
  static const bgDeep = Color(0xFF060606);
  static const surface = Color(0xFF171716);
  static const surfaceAlt = Color(0xFF1F1F1D);
  static const surfaceHi = Color(0xFF262624);
  static const accent = Color(0xFFE8C36A);
  static const accentInk = Color(0xFF1C1A12);
  static const state = Color(0xFF4FB3A9);
  static const text = Color(0xFFE0E0DE);
  static const textStrong = Color(0xFFEAE9E4);
  static const muted = Color(0xFFB8B8B3);
  static const faint = Color(0xFF9E9E99);
  static const border = Color(0x29FFFFFF);
  static const borderActive = Color(0x99C9A85A);
  static const danger = Color(0xFFD65A4A);
}

class AkText {
  static const pageTitle = TextStyle(
    fontSize: 24,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: AkColors.textStrong,
  );
  static const panelTitle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: AkColors.textStrong,
  );
  static const body = TextStyle(
    fontSize: 13,
    height: 1.5,
    color: AkColors.text,
  );
  static const label = TextStyle(
    fontSize: 12,
    color: AkColors.muted,
  );
  static const micro = TextStyle(
    fontSize: 11,
    color: AkColors.faint,
  );
  static const mono = TextStyle(
    fontFamily: 'JetBrains Mono',
    fontSize: 12,
    color: AkColors.muted,
  );
}

ThemeData akTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final scheme = base.colorScheme.copyWith(
    brightness: Brightness.dark,
    primary: AkColors.accent,
    onPrimary: AkColors.accentInk,
    secondary: AkColors.state,
    onSecondary: AkColors.accentInk,
    surface: AkColors.surface,
    onSurface: AkColors.text,
    error: AkColors.danger,
  );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: AkColors.bg,
    canvasColor: AkColors.bg,
    dividerColor: AkColors.border,
    textTheme: base.textTheme.apply(
      bodyColor: AkColors.text,
      displayColor: AkColors.textStrong,
      fontFamily: 'Albert Sans',
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AkColors.accent,
        foregroundColor: AkColors.accentInk,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AkColors.textStrong,
        minimumSize: const Size(0, 44),
        side: const BorderSide(color: AkColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 13),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AkColors.bgDeep,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AkColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AkColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AkColors.borderActive),
      ),
      hintStyle: const TextStyle(color: AkColors.faint, fontSize: 13),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: AkColors.accent,
      inactiveTrackColor: AkColors.surfaceAlt,
      thumbColor: AkColors.accent,
      overlayColor: AkColors.accent.withValues(alpha: 0.12),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AkColors.accentInk
            : AkColors.faint,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AkColors.accent
            : AkColors.surfaceAlt,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AkColors.surfaceHi,
      contentTextStyle: TextStyle(color: AkColors.text, fontSize: 13),
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: AkColors.surfaceHi,
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      textStyle: TextStyle(color: AkColors.text, fontSize: 12),
    ),
  );
}
