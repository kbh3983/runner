import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  /// 메인 컬러 (형광 라임)
  static const neon = Color(0xFFCCFF00);
  static const neonDim = Color(0xFF9EC700);
  static const bg = Color(0xFF0D0E11);
  static const surface = Color(0xFF17191E);
  static const surfaceHigh = Color(0xFF22252C);
  static const outline = Color(0xFF2E323A);
  static const textPrimary = Color(0xFFF4F6F8);
  static const textSecondary = Color(0xFF9AA1AC);
  static const route = Color(0xFF00E676); // 내 경로 (초록)
  static const danger = Color(0xFFFF5252);
  static const gold = Color(0xFFFFD54F);
  static const silver = Color(0xFFCFD8DC);
  static const bronze = Color(0xFFD7A26C);
}

class AppTheme {
  AppTheme._();

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.neon,
      brightness: Brightness.dark,
    ).copyWith(
      primary: AppColors.neon,
      onPrimary: Colors.black,
      secondary: AppColors.route,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      error: AppColors.danger,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bg,
      brightness: Brightness.dark,
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: AppColors.textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.neon,
          foregroundColor: Colors.black,
          minimumSize: const Size.fromHeight(52),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          minimumSize: const Size.fromHeight(52),
          side: const BorderSide(color: AppColors.outline),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.neon, width: 1.5),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.surfaceHigh,
        contentTextStyle: TextStyle(color: AppColors.textPrimary),
      ),
      dividerColor: AppColors.outline,
    );
  }
}

/// 어두운 지도 스타일 (Google Maps JSON)
const String kDarkMapStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#1d2026"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#8a9099"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#1d2026"}]},
  {"featureType":"poi","elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#1f2b24"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#2c3038"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#3a3f49"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0f1a24"}]}
]
''';
