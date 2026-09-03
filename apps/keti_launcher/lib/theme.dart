import 'package:flutter/material.dart';

/// The rig look: near-black, one accent per module, red reserved for a cut path.
///
/// Dark is not decoration here. This tablet is a TB-8504F -- a 2 GB Snapdragon 425 with an IPS
/// panel -- and the app is its home screen, on all day next to the bench. A flat dark surface
/// costs the least to redraw (no gradients, no elevation shadows, no blurs anywhere in this app)
/// and keeps the panel from lighting the rig up in demo photographs.
class K {
  static const bg = Color(0xFF0A0C10);
  static const surface = Color(0xFF151A21);
  static const surfaceHi = Color(0xFF1D242D);
  static const border = Color(0xFF2A323D);
  static const text = Color(0xFFE6EAF0);
  static const muted = Color(0xFF8B96A5);
  static const dim = Color(0xFF5A6675);

  static const fault = Color(0xFFEF4444);
  static const ok = Color(0xFF22C55E);
  static const warn = Color(0xFFF59E0B);

  /// Matched to the WS2812 on each board, so the tile and the module on the bench are the same
  /// colour: path 1 green, 2 blue, 3 cyan, 4 magenta. Whoever is holding the tablet and whoever
  /// is looking at the rig are then talking about the same thing.
  static const pathColours = <int, Color>{
    1: Color(0xFF22C55E),
    2: Color(0xFF3B82F6),
    3: Color(0xFF06B6D4),
    4: Color(0xFFD946EF),
  };

  static Color pathColour(int n) => pathColours[n] ?? muted;

  static ThemeData theme() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: base.colorScheme.copyWith(
        surface: surface,
        primary: ok,
        onSurface: text,
      ),
      dividerColor: border,
      splashFactory: NoSplash.splashFactory,
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
    );
  }

  /// Monospace for anything that is a reading rather than a word -- sequence numbers, ages, RSSI.
  /// Digits that change every second must not reflow the row they sit in.
  static const mono = TextStyle(fontFamily: 'monospace', fontFeatures: [FontFeature.tabularFigures()]);
}
