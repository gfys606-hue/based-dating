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

  // The look follows the opening: a lamplit study. Dark mode is the study at night (walnut,
  // old leather, brass, warm lamplight); light mode is the pages of an old book (parchment and ink).

  // Text
  static Color get ink => _c(0xFF2A1A0F, 0xFFF1E6D0); // main text (sepia ink / warm ivory)
  static Color get ink2 => _c(0xFF4E3826, 0xFFD6C5A6); // secondary text
  static Color get muted => _c(0xFF7A6248, 0xFF9E8B70); // captions

  // Surfaces
  static Color get bg => _c(0xFFF3EADA, 0xFF110B07); // page background (parchment / near-black walnut)
  static Color get card => _c(0xFFFBF6EC, 0xFF1B130D);
  static Color get line => _c(0xFFDCCBAE, 0xFF33251A);
  static Color get fill => _c(0xFFEADCC2, 0xFF261A11); // soft fills: toggles, placeholders, dividers
  static Color get avatarFill => _c(0xFFE0CDAA, 0xFF33241A);

  // Panels (side rail, call panel, your chat bubbles): dark walnut in both modes. Text on them is ivory.
  static Color get panel => _c(0xFF2B1B10, 0xFF0A0604);
  static Color get panelRaised => _c(0xFF3E2817, 0xFF22170F);
  static const onPanelMuted = Color(0xFFBCA889);
  static const panelAccent = Color(0xFFD9A84E); // brass for small text on panels

  // Brass: the signature color (the intro's words). Main buttons, the logo dot, highlights.
  static const gold = Color(0xFFD9A84E);
  static const onGold = Color(0xFF1C1009); // text on brass
  // brass for text and icons on the page: deeper on parchment so it stays readable
  static Color get goldInk => _c(0xFF94621C, 0xFFD9A84E);
  // The feature card on Home (tonight's call): oxblood leather in both modes.
  static Color get hero => _c(0xFF5C1F14, 0xFF4E1A11);
  static Color get slogan => _c(0xFF6E3B1C, 0xFFD9A84E);

  // Cognac / amber: the ONE action color (links, selected things, switches)
  static Color get accent => _c(0xFF8C4A1C, 0xFFE0A955);
  static Color get accentSoft => _c(0xFFEFDDBE, 0xFF2E2014);
  static Color get accentMid => _c(0xFFD6B585, 0xFF5C4126); // radar rings
  static Color get accentStrong => _c(0xFF6E3B1C, 0xFFE6B866); // accent-colored text on soft fills

  // Status
  static Color get urgent => _c(0xFF9A2E1E, 0xFFE58A62); // under 24h, and anything destructive (oxblood / ember)
  static Color get urgentSoft => _c(0xFFF2DCD0, 0xFF3A1C12);
  static Color get soon => _c(0xFF8C4A1C, 0xFFE0B57A); // under 2 days (cognac / amber)
  static Color get soonSoft => _c(0xFFEFDDBE, 0xFF2E2014);
  static Color get ok => _c(0xFF4B6B38, 0xFF9DBB7E); // bottle green
  static Color get okSoft => _c(0xFFE6EBD7, 0xFF1E2616);
  static Color get okInk => _c(0xFF34502A, 0xFFBFD6A6); // text on okSoft

  // Traffic-light colors used for small status dots and counts, toned to sit in the room
  static const good = Color(0xFF6E9A4E);
  static const caution = Color(0xFFD99A3A);
  static const bad = Color(0xFFC0533A);

  static const radius = 4.0; // near-square corners: gallery-sharp
  static const navHeight = 70.0;
  static const navClearance = 28.0; // bottom padding at the end of scrolling pages

  // Barely-there shadows; edges come from fine hairlines instead.
  static List<BoxShadow> get shadow => isDark
      ? const [BoxShadow(color: Color(0x66000000), blurRadius: 16, spreadRadius: -8, offset: Offset(0, 6))]
      : const [BoxShadow(color: Color(0x142A1A0F), blurRadius: 12, spreadRadius: -6, offset: Offset(0, 4))];

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
      onPrimary: isDark ? onGold : const Color(0xFFFBF6EC),
      secondary: gold,
      onSecondary: onGold,
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
          backgroundColor: gold, // main buttons are brass with dark walnut text
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
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? (isDark ? onGold : Colors.white) : muted),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : fill),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: panel,
        contentTextStyle: const TextStyle(color: Color(0xFFF1E6D0)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    );
  }
}
