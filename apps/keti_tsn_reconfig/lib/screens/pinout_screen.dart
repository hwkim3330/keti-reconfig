import 'package:flutter/material.dart';

import '../core/reference.dart';
import '../core/theme.dart';
import '../widgets/sheet_image.dart';

/// The wire tables, as tables. This is the one page where the right answer is a grid: a crimper
/// reads down a column, and every row is a cavity, a gauge, a colour and a signal.
class PinoutScreen extends StatelessWidget {
  const PinoutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      itemCount: pinouts.length,
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (_, i) => _PinoutCard(pinout: pinouts[i]),
    );
  }
}

class _PinoutCard extends StatelessWidget {
  final Pinout pinout;

  const _PinoutCard({required this.pinout});

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(pinout.title, trailing: pinout.connector),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: _Table(rows: pinout.rows)),
              if (pinout.refImage != null) ...[
                const SizedBox(width: 18),
                SizedBox(
                  width: 268,
                  child: SheetImage(
                    asset: pinout.refImage!,
                    title: 'Source drawing',
                    caption: 'Tap to zoom',
                    height: 172,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Note(pinout.note, icon: Icons.push_pin_outlined, colour: Tone.muted),
        ],
      ),
    );
  }
}

class _Table extends StatelessWidget {
  final List<PinRow> rows;

  const _Table({required this.rows});

  @override
  Widget build(BuildContext context) {
    Widget head(String s) => Text(s, style: Type.label);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              SizedBox(width: 96, child: head('CAV')),
              Expanded(flex: 4, child: head('CSA / PART')),
              SizedBox(width: 92, child: head('COLOUR')),
              Expanded(flex: 4, child: head('SIGNAL')),
              Expanded(flex: 4, child: head('COMMENT')),
            ],
          ),
        ),
        for (var i = 0; i < rows.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: i.isOdd ? Tone.sunken.withValues(alpha: 0.7) : null,
              border: const Border(top: BorderSide(color: Tone.hairline)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 96,
                  child: Text(rows[i].cav, style: Type.monoAt(11.5, weight: FontWeight.w800)),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    rows[i].csa,
                    style: Type.monoAt(10.5, weight: FontWeight.w500, colour: Tone.muted)
                        .copyWith(height: 1.4),
                  ),
                ),
                SizedBox(width: 92, child: _Colour(name: rows[i].colour)),
                Expanded(
                  flex: 4,
                  child: Text(rows[i].signal,
                      style: const TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w600, height: 1.35)),
                ),
                Expanded(flex: 4, child: Text(rows[i].comment, style: Type.tiny)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Wire colours are what a crimper actually goes by, so they are shown as colour and not only as
/// a word. White gets an outline or it disappears into the row.
class _Colour extends StatelessWidget {
  final String name;

  const _Colour({required this.name});

  static const _swatches = {
    'GREEN': Color(0xFF2FAE60),
    'WHITE': Color(0xFFFAFBFD),
    'BLACK': Color(0xFF1B1F27),
    'RED': Color(0xFFD8453C),
    'GRAY': Color(0xFF98A2B3),
    'GREY': Color(0xFF98A2B3),
    'BRAIDING': Color(0xFFB0B7C3),
    'WATER BLUE': Color(0xFF7FC5E0),
  };

  @override
  Widget build(BuildContext context) {
    final swatch = _swatches[name.toUpperCase()];
    return Row(
      children: [
        if (swatch != null) ...[
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: swatch,
              shape: BoxShape.circle,
              border: Border.all(color: Tone.hairlineStrong),
            ),
          ),
          const SizedBox(width: 6),
        ],
        Expanded(child: Text(name, style: const TextStyle(fontSize: 11, color: Tone.muted))),
      ],
    );
  }
}
