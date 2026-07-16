import 'package:flutter/material.dart';

class AppTypography {
  AppTypography._();

  static const outfit = 'Outfit';
  static const manropeFamily = 'Manrope';
  static const interFamily = 'Inter';
  static const jetBrainsMonoFamily = 'JetBrains Mono';

  static TextTheme outfitTextTheme(TextTheme base) =>
      base.apply(fontFamily: outfit);

  static TextStyle manrope({TextStyle? textStyle}) =>
      (textStyle ?? const TextStyle()).copyWith(fontFamily: manropeFamily);

  static TextStyle inter({TextStyle? textStyle}) =>
      (textStyle ?? const TextStyle()).copyWith(fontFamily: interFamily);

  static TextStyle jetBrainsMono({TextStyle? textStyle}) =>
      (textStyle ?? const TextStyle()).copyWith(
        fontFamily: jetBrainsMonoFamily,
      );
}
