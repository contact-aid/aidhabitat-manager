import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The former « Signaler » inherited the app's Quicksand body font from Material.
/// Keep the same font variant at the requested 14 logical pixels.
final TextStyle kCtaTextStyle = GoogleFonts.quicksand(
  textStyle: ThemeData.light().textTheme.bodyMedium,
).copyWith(fontSize: 14, fontWeight: FontWeight.w800);
