import 'package:flutter/material.dart';

/// The design system.
///
/// Two surface families, deliberately: paper for the document (everything transcribed from the
/// sheets) and hardware for the boards (the connector faces and the faceplate). A reader should
/// be able to tell at a glance whether they are looking at a description of the vehicle or at a
/// picture of a part they can put a finger on.
class Tone {
  // Paper.
  static const bg = Color(0xFFEEF1F6);
  static const surface = Color(0xFFFFFFFF);
  static const sunken = Color(0xFFF5F7FB);
  static const hairline = Color(0xFFE3E8F0);
  static const hairlineStrong = Color(0xFFCFD7E3);

  static const ink = Color(0xFF101826);
  static const muted = Color(0xFF5C6779);
  static const faint = Color(0xFF97A1B2);

  // Hardware.
  static const board = Color(0xFF151B26);
  static const boardCell = Color(0xFF1F2733);
  static const boardCellLive = Color(0xFF27344B);
  static const boardEdge = Color(0xFF323C4C);
  static const boardInk = Color(0xFFE6EDF7);
  static const boardMuted = Color(0xFF8B98AC);

  /// Interaction. Used for selection and nothing else -- a blue thing on this screen is a thing
  /// the user chose, never a thing the vehicle did.
  static const accent = Color(0xFF2563EB);

  // Device taxonomy. Identity only; never used to mean a state.
  static const lidar = Color(0xFF0EA5C4);
  static const camera = Color(0xFF109E6D);
  static const acu = Color(0xFF7A64EC);
  static const aux = Color(0xFFE07C1B);

  /// The KETI insertion. A hue nothing on the a2z sheets uses, so the backbone never reads as
  /// part of the document it was added to.
  static const tsn = Color(0xFFBE3F97);

  // Link state. State only; never used to mean an identity.
  static const ok = Color(0xFF17914D);
  static const warn = Color(0xFFC77A08);
  static const bad = Color(0xFFC8362D);
}

/// Type scale. Identifiers -- port numbers, cavities, part numbers, rates -- are set in
/// monospace with tabular figures, because they are read as codes and compared column to column,
/// not read as words.
class Type {
  static const display = TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.4, height: 1.1);
  static const title = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, letterSpacing: -0.1);
  static const body = TextStyle(fontSize: 12, height: 1.45);
  static const bodyStrong = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, height: 1.4);
  static const small = TextStyle(fontSize: 11, height: 1.45, color: Tone.muted);
  static const tiny = TextStyle(fontSize: 10.5, height: 1.4, color: Tone.faint);

  static const label = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w800,
    letterSpacing: 1.2,
    color: Tone.muted,
  );

  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['Roboto Mono', 'Droid Sans Mono'],
    fontFeatures: [FontFeature.tabularFigures()],
    letterSpacing: -0.2,
  );

  static TextStyle monoAt(double size, {FontWeight weight = FontWeight.w600, Color? colour}) =>
      mono.copyWith(fontSize: size, fontWeight: weight, color: colour);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: Tone.bg,
    colorScheme: ColorScheme.fromSeed(seedColor: Tone.accent, brightness: Brightness.light),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: Tone.ink, displayColor: Tone.ink),
    splashFactory: InkSparkle.splashFactory,
  );
}

/// A paper card. One hairline and a barely-there lift -- on a screen this dense, a heavy shadow
/// per card turns into visual noise long before it reads as depth.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? tint;
  final Color? edge;

  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.tint,
    this.edge,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: tint ?? Tone.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: edge ?? Tone.hairline),
        boxShadow: const [
          BoxShadow(color: Color(0x0A1B2A44), blurRadius: 14, offset: Offset(0, 3)),
        ],
      ),
      child: child,
    );
  }
}

/// An inset surface, for rows of controls or readouts that sit inside a panel.
class Well extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const Well({super.key, required this.child, this.padding = const EdgeInsets.all(10)});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Tone.sunken,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Tone.hairline),
      ),
      child: child,
    );
  }
}

/// The hardware surface: a dark panel with a light top edge, so a connector face reads as a
/// moulded part rather than as another card that happens to be dark.
class Board extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const Board({super.key, required this.child, this.padding = const EdgeInsets.all(11)});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1B2331), Tone.board],
        ),
        border: Border.all(color: const Color(0xFF2B3444)),
        boxShadow: const [
          BoxShadow(color: Color(0x22101826), blurRadius: 12, offset: Offset(0, 4)),
        ],
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
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(text.toUpperCase(), style: Type.label),
        const SizedBox(width: 10),
        const Expanded(child: Divider(height: 1, thickness: 1, color: Tone.hairline)),
        if (trailing != null) ...[
          const SizedBox(width: 10),
          Text(trailing!, style: Type.tiny),
        ],
      ],
    );
  }
}

class Chip2 extends StatelessWidget {
  final String label;
  final Color color;
  final bool solid;
  final bool mono;

  const Chip2(this.label, {super.key, this.color = Tone.muted, this.solid = false, this.mono = false});

  @override
  Widget build(BuildContext context) {
    final style = (mono ? Type.mono : const TextStyle()).copyWith(
      fontSize: 10.5,
      height: 1.2,
      fontWeight: FontWeight.w700,
      color: solid ? Colors.white : color,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: solid ? color : color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: solid ? 1 : 0.28)),
      ),
      child: Text(label, style: style),
    );
  }
}

/// Dot plus label. The dot carries the state; the label says what the state is, because a dot
/// alone asks the reader to remember a colour key that is somewhere else on the screen.
class StatusPill extends StatelessWidget {
  final String label;
  final Color colour;
  final bool emphasis;

  const StatusPill({super.key, required this.label, required this.colour, this.emphasis = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 5, 11, 5),
      decoration: BoxDecoration(
        color: emphasis ? colour.withValues(alpha: 0.12) : Tone.sunken,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: emphasis ? colour.withValues(alpha: 0.42) : Tone.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: colour, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: emphasis ? colour : Tone.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// A fact and its value, aligned in a column so a run of them reads as a table. Values default to
/// monospace: they are part numbers and port ids far more often than they are prose.
class KeyValue extends StatelessWidget {
  final String label;
  final String value;
  final double labelWidth;
  final bool mono;
  final Color? colour;
  final FontStyle? style;
  final Widget? badge;

  const KeyValue(
    this.label,
    this.value, {
    super.key,
    this.labelWidth = 84,
    this.mono = true,
    this.colour,
    this.style,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(label, style: const TextStyle(fontSize: 11, color: Tone.faint, height: 1.35)),
          ),
          Expanded(
            child: Text(
              value,
              style: (mono ? Type.mono : const TextStyle()).copyWith(
                fontSize: 11.5,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: colour ?? Tone.ink,
                fontStyle: style,
              ),
            ),
          ),
          if (badge != null) ...[const SizedBox(width: 6), badge!],
        ],
      ),
    );
  }
}

/// A short callout. Warnings on this screen are about the source documents, not about the app,
/// so they read as a marginal note rather than an alert.
class Note extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color colour;

  const Note(this.text, {super.key, this.icon = Icons.error_outline, this.colour = Tone.warn});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(11),
        border: Border(left: BorderSide(color: colour.withValues(alpha: 0.55), width: 3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: colour),
          const SizedBox(width: 9),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 11.5, color: Tone.ink, height: 1.5)),
          ),
        ],
      ),
    );
  }
}
