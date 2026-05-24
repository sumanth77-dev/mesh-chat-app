// ============================================================
// FILE: lib/utils/app_theme.dart
// Centralized colors, gradients, and text styles for RelayX.
// ============================================================

import 'package:flutter/material.dart';

class AppTheme {
  // ── Core Palette ───────────────────────────────────────────
  static const Color bg        = Color(0xFF070714);
  static const Color surface   = Color(0xFF0F0F23);
  static const Color card      = Color(0xFF141428);
  static const Color border    = Color(0xFF1E1E3F);

  // ── Accents ────────────────────────────────────────────────
  static const Color cyan      = Color(0xFF00D4FF);
  static const Color purple    = Color(0xFF6C63FF);
  static const Color green     = Color(0xFF00E676);
  static const Color orange    = Color(0xFFFFAB40);
  static const Color red       = Color(0xFFFF5252);

  // ── Text ──────────────────────────────────────────────────
  static const Color textPrim  = Color(0xFFEEEEFF);
  static const Color textSec   = Color(0xFF6B6B8E);
  static const Color textMuted = Color(0xFF3D3D5C);

  // ── Gradients ─────────────────────────────────────────────
  static const LinearGradient accentGradient = LinearGradient(
    colors: [purple, cyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient sentBubbleGradient = LinearGradient(
    colors: [Color(0xFF5B52E8), Color(0xFF00BFDF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient bgGradient = LinearGradient(
    colors: [Color(0xFF070714), Color(0xFF0A0A1A)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // ── Shadows / Glows ───────────────────────────────────────
  static List<BoxShadow> cyanGlow({double opacity = 0.35, double blur = 18}) =>
      [BoxShadow(color: cyan.withOpacity(opacity), blurRadius: blur, spreadRadius: -2)];

  static List<BoxShadow> purpleGlow({double opacity = 0.35, double blur = 18}) =>
      [BoxShadow(color: purple.withOpacity(opacity), blurRadius: blur, spreadRadius: -2)];

  static List<BoxShadow> greenGlow({double opacity = 0.4, double blur = 14}) =>
      [BoxShadow(color: green.withOpacity(opacity), blurRadius: blur, spreadRadius: -2)];

  // ── Card decoration ────────────────────────────────────────
  static BoxDecoration glassCard({Color? borderColor, double radius = 16}) =>
      BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? border, width: 1),
      );

  static BoxDecoration glowCard({Color glowColor = cyan, double radius = 16}) =>
      BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: glowColor.withOpacity(0.4), width: 1),
        boxShadow: [
          BoxShadow(color: glowColor.withOpacity(0.08), blurRadius: 20, spreadRadius: 0),
        ],
      );

  // ── ThemeData ─────────────────────────────────────────────
  static ThemeData get theme => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        primaryColor: purple,
        colorScheme: const ColorScheme.dark(
          primary: purple,
          secondary: cyan,
          surface: surface,
        ),
        fontFamily: 'Roboto',
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: surface,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: textPrim,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: bg,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: const BorderSide(color: cyan, width: 1.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide(color: border),
          ),
          hintStyle: const TextStyle(color: textSec),
          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      );
}
