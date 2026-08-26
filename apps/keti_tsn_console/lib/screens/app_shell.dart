import 'package:flutter/material.dart';

import 'car_viewer_screen.dart';
import 'scenarios_screen.dart';
import 'settings_screen.dart';
import 'switch_console_screen.dart';
import 'traffic_gen_screen.dart';

/// Tab shell for the console. A left NavigationRail (landscape tablet) hosts the
/// feature tabs; the screens are kept alive in an IndexedStack so BLE links and
/// live graphs don't tear down when you switch tabs.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;

  static const _dests = <(IconData, String)>[
    (Icons.hub_outlined, 'Reconfig'),
    (Icons.speed_outlined, 'Traffic'),
    (Icons.science_outlined, 'Scenarios'),
    (Icons.view_in_ar_outlined, 'Topology'),
    (Icons.settings_outlined, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F4F7),
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              labelType: NavigationRailLabelType.all,
              backgroundColor: Colors.white,
              indicatorColor: const Color(0xFFEDF2FD),
              selectedIconTheme: const IconThemeData(color: Color(0xFF2563EB)),
              selectedLabelTextStyle: const TextStyle(
                  color: Color(0xFF2563EB), fontWeight: FontWeight.w700, fontSize: 11),
              unselectedLabelTextStyle:
                  const TextStyle(color: Color(0xFF9AA3B2), fontSize: 11),
              leading: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Icon(Icons.lan_outlined, color: Color(0xFF2563EB)),
              ),
              destinations: [
                for (final d in _dests)
                  NavigationRailDestination(
                    icon: Icon(d.$1),
                    label: Text(d.$2),
                  ),
              ],
            ),
            const VerticalDivider(width: 1, color: Color(0xFFE2E6EE)),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: const [
                  SwitchConsoleScreen(),
                  TrafficGenScreen(),
                  ScenariosScreen(),
                  CarViewerScreen(),
                  SettingsScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
