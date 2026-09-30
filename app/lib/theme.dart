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
  static Color get ink => _c(0xFF0E1A45, 0xFFF7F3E8); // main text (navy / ivory)
  static Color get ink2 => _c(0xFF3A4468, 0xFFD6DCEF); // secondary text
  static Color get muted => _c(0xFF5B6384, 0xFFA3AED3); // captions

  // Surfaces
  static Color get bg => _c(0xFFF7F3E8, 0xFF0E1A45); // page background (ivory / deep royal navy)
  static Color get card => _c(0xFFFFFFFF, 0xFF132257);
  static Color get line => _c(0xFFE4DCC8, 0xFF243572);
  static Color get fill => _c(0xFFEDE5D2, 0xFF1A2A63); // soft fills: toggles, placeholders, dividers
  static Color get avatarFill => _c(0xFFE1D6BD, 0xFF22347A);

  // Panels (side rail, call panel, your chat bubbles): royal blue / midnight navy. Text on them is white.
  static Color get panel => _c(0xFF1B3A9E, 0xFF09122F);
  static Color get panelRaised => _c(0xFF2B4BB5, 0xFF16255A);
  static const onPanelMuted = Color(0xFFB4C1EA);
  static const panelAccent = Color(0xFFF5C542); // gold for small text on panels

  // Gold: the second signature color. Main buttons, the logo dot, highlights.
  static const gold = Color(0xFFF5C542);
  static const onGold = Color(0xFF0E1A45); // text on gold
  // The feature card on Home (tonight's call): royal blue in both modes.
  static Color get hero => _c(0xFF1B3A9E, 0xFF4169E1);
  static Color get slogan => _c(0xFF1B3A9E, 0xFFF5C542);

  // Royal blue: the ONE action color
  static Color get accent => _c(0xFF2F55D4, 0xFF6A8DF2);
  static Color get accentSoft => _c(0xFFE3E9FB, 0xFF1D2F73);
  static Color get accentMid => _c(0xFFAFC0F2, 0xFF34498F); // radar rings
  static Color get accentStrong => _c(0xFF1B3A9E, 0xFFF5C542); // accent-colored text on soft fills

  // Status
  static Color get urgent => _c(0xFF1B3A9E, 0xFFF5C542); // under 24h (deep blue / gold)
  static Color get urgentSoft => _c(0xFFDCE4FA, 0xFF3A3A4A);
  static Color get soon => _c(0xFF2F55D4, 0xFFA9BDF5); // under 2 days (royal blue)
  static Color get soonSoft => _c(0xFFE8EDFC, 0xFF1D2F73);
  static Color get ok => _c(0xFF2F6B47, 0xFF6FC08E);
  static Color get okSoft => _c(0xFFEAF3EC, 0xFF1C3A3A);
  static Color get okInk => _c(0xFF1F4D32, 0xFF9FD8B2); // text on okSoft

  static const radius = 4.0; // near-square corners: gallery-sharp
  static const navHeight = 70.0;
  static const navClearance = 28.0; // bottom padding at the end of scrolling pages

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
      GoogleFonts.cormorantGaramond(fontSize: size * 1.1, fontWeight: FontWeight.w700, color: ink, height: 1.0);

  static TextStyle heading(double size) =>
      GoogleFonts.cormorantGaramond(fontSize: size * 1.1, fontWeight: FontWeight.w700, color: ink, height: 1.1);

  static TextStyle get label => GoogleFonts.manrope(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 2.2, color: muted);

  /// The slogan, set in italic serif.
  static TextStyle get sloganStyle => GoogleFonts.cormorantGaramond(fontSize: 16, fontStyle: FontStyle.italic, fontWeight: FontWeight.w600, color: slogan);

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

  /// Body text a touch heavier than default so it reads crisp on dark backgrounds.
  static TextTheme _bolder(TextTheme t) => t.copyWith(
        bodyLarge: t.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
        bodyMedium: t.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
        bodySmall: t.bodySmall?.copyWith(fontWeight: FontWeight.w500),
        titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      );

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
      textTheme: _bolder(GoogleFonts.manropeTextTheme(base.textTheme)).apply(bodyColor: ink, displayColor: ink),
      iconTheme: IconThemeData(color: ink2),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: gold, // main buttons are gold with navy text
          foregroundColor: onGold,
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
          textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, letterSpacing: 1.6),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          minimumSize: const Size(0, 52),
          side: BorderSide(color: line, width: 1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
          textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, letterSpacing: 1.2),
        ),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: accent)),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? card : bg,
        hintStyle: TextStyle(color: muted),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(2), borderSide: BorderSide(color: line, width: 1)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(2), borderSide: BorderSide(color: line, width: 1)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(2), borderSide: BorderSide(color: accent, width: 1.5)),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    );
  }
}
