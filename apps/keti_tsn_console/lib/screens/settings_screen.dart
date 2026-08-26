import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/traffic_gen_provider.dart';

/// Settings — transport (BLE vs Wi-Fi), reconnect, and the fixed demo topology
/// for reference. BLE is the intended control path (wireless = control-plane
/// only); Wi-Fi is a fallback for bench work.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = ref.watch(trafficGenProvider);
    final notifier = ref.read(trafficGenProvider.notifier);

    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Settings',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF1F2937))),
          const SizedBox(height: 16),
          _Card(
            title: 'Control transport',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<TgTransport>(
                  segments: const [
                    ButtonSegment(value: TgTransport.ble, label: Text('BLE'), icon: Icon(Icons.bluetooth)),
                    ButtonSegment(value: TgTransport.wifi, label: Text('Wi-Fi'), icon: Icon(Icons.wifi)),
                  ],
                  selected: {tg.transport},
                  onSelectionChanged: (s) => notifier.setTransport(s.first),
                ),
                const SizedBox(height: 8),
                Text(
                  tg.transport == TgTransport.ble
                      ? 'Scans for KETI-TRAFGEN-TX (Pi1). Pi1 relays to the two D10 switches.'
                      : 'HTTP to the sender Pi on :8080 — bench fallback.',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF9AA3B2)),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  _pill(_linkLabel(tg.link), tg.link == TgLink.online),
                  const SizedBox(width: 10),
                  TextButton(onPressed: notifier.connect, child: const Text('Reconnect')),
                ]),
              ],
            ),
          ),
          _Card(
            title: 'Demo topology',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                _Line('Video Pi', '192.168.77.10  ·  HD stream'),
                _Line('Sender Pi', '192.168.77.11  ·  flood + D10 controller  ·  KETI-TRAFGEN-TX'),
                _Line('Receiver Pi', '192.168.77.12  ·  kiosk  ·  KETI-TRAFGEN-RX'),
                _Line('D10 switch 1', '192.168.100.2  ·  generation'),
                _Line('D10 switch 2', '192.168.100.4  ·  recovery'),
              ],
            ),
          ),
          const Spacer(),
          const Text('KETI TSN Console · Kontron KSwitch D10 (WebStaX)',
              style: TextStyle(fontSize: 11, color: Color(0xFFB0B7C3))),
        ],
      ),
    );
  }

  static String _linkLabel(TgLink l) => switch (l) {
        TgLink.online => 'online',
        TgLink.connecting => 'connecting',
        TgLink.offline => 'offline',
      };

  Widget _pill(String text, bool up) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: up ? const Color(0xFFE7F6EE) : const Color(0xFFF0F1F4),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: up ? const Color(0xFF0F766E) : const Color(0xFF9AA3B2))),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE2E6EE)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
            const SizedBox(height: 10),
            child,
          ],
        ),
      );
}

class _Line extends StatelessWidget {
  const _Line(this.name, this.detail);
  final String name;
  final String detail;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          SizedBox(
              width: 110,
              child: Text(name,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151)))),
          Expanded(
              child: Text(detail,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280), fontFamily: 'monospace'))),
        ]),
      );
}
