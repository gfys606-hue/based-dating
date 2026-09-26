import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Based design tokens. Every screen (and every future module: search, shop,
/// groups) uses these, so the whole platform looks and feels like one app.
class B {
  static const ink = Color(0xFF15181D); // text, dark surfaces, floating menu
  static const ink2 = Color(0xFF3B4048); // secondary text
  static const muted = Color(0xFF5A6068); // captions
  static const bg = Color(0xFFF6F3EE); // page background
  static const card = Colors.white;
  static const line = Color(0xFFE2DDD4);
  static const accent = Color(0xFFC2451E); // the ONE action color
  static const accentSoft = Color(0xFFF7E4DA);
  static const urgent = Color(0xFFA1261C); // under 24h
  static const urgentSoft = Color(0xFFF1DCD9);
  static const soon = Color(0xFF9A5F12); // under 2 days
  static const soonSoft = Color(0xFFF3E6D2);
  static const ok = Color(0xFF2F6B47);
  static const okSoft = Color(0xFFEAF3EC);

  static const radius = 20.0;
  static const navHeight = 70.0;
  static const navClearance = 104.0; // bottom padding so content scrolls above the floating menu

  static List<BoxShadow> shadow = [
    BoxShadow(color: ink.withOpacity(.05), blurRadius: 2, offset: const Offset(0, 1)),
    BoxShadow(color: ink.withOpacity(.12), blurRadius: 24, spreadRadius: -12, offset: const Offset(0, 8)),
  ];

  static BoxDecoration cardBox({Color? border}) => BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: shadow,
        border: border == null ? null : Border.all(color: border, width: 2),
      );

  static TextStyle display(double size) =>
      GoogleFonts.archivo(fontSize: size, fontWeight: FontWeight.w900, letterSpacing: -0.025 * size, color: ink, height: 1.05);

  static TextStyle heading(double size) =>
      GoogleFonts.archivo(fontSize: size, fontWeight: FontWeight.w800, color: ink);

  static const label = TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.7, color: muted);

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: accent, primary: accent, surface: bg),
      scaffoldBackgroundColor: bg,
    );
    return base.copyWith(
      textTheme: GoogleFonts.dmSansTextTheme(base.textTheme).apply(bodyColor: ink, displayColor: ink),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          minimumSize: const Size(0, 52),
          side: const BorderSide(color: line, width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bg,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: line, width: 1.5)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: line, width: 1.5)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: ink, width: 1.5)),
      ),
      appBarTheme: const AppBarTheme(backgroundColor: bg, foregroundColor: ink, elevation: 0, scrolledUnderElevation: 0),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ink,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}
