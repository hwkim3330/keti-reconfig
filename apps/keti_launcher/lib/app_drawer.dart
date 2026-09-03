import 'package:flutter/material.dart';

import 'host.dart';
import 'theme.dart';

/// The app drawer.
///
/// This app is the tablet's HOME, so it owns the only way to reach anything else on the device.
/// The list is loaded the first time the sheet opens, not at startup: enumerating and rendering
/// icons for every installed package costs about a second on this hardware, and it is a second
/// spent before the path modules are on screen if it happens at launch.
class AppDrawerSheet extends StatefulWidget {
  const AppDrawerSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet(
        context: context,
        backgroundColor: K.surface,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (_) => const AppDrawerSheet(),
      );

  @override
  State<AppDrawerSheet> createState() => _AppDrawerSheetState();
}

class _AppDrawerSheetState extends State<AppDrawerSheet> {
  List<InstalledApp>? _apps;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    Host.listApps().then((a) {
      if (mounted) setState(() => _apps = a);
    });
  }

  @override
  Widget build(BuildContext context) {
    final apps = _apps;
    final shown = apps == null
        ? const <InstalledApp>[]
        : apps
            .where((a) =>
                _filter.isEmpty ||
                a.label.toLowerCase().contains(_filter.toLowerCase()))
            .toList();

    return FractionallySizedBox(
      heightFactor: 0.86,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: K.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 42,
                    child: TextField(
                      style: const TextStyle(fontSize: 14, color: K.text),
                      cursorColor: K.ok,
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: K.surfaceHi,
                        hintText: '앱 검색',
                        hintStyle: const TextStyle(color: K.dim, fontSize: 14),
                        prefixIcon: const Icon(Icons.search, size: 18, color: K.dim),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (v) => setState(() => _filter = v),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _chip(Icons.settings, '설정', () => Host.openSettings()),
              ],
            ),
          ),
          Expanded(
            child: apps == null
                ? const Center(
                    child: Text('앱 목록 읽는 중…',
                        style: TextStyle(color: K.dim, fontSize: 13)))
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    // Fixed extent rather than a cross-axis count so the same grid works on the
                    // 7" panel in either orientation without a second layout.
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 104,
                      childAspectRatio: 0.82,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (context, i) => _AppTile(app: shown[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) => Material(
        color: K.surfaceHi,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(children: [
              Icon(icon, size: 16, color: K.muted),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(fontSize: 13, color: K.muted)),
            ]),
          ),
        ),
      );
}

class _AppTile extends StatelessWidget {
  const _AppTile({required this.app});
  final InstalledApp app;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        Host.launch(app.package);
        Navigator.of(context).maybePop();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: app.icon.isEmpty
                  ? const Icon(Icons.android, color: K.dim, size: 30)
                  : Image.memory(app.icon, gaplessPlayback: true, filterQuality: FilterQuality.low),
            ),
            const SizedBox(height: 6),
            Text(
              app.label,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, height: 1.2, color: K.muted),
            ),
          ],
        ),
      ),
    );
  }
}
