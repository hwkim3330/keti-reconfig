// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/fault_provider.dart';

class ControlBar extends ConsumerWidget {
  const ControlBar({
    this.showHotspot = false,
    this.onToggleHotspot,
    this.onToggleMaterial,
    this.onSwitchOrbit,
    this.onSimulateFault,
    super.key,
  });

  final bool showHotspot;
  final VoidCallback? onToggleHotspot;
  final VoidCallback? onToggleMaterial;
  final VoidCallback? onSwitchOrbit;
  final VoidCallback? onSimulateFault;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xff252a33).withOpacity(0.95),
            const Color(0xff1e2229).withOpacity(0.85),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xff3a3f48), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ControlItem(
            icon: Icons.visibility_rounded,
            label: showHotspot ? 'Hide' : 'Label',
            active: showHotspot,
            onTap: onToggleHotspot,
          ),
          _ControlItem(
            icon: Icons.flip_camera_android_rounded,
            label: 'Side/Aero',
            onTap: onToggleMaterial,
          ),
          _ControlItem(
            icon: Icons.swap_horiz_rounded,
            label: 'Orbit',
            onTap: onSwitchOrbit,
          ),
          _ControlItem(
            icon: Icons.bug_report_rounded,
            label: 'Sim',
            onTap: onSimulateFault,
          ),
          _ControlItem(
            icon: Icons.clear_all_rounded,
            label: 'Clear',
            onTap: () {
              ref.read(faultProvider.notifier).clearAll();
            },
          ),
        ],
      ),
    );
  }
}

class _ControlItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  const _ControlItem({
    required this.icon,
    required this.label,
    this.active = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: active ? const Color(0xff4a90d9).withOpacity(0.15) : null,
          borderRadius: BorderRadius.circular(12),
          border: active
              ? Border.all(color: const Color(0xff4a90d9).withOpacity(0.4))
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 24,
              color: active ? const Color(0xff4a90d9) : Colors.grey.shade400,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: active ? const Color(0xff4a90d9) : Colors.grey.shade500,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
