import 'package:flutter/material.dart';

import '../core/reference.dart';
import '../core/theme.dart';
import '../widgets/sheet_image.dart';

/// The source material, shipped with the app. A harness console that cannot show the drawing it
/// is asserting from sends whoever is on the vehicle back to a laptop.
class SheetsScreen extends StatelessWidget {
  const SheetsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final groups = sheetGroups.entries.toList();
    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (_, i) {
        final g = groups[i];
        return Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(g.key, trailing: '${g.value.length} image(s)'),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, c) {
                  const gap = 12.0;
                  final cols = c.maxWidth > 900 ? 4 : 3;
                  final w = (c.maxWidth - gap * (cols - 1)) / cols;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final s in g.value)
                        SizedBox(
                          width: w,
                          child: SheetImage(
                            asset: s.asset,
                            title: s.title,
                            caption: s.caption,
                            superseded: s.superseded,
                            height: 132,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
