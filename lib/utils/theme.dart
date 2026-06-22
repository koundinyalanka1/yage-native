import 'package:flutter/material.dart';

/// Defines a complete app color theme as a [ThemeExtension].
///
/// Access the current theme in any widget via [AppColorTheme.of]:
/// ```dart
/// final colors = AppColorTheme.of(context);
/// Container(color: colors.primary);
/// ```
///
/// Because it's stored inside [ThemeData.extensions], any widget that calls
/// [AppColorTheme.of] (which uses [Theme.of]) will automatically rebuild
/// when the theme changes — no static mutable state needed.
class AppColorTheme extends ThemeExtension<AppColorTheme> {
  final String id;
  final String name;
  final String emoji;

  // Primary colors
  final Color primary;
  final Color primaryDark;
  final Color primaryLight;

  // Accent colors
  final Color accent;
  final Color accentAlt;
  final Color accentYellow;

  // Background colors
  final Color backgroundDark;
  final Color backgroundMedium;
  final Color backgroundLight;
  final Color surface;
  final Color surfaceLight;

  // Text colors
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  // Platform colors
  final Color gbColor;
  final Color gbcColor;
  final Color gbaColor;
  final Color nesColor;
  final Color snesColor;
  final Color smsColor;
  final Color ggColor;
  final Color mdColor;
  final Color ngpColor;
  final Color wsColor;
  final Color wscColor;
  final Color a2600Color;
  final Color vbColor;
  final Color tic80Color;
  final Color pico8Color;
  final Color ndsColor;
  final Color ps1Color;
  final Color intvColor;

  // State colors
  final Color success;
  final Color warning;
  final Color error;

  const AppColorTheme({
    required this.id,
    required this.name,
    required this.emoji,
    required this.primary,
    required this.primaryDark,
    required this.primaryLight,
    required this.accent,
    required this.accentAlt,
    required this.accentYellow,
    required this.backgroundDark,
    required this.backgroundMedium,
    required this.backgroundLight,
    required this.surface,
    required this.surfaceLight,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    this.gbColor = const Color(0xFF8BC34A),
    this.gbcColor = const Color(0xFF03A9F4),
    this.gbaColor = const Color(0xFFE91E63),
    this.nesColor = const Color(0xFFE53935), // NES red
    this.snesColor = const Color(0xFF7B1FA2), // SNES purple
    this.smsColor = const Color(0xFF1565C0), // SMS blue
    this.ggColor = const Color(0xFF00897B), // Game Gear teal
    this.mdColor = const Color(0xFFFF6F00), // Mega Drive amber
    this.ngpColor = const Color(0xFF546E7A), // NGP slate
    this.wsColor = const Color(0xFF5C6BC0), // WS slate blue
    this.wscColor = const Color(0xFFAB47BC), // WSC violet
    this.a2600Color = const Color(0xFF8D6E63), // Atari 2600 woodgrain brown
    this.vbColor = const Color(0xFFD32F2F), // Virtual Boy red
    this.tic80Color = const Color(0xFF1A1A2E), // TIC-80 deep navy
    this.pico8Color = const Color(0xFFFF77A8), // PICO-8 hot pink (color #14)
    this.ndsColor = const Color(0xFF1976D2), // NDS clamshell blue
    this.ps1Color = const Color(0xFF455A64), // PS1 gray
    this.intvColor = const Color(0xFFBF360C), // Intellivision rust orange
    this.success = const Color(0xFF4CAF50),
    this.warning = const Color(0xFFFF9800),
    this.error = const Color(0xFFF44336),
  });

  /// Convenient context-based accessor.
  ///
  /// Widgets that call this will automatically rebuild when the theme changes.
  static AppColorTheme of(BuildContext context) {
    return Theme.of(context).extension<AppColorTheme>()!;
  }

  @override
  AppColorTheme copyWith({
    String? id,
    String? name,
    String? emoji,
    Color? primary,
    Color? primaryDark,
    Color? primaryLight,
    Color? accent,
    Color? accentAlt,
    Color? accentYellow,
    Color? backgroundDark,
    Color? backgroundMedium,
    Color? backgroundLight,
    Color? surface,
    Color? surfaceLight,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? gbColor,
    Color? gbcColor,
    Color? gbaColor,
    Color? nesColor,
    Color? snesColor,
    Color? smsColor,
    Color? ggColor,
    Color? mdColor,
    Color? ngpColor,
    Color? wsColor,
    Color? wscColor,
    Color? a2600Color,
    Color? vbColor,
    Color? tic80Color,
    Color? pico8Color,
    Color? ndsColor,
    Color? ps1Color,
    Color? intvColor,
    Color? success,
    Color? warning,
    Color? error,
  }) {
    return AppColorTheme(
      id: id ?? this.id,
      name: name ?? this.name,
      emoji: emoji ?? this.emoji,
      primary: primary ?? this.primary,
      primaryDark: primaryDark ?? this.primaryDark,
      primaryLight: primaryLight ?? this.primaryLight,
      accent: accent ?? this.accent,
      accentAlt: accentAlt ?? this.accentAlt,
      accentYellow: accentYellow ?? this.accentYellow,
      backgroundDark: backgroundDark ?? this.backgroundDark,
      backgroundMedium: backgroundMedium ?? this.backgroundMedium,
      backgroundLight: backgroundLight ?? this.backgroundLight,
      surface: surface ?? this.surface,
      surfaceLight: surfaceLight ?? this.surfaceLight,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      gbColor: gbColor ?? this.gbColor,
      gbcColor: gbcColor ?? this.gbcColor,
      gbaColor: gbaColor ?? this.gbaColor,
      nesColor: nesColor ?? this.nesColor,
      snesColor: snesColor ?? this.snesColor,
      smsColor: smsColor ?? this.smsColor,
      ggColor: ggColor ?? this.ggColor,
      mdColor: mdColor ?? this.mdColor,
      ngpColor: ngpColor ?? this.ngpColor,
      wsColor: wsColor ?? this.wsColor,
      wscColor: wscColor ?? this.wscColor,
      a2600Color: a2600Color ?? this.a2600Color,
      vbColor: vbColor ?? this.vbColor,
      tic80Color: tic80Color ?? this.tic80Color,
      pico8Color: pico8Color ?? this.pico8Color,
      ndsColor: ndsColor ?? this.ndsColor,
      ps1Color: ps1Color ?? this.ps1Color,
      intvColor: intvColor ?? this.intvColor,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
    );
  }

  @override
  AppColorTheme lerp(AppColorTheme? other, double t) {
    if (other is! AppColorTheme) return this;
    return AppColorTheme(
      id: t < 0.5 ? id : other.id,
      name: t < 0.5 ? name : other.name,
      emoji: t < 0.5 ? emoji : other.emoji,
      primary: Color.lerp(primary, other.primary, t)!,
      primaryDark: Color.lerp(primaryDark, other.primaryDark, t)!,
      primaryLight: Color.lerp(primaryLight, other.primaryLight, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentAlt: Color.lerp(accentAlt, other.accentAlt, t)!,
      accentYellow: Color.lerp(accentYellow, other.accentYellow, t)!,
      backgroundDark: Color.lerp(backgroundDark, other.backgroundDark, t)!,
      backgroundMedium: Color.lerp(
        backgroundMedium,
        other.backgroundMedium,
        t,
      )!,
      backgroundLight: Color.lerp(backgroundLight, other.backgroundLight, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceLight: Color.lerp(surfaceLight, other.surfaceLight, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      gbColor: Color.lerp(gbColor, other.gbColor, t)!,
      gbcColor: Color.lerp(gbcColor, other.gbcColor, t)!,
      gbaColor: Color.lerp(gbaColor, other.gbaColor, t)!,
      nesColor: Color.lerp(nesColor, other.nesColor, t)!,
      snesColor: Color.lerp(snesColor, other.snesColor, t)!,
      smsColor: Color.lerp(smsColor, other.smsColor, t)!,
      ggColor: Color.lerp(ggColor, other.ggColor, t)!,
      mdColor: Color.lerp(mdColor, other.mdColor, t)!,
      ngpColor: Color.lerp(ngpColor, other.ngpColor, t)!,
      wsColor: Color.lerp(wsColor, other.wsColor, t)!,
      wscColor: Color.lerp(wscColor, other.wscColor, t)!,
      a2600Color: Color.lerp(a2600Color, other.a2600Color, t)!,
      vbColor: Color.lerp(vbColor, other.vbColor, t)!,
      tic80Color: Color.lerp(tic80Color, other.tic80Color, t)!,
      pico8Color: Color.lerp(pico8Color, other.pico8Color, t)!,
      ndsColor: Color.lerp(ndsColor, other.ndsColor, t)!,
      ps1Color: Color.lerp(ps1Color, other.ps1Color, t)!,
      intvColor: Color.lerp(intvColor, other.intvColor, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
    );
  }
}

/// All available app themes
class AppThemes {
  static const List<AppColorTheme> all = [
    // 0 — Neon Night (default, the original purple/teal theme)
    AppColorTheme(
      id: 'neon_night',
      name: 'Neon Night',
      emoji: '\u{1F303}',
      primary: Color(0xFF6B4EE6),
      primaryDark: Color(0xFF4A2FB8),
      primaryLight: Color(0xFF9B7EFF),
      accent: Color(0xFF00F5D4),
      accentAlt: Color(0xFFFF6B6B),
      accentYellow: Color(0xFFFEE440),
      backgroundDark: Color(0xFF0D0D1A),
      backgroundMedium: Color(0xFF151528),
      backgroundLight: Color(0xFF1E1E38),
      surface: Color(0xFF252545),
      surfaceLight: Color(0xFF2D2D55),
      textPrimary: Color(0xFFF0F0FF),
      textSecondary: Color(0xFFA0A0C0),
      textMuted: Color(0xFF606080),
    ),

    // 1 — Crimson Blaze
    AppColorTheme(
      id: 'crimson_blaze',
      name: 'Crimson Blaze',
      emoji: '\u{1F525}',
      primary: Color(0xFFE63946),
      primaryDark: Color(0xFFB5212D),
      primaryLight: Color(0xFFFF6B7A),
      accent: Color(0xFFFFB703),
      accentAlt: Color(0xFFFF4D6D),
      accentYellow: Color(0xFFFEE440),
      backgroundDark: Color(0xFF100808),
      backgroundMedium: Color(0xFF1A0F0F),
      backgroundLight: Color(0xFF2A1818),
      surface: Color(0xFF352020),
      surfaceLight: Color(0xFF452A2A),
      textPrimary: Color(0xFFFFF0F0),
      textSecondary: Color(0xFFC0A0A0),
      textMuted: Color(0xFF806060),
    ),

    // 2 — Cyberpunk
    AppColorTheme(
      id: 'cyberpunk',
      name: 'Cyberpunk',
      emoji: '\u26A1',
      primary: Color(0xFFFF2A6D),
      primaryDark: Color(0xFFD1184F),
      primaryLight: Color(0xFFFF6B9D),
      accent: Color(0xFF05D9E8),
      accentAlt: Color(0xFFFF2A6D),
      accentYellow: Color(0xFFD1F7FF),
      backgroundDark: Color(0xFF01012B),
      backgroundMedium: Color(0xFF050533),
      backgroundLight: Color(0xFF0A0A3E),
      surface: Color(0xFF12124A),
      surfaceLight: Color(0xFF1A1A5C),
      textPrimary: Color(0xFFD1F7FF),
      textSecondary: Color(0xFF7EB8C9),
      textMuted: Color(0xFF3E6A78),
    ),

    // 3 — Emerald Forest
    AppColorTheme(
      id: 'emerald_forest',
      name: 'Emerald',
      emoji: '\u{1F332}',
      primary: Color(0xFF00C853),
      primaryDark: Color(0xFF009624),
      primaryLight: Color(0xFF5EFC82),
      accent: Color(0xFF69F0AE),
      accentAlt: Color(0xFFFFD740),
      accentYellow: Color(0xFFFFEB3B),
      backgroundDark: Color(0xFF0A1410),
      backgroundMedium: Color(0xFF0F1D16),
      backgroundLight: Color(0xFF162B20),
      surface: Color(0xFF1E3A2A),
      surfaceLight: Color(0xFF264A35),
      textPrimary: Color(0xFFE8F5E9),
      textSecondary: Color(0xFF8DC49A),
      textMuted: Color(0xFF4E7B5C),
    ),

    // 4 — Midnight Ocean
    AppColorTheme(
      id: 'midnight_ocean',
      name: 'Ocean',
      emoji: '\u{1F30A}',
      primary: Color(0xFF0088FF),
      primaryDark: Color(0xFF0055CC),
      primaryLight: Color(0xFF55AAFF),
      accent: Color(0xFF00E5FF),
      accentAlt: Color(0xFF7C4DFF),
      accentYellow: Color(0xFF82B1FF),
      backgroundDark: Color(0xFF060D14),
      backgroundMedium: Color(0xFF0A1520),
      backgroundLight: Color(0xFF102030),
      surface: Color(0xFF142840),
      surfaceLight: Color(0xFF1A3250),
      textPrimary: Color(0xFFE3F2FD),
      textSecondary: Color(0xFF90CAF9),
      textMuted: Color(0xFF4A7A9B),
    ),

    // 5 — Sunset Haze
    AppColorTheme(
      id: 'sunset_haze',
      name: 'Sunset',
      emoji: '\u{1F305}',
      primary: Color(0xFFFF7043),
      primaryDark: Color(0xFFD84315),
      primaryLight: Color(0xFFFFAB91),
      accent: Color(0xFFFFD54F),
      accentAlt: Color(0xFFFF8A80),
      accentYellow: Color(0xFFFFF176),
      backgroundDark: Color(0xFF140E0A),
      backgroundMedium: Color(0xFF1E150F),
      backgroundLight: Color(0xFF2E2018),
      surface: Color(0xFF3E2C22),
      surfaceLight: Color(0xFF50382C),
      textPrimary: Color(0xFFFFF3E0),
      textSecondary: Color(0xFFCCAA88),
      textMuted: Color(0xFF806650),
    ),
  ];

  /// The default theme (Neon Night).
  static AppColorTheme get defaultTheme => all.first;

  static AppColorTheme getById(String id) {
    return all.firstWhere((t) => t.id == id, orElse: () => all.first);
  }

  static AppColorTheme getByIndex(int index) {
    if (index < 0 || index >= all.length) return all.first;
    return all[index];
  }
}

/// RetroPal theme configuration.
///
/// Call [YageTheme.darkTheme] with an [AppColorTheme] to get a fully
/// configured [ThemeData] that carries the color theme as a
/// [ThemeExtension] — accessible everywhere via [AppColorTheme.of].
class YageTheme {
  static const String _fontFamily = 'Rajdhani';
  static const String _monoFontFamily = 'JetBrains Mono';

  static ThemeData darkTheme(AppColorTheme colors) {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: _fontFamily,

      // Carry the full color theme so widgets can read it via
      // AppColorTheme.of(context).
      extensions: [colors],

      // Color scheme
      colorScheme: ColorScheme.dark(
        primary: colors.primary,
        secondary: colors.accent,
        surface: colors.surface,
        error: colors.error,
        onPrimary: colors.textPrimary,
        onSecondary: colors.backgroundDark,
        onSurface: colors.textPrimary,
        onError: colors.textPrimary,
      ),

      // Scaffold
      scaffoldBackgroundColor: colors.backgroundDark,

      // AppBar
      appBarTheme: AppBarTheme(
        backgroundColor: colors.backgroundMedium,
        foregroundColor: colors.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: colors.textPrimary,
        ),
      ),

      // Cards
      cardTheme: CardThemeData(
        color: colors.surface,
        elevation: 4,
        shadowColor: Colors.black54,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      // Buttons
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colors.primary,
          foregroundColor: colors.textPrimary,
          elevation: 4,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontFamily: _fontFamily,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.accent,
          side: BorderSide(color: colors.accent, width: 2),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: colors.accent),
      ),

      // FAB
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colors.accent,
        foregroundColor: colors.backgroundDark,
        elevation: 6,
      ),

      // Icons
      iconTheme: IconThemeData(color: colors.textPrimary, size: 24),

      // Text
      textTheme: TextTheme(
        displayLarge: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 48,
          fontWeight: FontWeight.bold,
          color: colors.textPrimary,
        ),
        displayMedium: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 36,
          fontWeight: FontWeight.bold,
          color: colors.textPrimary,
        ),
        displaySmall: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 28,
          fontWeight: FontWeight.bold,
          color: colors.textPrimary,
        ),
        headlineLarge: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: colors.textPrimary,
        ),
        headlineMedium: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: colors.textPrimary,
        ),
        headlineSmall: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
        titleLarge: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
        titleMedium: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
        titleSmall: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: colors.textSecondary,
        ),
        bodyLarge: TextStyle(fontSize: 16, color: colors.textPrimary),
        bodyMedium: TextStyle(fontSize: 14, color: colors.textSecondary),
        bodySmall: TextStyle(fontSize: 12, color: colors.textMuted),
        labelLarge: TextStyle(
          fontFamily: _monoFontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
        labelMedium: TextStyle(
          fontFamily: _monoFontFamily,
          fontSize: 12,
          color: colors.textSecondary,
        ),
        labelSmall: TextStyle(
          fontFamily: _monoFontFamily,
          fontSize: 10,
          color: colors.textMuted,
        ),
      ),

      // Input decoration
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.backgroundLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.surfaceLight, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.primary, width: 2),
        ),
        hintStyle: TextStyle(color: colors.textMuted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),

      // Slider
      sliderTheme: SliderThemeData(
        activeTrackColor: colors.primary,
        inactiveTrackColor: colors.surfaceLight,
        thumbColor: colors.accent,
        overlayColor: colors.accent.withAlpha(51),
        trackHeight: 4,
      ),

      // Switch
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colors.accent;
          }
          return colors.textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colors.primary;
          }
          return colors.surfaceLight;
        }),
      ),

      // Divider
      dividerTheme: DividerThemeData(color: colors.surfaceLight, thickness: 1),

      // Bottom nav
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: colors.backgroundMedium,
        selectedItemColor: colors.accent,
        unselectedItemColor: colors.textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),

      // Dialogs
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),

      // Snackbar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.surfaceLight,
        contentTextStyle: TextStyle(color: colors.textPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),

      // Progress indicator
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.accent,
        linearTrackColor: colors.surfaceLight,
      ),

      // Tab bar
      tabBarTheme: TabBarThemeData(
        labelColor: colors.textPrimary,
        unselectedLabelColor: colors.textMuted,
        indicatorColor: colors.primary,
      ),
    );
  }
}
