import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The former « Signaler » inherited the app's Quicksand body font from Material.
/// Keep that loaded font variant while raising the label to 16 logical pixels.
final TextStyle kCtaTextStyle = GoogleFonts.quicksand(
  textStyle: ThemeData.light().textTheme.bodyMedium,
).copyWith(fontSize: 16, fontWeight: FontWeight.w800);
