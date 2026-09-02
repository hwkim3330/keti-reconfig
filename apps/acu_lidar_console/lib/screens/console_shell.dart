import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../providers/rig_provider.dart';
import '../widgets/inspector.dart';
import 'pinout_screen.dart';
import 'sheets_screen.dart';
import 'topology_screen.dart';
import 'wiring_screen.dart';

class ConsoleShell extends ConsumerStatefulWidget {
  const ConsoleShell({super.key});

  @override
  ConsumerState<ConsoleShell> createState() => _ConsoleShellState();
}

class _ConsoleShellState extends ConsumerState<ConsoleShell> {
  int _page = 0;

  static const _dests = [
    (icon: Icons.directions_car_filled_outlined, label: 'Vehicle'),
    (icon: Icons.account_tree_outlined, label: 'Wiring'),
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
            _NavRail(index: _page, dests: _dests, onTap: (i) => setState(() => _page = i)),
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
                        WiringScreen(),
                        PinoutScreen(),
                        SheetsScreen(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const _Inspector(),
          ],
        ),
      ),
    );
  }
}

/// The inspector is a drawer, not a column. Held open permanently it spent a quarter of the
/// screen saying "tap something"; now the hero gets that width back until there is something to
/// inspect.
class _Inspector extends ConsumerWidget {
  const _Inspector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(selectedNodeProvider) != null || ref.watch(selectedPortProvider) != null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      width: open ? 336 : 0,
      child: open
          ? const ClipRect(child: OverflowBox(maxWidth: 336, alignment: Alignment.centerLeft, child: InspectorPanel()))
          : const SizedBox.shrink(),
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
      width: 80,
      decoration: const BoxDecoration(
        color: Tone.surface,
        border: Border(right: BorderSide(color: Tone.hairline)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11),
            child: Image.asset('assets/keti_logo.png', height: 24, fit: BoxFit.contain),
          ),
          const SizedBox(height: 18),
          for (var i = 0; i < dests.length; i++)
            _NavItem(
              icon: dests[i].icon,
              label: dests[i].label,
              selected: i == index,
              onTap: () => onTap(i),
            ),
          const Spacer(),
          const _ModeToggle(),
          const SizedBox(height: 12),
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
    // The marker is a bar on the rail's own edge, not a box around the item: the destination
    // stays the same size whether or not it is current, so the column never shifts under a tap.
    return SizedBox(
      height: 62,
      child: Stack(
        children: [
          if (selected)
            Positioned(
              left: 0,
              top: 14,
              bottom: 14,
              child: Container(
                width: 3,
                decoration: const BoxDecoration(
                  color: Tone.accent,
                  borderRadius: BorderRadius.horizontal(right: Radius.circular(3)),
                ),
              ),
            ),
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 21, color: selected ? Tone.accent : Tone.faint),
                    const SizedBox(height: 4),
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
        ],
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
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Tooltip(
        message: sim
            ? 'Scripted rig. Every link state and rate on screen is generated.'
            : 'Reference only. No rig attached, so no link is claimed up or down.',
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => ref.read(rigProvider).setMode(sim ? RigMode.reference : RigMode.simulated),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: sim ? Tone.warn.withValues(alpha: 0.12) : Tone.sunken,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sim ? Tone.warn.withValues(alpha: 0.5) : Tone.hairline),
            ),
            child: Column(
              children: [
                Icon(sim ? Icons.play_circle_outline : Icons.menu_book_outlined,
                    size: 20, color: sim ? Tone.warn : Tone.muted),
                const SizedBox(height: 4),
                Text(sim ? 'DEMO' : 'REF',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
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
    final sim = rig.mode == RigMode.simulated;
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(
        color: Tone.surface,
        border: Border(bottom: BorderSide(color: Tone.hairline)),
      ),
      child: Row(
        children: [
          const Text('ACU / LiDAR', style: Type.display),
          const SizedBox(width: 10),
          Container(width: 1, height: 20, color: Tone.hairline),
          const SizedBox(width: 10),
          Text(page, style: const TextStyle(fontSize: 15, color: Tone.muted, fontWeight: FontWeight.w600)),
          const SizedBox(width: 14),
          const Chip2('2026 · a2z design sheets', color: Tone.faint),
          const Spacer(),
          if (sim) ...[
            SizedBox(
              width: 250,
              child: DropdownButtonFormField<String>(
                initialValue: rig.scenario.id,
                isDense: true,
                borderRadius: BorderRadius.circular(12),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: Tone.sunken,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Tone.hairline),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Tone.hairline),
                  ),
                ),
                style: const TextStyle(fontSize: 12, color: Tone.ink, fontWeight: FontWeight.w600),
                items: [
                  for (final s in scenarios)
                    DropdownMenuItem(value: s.id, child: Text(s.title, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) =>
                    ref.read(rigProvider).setScenario(scenarios.firstWhere((e) => e.id == v)),
              ),
            ),
            const SizedBox(width: 12),
          ],
          StatusPill(
            label: sim ? 'Scripted rig' : 'No rig attached',
            colour: sim ? Tone.warn : Tone.faint,
            emphasis: sim,
          ),
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
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
      decoration: BoxDecoration(
        color: Tone.warn.withValues(alpha: 0.13),
        border: Border(bottom: BorderSide(color: Tone.warn.withValues(alpha: 0.3))),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(color: Tone.warn, borderRadius: BorderRadius.circular(5)),
            child: const Text('SIMULATED',
                style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: 1)),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              '${rig.scenario.detail}  Link states and Mb/s below are generated, not measured.',
              style: const TextStyle(fontSize: 11.5, color: Tone.ink),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
