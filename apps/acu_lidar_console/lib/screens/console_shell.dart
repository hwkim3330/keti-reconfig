import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../providers/rig_provider.dart';
import '../widgets/inspector.dart';
import 'acu_screen.dart';
import 'pinout_screen.dart';
import 'sheets_screen.dart';
import 'topology_screen.dart';

class ConsoleShell extends ConsumerStatefulWidget {
  const ConsoleShell({super.key});

  @override
  ConsumerState<ConsoleShell> createState() => _ConsoleShellState();
}

class _ConsoleShellState extends ConsumerState<ConsoleShell> {
  int _page = 0;

  static const _dests = [
    (icon: Icons.directions_car_filled_outlined, label: 'Vehicle'),
    (icon: Icons.settings_input_component_outlined, label: 'ACU'),
    (icon: Icons.table_rows_outlined, label: 'Pinouts'),
    (icon: Icons.photo_library_outlined, label: 'Sheets'),
  ];

  @override
  Widget build(BuildContext context) {
    final rig = ref.watch(rigProvider);
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            _NavRail(
              index: _page,
              dests: _dests,
              onTap: (i) => setState(() => _page = i),
            ),
            Expanded(
              child: Column(
                children: [
                  _TopBar(page: _dests[_page].label),
                  if (rig.mode == RigMode.simulated) const _SimulatedStamp(),
                  Expanded(
                    child: IndexedStack(
                      index: _page,
                      children: const [
                        TopologyScreen(),
                        AcuScreen(),
                        PinoutScreen(),
                        SheetsScreen(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const InspectorPanel(),
          ],
        ),
      ),
    );
  }
}

class _NavRail extends StatelessWidget {
  final int index;
  final List<({IconData icon, String label})> dests;
  final ValueChanged<int> onTap;

  const _NavRail({required this.index, required this.dests, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 78,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Tone.line)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Image.asset('assets/keti_logo.png', height: 26, fit: BoxFit.contain),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < dests.length; i++)
            _NavItem(
              icon: dests[i].icon,
              label: dests[i].label,
              selected: i == index,
              onTap: () => onTap(i),
            ),
          const Spacer(),
          const _ModeToggle(),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Material(
        color: selected ? Tone.accent.withValues(alpha: 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Column(
              children: [
                Icon(icon, size: 21, color: selected ? Tone.accent : Tone.muted),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? Tone.accent : Tone.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeToggle extends ConsumerWidget {
  const _ModeToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    final sim = rig.mode == RigMode.simulated;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Tooltip(
        message: sim
            ? 'Scripted rig. Every link state and rate on screen is generated.'
            : 'Reference only. No rig attached, so no link is claimed up or down.',
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => ref
              .read(rigProvider)
              .setMode(sim ? RigMode.reference : RigMode.simulated),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: sim ? Tone.warn.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sim ? Tone.warn.withValues(alpha: 0.5) : Tone.line),
            ),
            child: Column(
              children: [
                Icon(sim ? Icons.play_circle_outline : Icons.menu_book_outlined,
                    size: 20, color: sim ? Tone.warn : Tone.muted),
                const SizedBox(height: 3),
                Text(sim ? 'DEMO' : 'REF',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: sim ? Tone.warn : Tone.muted)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  final String page;

  const _TopBar({required this.page});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Tone.line)),
      ),
      child: Row(
        children: [
          const Text('ACU / LiDAR',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
          const SizedBox(width: 8),
          Text('· $page', style: const TextStyle(fontSize: 15, color: Tone.muted)),
          const SizedBox(width: 14),
          const Chip2('2026 · a2z design sheets', color: Tone.faint),
          const Spacer(),
          if (rig.mode == RigMode.simulated) ...[
            const Text('Scenario', style: TextStyle(fontSize: 11, color: Tone.muted)),
            const SizedBox(width: 8),
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String>(
                initialValue: rig.scenario.id,
                isDense: true,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontSize: 12, color: Tone.text),
                items: [
                  for (final s in scenarios)
                    DropdownMenuItem(value: s.id, child: Text(s.title, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) {
                  final s = scenarios.firstWhere((e) => e.id == v);
                  ref.read(rigProvider).setScenario(s);
                },
              ),
            ),
          ] else
            const Text('Reference mode · no rig attached',
                style: TextStyle(fontSize: 12, color: Tone.faint)),
        ],
      ),
    );
  }
}

class _SimulatedStamp extends ConsumerWidget {
  const _SimulatedStamp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    return Container(
      width: double.infinity,
      color: Tone.warn.withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 15, color: Tone.warn),
          const SizedBox(width: 7),
          const Text('SIMULATED',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Tone.warn, letterSpacing: 0.8)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${rig.scenario.detail}  Link states and Mb/s below are generated, not measured.',
              style: const TextStyle(fontSize: 11, color: Tone.text),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
