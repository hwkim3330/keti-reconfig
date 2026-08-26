import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/traffic_gen_provider.dart';

/// Scenario Lab — TSN test cases, like the PacketLabManager TC_* library but
/// driven over BLE. Each case is a short sequence of control commands relayed
/// by Pi1 to the two D10 switches (and the flood). Grouped by the feature under
/// test: FRER (seamless redundancy), CBS (bandwidth reservation), TAS (gates),
/// and combinations — the interesting cases are where they interact.
class ScenariosScreen extends ConsumerWidget {
  const ScenariosScreen({super.key});

  static const _groups = <_Group>[
    _Group('FRER · 802.1CB seamless redundancy', [
      _Case('Baseline — both ring links up', 'Video replicated over Gi1/4 + Gi1/6, duplicates eliminated at SW2.',
          ['restore:1', 'restore:2', 'frer:on']),
      _Case('Cut ring link 1', 'Pull Gi1/4. FRER keeps the video from the surviving Gi1/6 — zero drop.',
          ['cut:1']),
      _Case('Cut ring link 2', 'Pull Gi1/6 instead. Same seamless recovery over Gi1/4.',
          ['cut:2']),
      _Case('Restore all links', 'Both ring links back up.', ['restore:1', 'restore:2']),
    ]),
    _Group('CBS · 802.1Qav bandwidth reservation', [
      _Case('No protection (degrade)', 'Flood on, CBS off — the video shares best-effort and stutters.',
          ['cbs:off', 'start']),
      _Case('Protect video (250 Mbps)', 'Reserve the video queue; the 1 G flood can no longer starve it.',
          ['cbs:mbps:250', 'cbs:on', 'start']),
      _Case('Below idle-slope', 'Reserve less than the stream needs — shows the credit running out.',
          ['cbs:mbps:100', 'cbs:on', 'start']),
      _Case('Stop flood', 'Return to quiet.', ['stop']),
    ]),
    _Group('TAS · 802.1Qbv time-aware gates', [
      _Case('Gate schedule 1 ms', 'Open the video queue on a 1 ms cycle.', ['tas:cycle:1000', 'tas:on']),
      _Case('Fast cycle 250 µs', 'Tighter gating.', ['tas:cycle:250', 'tas:on']),
      _Case('Gates off', 'Disable TAS.', ['tas:off']),
    ]),
    _Group('Combined', [
      _Case('CBS + TAS', 'Reserve and gate the video class together.',
          ['cbs:mbps:250', 'cbs:on', 'tas:cycle:1000', 'tas:on', 'start']),
      _Case('FRER + CBS under flood', 'Redundant path AND protected bandwidth, with the flood running.',
          ['frer:on', 'cbs:mbps:250', 'cbs:on', 'start']),
      _Case('Reset all', 'Flood off, shapers off, links restored.',
          ['stop', 'cbs:off', 'tas:off', 'restore:1', 'restore:2']),
    ]),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Scenario Lab',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF1F2937))),
          const SizedBox(height: 2),
          const Text('TSN test cases, run over BLE via Pi1 → the two D10 switches.',
              style: TextStyle(fontSize: 12, color: Color(0xFF9AA3B2))),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(
              children: [
                for (final g in _groups) _GroupCard(group: g, ref: ref),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Group {
  const _Group(this.title, this.cases);
  final String title;
  final List<_Case> cases;
}

class _Case {
  const _Case(this.title, this.detail, this.commands);
  final String title;
  final String detail;
  final List<String> commands;
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.ref});
  final _Group group;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E6EE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(group.title,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
          ),
          for (final c in group.cases) _CaseRow(c: c, ref: ref),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _CaseRow extends StatelessWidget {
  const _CaseRow({required this.c, required this.ref});
  final _Case c;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.title,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF1F2937))),
                const SizedBox(height: 1),
                Text(c.detail, style: const TextStyle(fontSize: 11, color: Color(0xFF9AA3B2))),
                const SizedBox(height: 2),
                Text(c.commands.join('  ›  '),
                    style: const TextStyle(
                        fontSize: 10, color: Color(0xFFB0B7C3), fontFamily: 'monospace')),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _RunButton(commands: c.commands, ref: ref),
        ],
      ),
    );
  }
}

class _RunButton extends StatelessWidget {
  const _RunButton({required this.commands, required this.ref});
  final List<String> commands;
  final WidgetRef ref;

  Future<void> _run() async {
    final tg = ref.read(trafficGenProvider.notifier);
    for (final cmd in commands) {
      await tg.sendControl(cmd);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _run,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF2563EB),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text('Run',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
      ),
    );
  }
}
