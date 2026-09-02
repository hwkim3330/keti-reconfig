import 'package:flutter/material.dart';

import '../core/reference.dart';
import '../core/theme.dart';
import '../widgets/sheet_image.dart';

class PinoutScreen extends StatelessWidget {
  const PinoutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(14),
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
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: _Table(rows: pinout.rows)),
              if (pinout.refImage != null) ...[
                const SizedBox(width: 14),
                SizedBox(
                  width: 260,
                  child: SheetImage(
                    asset: pinout.refImage!,
                    title: 'Source drawing',
                    caption: 'Tap to zoom',
                    height: 168,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: const Color(0xFFF6F8FB),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: Tone.line),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.push_pin_outlined, size: 15, color: Tone.muted),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(pinout.note,
                      style: const TextStyle(fontSize: 11.5, color: Tone.text, height: 1.5)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Table extends StatelessWidget {
  final List<PinRow> rows;

  const _Table({required this.rows});

  static const _head = TextStyle(
      fontSize: 10, fontWeight: FontWeight.w800, color: Tone.muted, letterSpacing: 0.6);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: const [
              SizedBox(width: 92, child: Text('CAV', style: _head)),
              Expanded(flex: 4, child: Text('CSA / PART', style: _head)),
              SizedBox(width: 86, child: Text('COLOUR', style: _head)),
              Expanded(flex: 4, child: Text('SIGNAL', style: _head)),
              Expanded(flex: 4, child: Text('COMMENT', style: _head)),
            ],
          ),
        ),
        for (final r in rows)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Tone.line)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 92,
                  child: Text(r.cav,
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800)),
                ),
                Expanded(
                    flex: 4,
                    child: Text(r.csa,
                        style: const TextStyle(fontSize: 11, color: Tone.muted, height: 1.35))),
                SizedBox(
                  width: 86,
                  child: Row(
                    children: [
                      if (_swatch(r.colour) != null) ...[
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: _swatch(r.colour),
                            shape: BoxShape.circle,
                            border: Border.all(color: Tone.line),
                          ),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Expanded(
                        child: Text(r.colour,
                            style: const TextStyle(fontSize: 11, color: Tone.muted)),
                      ),
                    ],
                  ),
                ),
                Expanded(
                    flex: 4,
                    child: Text(r.signal,
                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600))),
                Expanded(
                    flex: 4,
                    child: Text(r.comment,
                        style: const TextStyle(fontSize: 11, color: Tone.faint, height: 1.35))),
              ],
            ),
          ),
      ],
    );
  }

  /// Wire colours are the thing a crimper actually goes by, so they are shown as colour and
  /// not only as a word.
  Color? _swatch(String name) => switch (name.toUpperCase()) {
        'GREEN' => const Color(0xFF2FAE60),
        'WHITE' => const Color(0xFFF3F5F8),
        'BLACK' => const Color(0xFF1B1F27),
        'RED' => const Color(0xFFD8453C),
        'GRAY' || 'GREY' => const Color(0xFF98A2B3),
        'BRAIDING' => const Color(0xFFB0B7C3),
        'WATER BLUE' => const Color(0xFF7FC5E0),
        _ => null,
      };
}
