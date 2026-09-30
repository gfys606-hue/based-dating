import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Based design tokens. Every screen (and every future module: search, shop,
/// groups) uses these, so the whole platform looks and feels like one app.
///
/// Light and dark: each token has two values. [B.isDark] is set by the app root
/// (follows the phone's setting unless the user picks Light/Dark in You → Appearance),
/// and the whole app rebuilds when it changes.
class B {
  static bool isDark = false;
  static Color _c(int light, int dark) => Color(isDark ? dark : light);

  // Text
  static Color get ink => _c(0xFF15181D, 0xFFECEEF2); // main text
  static Color get ink2 => _c(0xFF3B4048, 0xFFC3C8D0); // secondary text
  static Color get muted => _c(0xFF5A6068, 0xFF9AA1AB); // captions

  // Surfaces
  static Color get bg => _c(0xFFF7F5F1, 0xFF0B0C0F); // page background
  static Color get card => _c(0xFFFFFFFF, 0xFF15171C);
  static Color get line => _c(0xFFE4E0D8, 0xFF272A31);
  static Color get fill => _c(0xFFEFEAE2, 0xFF23272E); // soft fills: toggles, placeholders, dividers
  static Color get avatarFill => _c(0xFFD9CDBD, 0xFF2C3038);

  // Dark panels (floating menu, call panel, your chat bubbles). Dark in both modes; text on them is white.
  static Color get panel => _c(0xFF15181D, 0xFF232833);
  static Color get panelRaised => _c(0xFF2A2F36, 0xFF323846);
  static const onPanelMuted = Color(0xFF9BA0A7);
  static const panelAccent = Color(0xFFA9BDF5); // light royal blue for small text on panels

  // Royal blue: the ONE action color
  static Color get accent => _c(0xFF4169E1, 0xFF5B7FEA);
  static Color get accentSoft => _c(0xFFE3E9FB, 0xFF1C2540);
  static Color get accentMid => _c(0xFFAFC0F2, 0xFF33457A); // radar rings
  static Color get accentStrong => _c(0xFF2A4BB8, 0xFF9DB2F2); // accent-colored text on soft fills

  // Status
  static Color get urgent => _c(0xFF1E3FAE, 0xFF8FA8F3); // under 24h (deep royal blue)
  static Color get urgentSoft => _c(0xFFDCE4FA, 0xFF1A2444);
  static Color get soon => _c(0xFF4169E1, 0xFF5B7FEA); // under 2 days (royal blue)
  static Color get soonSoft => _c(0xFFE8EDFC, 0xFF1C2540);
  static Color get ok => _c(0xFF2F6B47, 0xFF6FC08E);
  static Color get okSoft => _c(0xFFEAF3EC, 0xFF1C2E23);
  static Color get okInk => _c(0xFF1F4D32, 0xFF9FD8B2); // text on okSoft

  static const radius = 12.0;
  static const navHeight = 70.0;
  static const navClearance = 104.0; // bottom padding so content scrolls above the floating menu

  // Barely-there shadows; edges come from fine hairlines instead.
  static List<BoxShadow> get shadow => isDark
      ? const [BoxShadow(color: Color(0x55000000), blurRadius: 14, spreadRadius: -8, offset: Offset(0, 6))]
      : const [BoxShadow(color: Color(0x0F15181D), blurRadius: 12, spreadRadius: -6, offset: Offset(0, 4))];

  static BoxDecoration cardBox({Color? border}) => BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: shadow,
        border: Border.all(color: border ?? line, width: border == null ? 0.8 : 1.5),
      );

  // Type: an elegant serif for display/headings (speakeasy menu feel), a crisp sans for everything else.
  static TextStyle display(double size) =>
      GoogleFonts.playfairDisplay(fontSize: size, fontWeight: FontWeight.w600, letterSpacing: -0.01 * size, color: ink, height: 1.1);

  static TextStyle heading(double size) =>
      GoogleFonts.playfairDisplay(fontSize: size, fontWeight: FontWeight.w600, color: ink, height: 1.2);

  static TextStyle get label => TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.8, color: muted);

  // ---------- Appearance setting: System / Light / Dark ----------
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.system);

  static Future<void> loadMode() async {
    try {
      final p = await SharedPreferences.getInstance();
      mode.value = ThemeMode.values.firstWhere((m) => m.name == p.getString('theme_mode'), orElse: () => ThemeMode.system);
    } catch (_) {}
  }

  static Future<void> setMode(ThemeMode m) async {
    mode.value = m;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('theme_mode', m.name);
    } catch (_) {}
  }

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: isDark ? Brightness.dark : Brightness.light,
      primary: accent,
      onPrimary: Colors.white,
      surface: bg,
      onSurface: ink,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: isDark ? Brightness.dark : Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      dividerColor: line,
    );
    return base.copyWith(
      textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(bodyColor: ink, displayColor: ink),
      iconTheme: IconThemeData(color: ink2),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.4),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          minimumSize: const Size(0, 52),
          side: BorderSide(color: line, width: 1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.4),
        ),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: accent)),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? card : bg,
        hintStyle: TextStyle(color: muted),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: line, width: 1)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: line, width: 1)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: accent, width: 1.5)),
      ),
      appBarTheme: AppBarTheme(backgroundColor: bg, foregroundColor: ink, elevation: 0, scrolledUnderElevation: 0),
      cardColor: card,
      dialogTheme: DialogThemeData(backgroundColor: card),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: card, modalBackgroundColor: card),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : muted),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : fill),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: panel,
        contentTextStyle: const TextStyle(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
