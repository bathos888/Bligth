import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Couleurs Google Home
  static const Color backgroundDark = Color(0xFF121212);
  static const Color surfaceDark = Color(0xFF1E1E1E);
  static const Color cardDark = Color(0xFF2D2D2D);
  static const Color accentWarm = Color(0xFFF4B400);  // Ambre/Or
  static const Color accentCool = Color(0xFF4285F4);  // Bleu Google
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Colors.white70;
  static const Color inactive = Colors.white24;

  static ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: backgroundDark,
    colorScheme: const ColorScheme.dark(
      primary: accentWarm,
      secondary: accentCool,
      surface: surfaceDark,
      background: backgroundDark,
      onBackground: textPrimary,
      onSurface: textPrimary,
    ),
    textTheme: GoogleFonts.robotoTextTheme(ThemeData.dark().textTheme),
    cardTheme: CardThemeData(
      color: cardDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 0,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: accentWarm,
      thumbColor: accentWarm,
      overlayColor: accentWarm.withOpacity(0.2),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: MaterialStateProperty.resolveWith((states) {
        if (states.contains(MaterialState.selected)) return accentWarm;
        return Colors.grey;
      }),
      trackColor: MaterialStateProperty.resolveWith((states) {
        if (states.contains(MaterialState.selected)) return accentWarm.withOpacity(0.5);
        return Colors.grey.withOpacity(0.3);
      }),
    ),
  );
}
