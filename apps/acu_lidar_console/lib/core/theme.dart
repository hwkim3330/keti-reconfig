import 'package:flutter/material.dart';

/// The light instrument palette carried over from the reconfig console, so the two apps read
/// as one toolkit on the same tablet.
class Tone {
  static const bg = Color(0xFFF2F4F7);
  static const panel = Colors.white;
  static const line = Color(0xFFE2E6ED);
  static const text = Color(0xFF16202E);
  static const muted = Color(0xFF6B7688);
  static const faint = Color(0xFF9AA5B5);

  static const accent = Color(0xFF2F7FEB);
  static const lidar = Color(0xFF18B6D6);
  static const camera = Color(0xFF2FAE60);
  static const acu = Color(0xFF7A6BF0);
  static const other = Color(0xFFEF8A2B);

  static const ok = Color(0xFF23A25B);
  static const warn = Color(0xFFE0A03A);
  static const bad = Color(0xFFD8453C);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: Tone.bg,
    colorScheme: ColorScheme.fromSeed(seedColor: Tone.accent, brightness: Brightness.light),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: Tone.text, displayColor: Tone.text),
  );
}

/// A panel. Every surface in the console is one of these, so spacing and edges stay uniform.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? tint;

  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.tint});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: tint ?? Tone.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Tone.line),
      ),
      child: child,
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final String? trailing;

  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
            color: Tone.muted,
          ),
        ),
        const Spacer(),
        if (trailing != null)
          Text(trailing!, style: const TextStyle(fontSize: 11, color: Tone.faint)),
      ],
    );
  }
}

class Chip2 extends StatelessWidget {
  final String label;
  final Color color;
  final bool solid;

  const Chip2(this.label, {super.key, this.color = Tone.muted, this.solid = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: solid ? color : color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: solid ? 1 : 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: solid ? Colors.white : color,
        ),
      ),
    );
  }
}
