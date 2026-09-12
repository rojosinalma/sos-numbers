import 'package:flutter/material.dart';

/// Dracula palette, matching the house style used across the other projects.
abstract final class Dracula {
  static const Color background = Color(0xFF282A36);
  static const Color currentLine = Color(0xFF44475A);
  static const Color surface = Color(0xFF343746);
  static const Color foreground = Color(0xFFF8F8F2);
  static const Color comment = Color(0xFF6272A4);
  static const Color cyan = Color(0xFF8BE9FD);
  static const Color green = Color(0xFF50FA7B);
  static const Color orange = Color(0xFFFFB86C);
  static const Color pink = Color(0xFFFF79C6);
  static const Color purple = Color(0xFFBD93F9);
  static const Color red = Color(0xFFFF5555);
  static const Color yellow = Color(0xFFF1FA8C);
}

ThemeData buildTheme() {
  final ColorScheme scheme = const ColorScheme.dark(
    primary: Dracula.purple,
    onPrimary: Dracula.background,
    secondary: Dracula.cyan,
    onSecondary: Dracula.background,
    error: Dracula.red,
    onError: Dracula.foreground,
    surface: Dracula.surface,
    onSurface: Dracula.foreground,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Dracula.background,
    canvasColor: Dracula.background,
    dividerColor: Dracula.currentLine,
    appBarTheme: const AppBarTheme(
      backgroundColor: Dracula.background,
      foregroundColor: Dracula.foreground,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: Dracula.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Dracula.currentLine),
      ),
      margin: EdgeInsets.zero,
    ),
    textTheme: Typography.whiteMountainView.apply(
      bodyColor: Dracula.foreground,
      displayColor: Dracula.foreground,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Dracula.surface,
      hintStyle: const TextStyle(color: Dracula.comment),
      prefixIconColor: Dracula.comment,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Dracula.currentLine),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Dracula.currentLine),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Dracula.purple, width: 2),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Dracula.currentLine,
      contentTextStyle: TextStyle(color: Dracula.foreground),
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: const ListTileThemeData(
      textColor: Dracula.foreground,
      iconColor: Dracula.comment,
    ),
  );
}
