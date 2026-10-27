import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Shared Quicksand style for action labels at 14 logical pixels.
final TextStyle kCtaTextStyle = GoogleFonts.quicksand(
  textStyle: ThemeData.light().textTheme.bodyMedium,
).copyWith(fontSize: 14, fontWeight: FontWeight.w800);
