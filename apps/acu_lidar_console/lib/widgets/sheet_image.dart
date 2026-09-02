import 'package:flutter/material.dart';

import '../core/theme.dart';

/// A reference image with a caption, opening full-screen and zoomable on tap.
///
/// These are photographs and CAD crops of a real harness; a thumbnail is enough to recognise
/// which drawing is meant, and never enough to read a part number off. So every one of them is
/// tappable, and the full-screen view pans and zooms.
class SheetImage extends StatelessWidget {
  final String asset;
  final String title;
  final String? caption;
  final double height;
  final bool superseded;

  const SheetImage({
    super.key,
    required this.asset,
    required this.title,
    this.caption,
    this.height = 150,
    this.superseded = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => Navigator.of(context).push(
        PageRouteBuilder(
          opaque: false,
          pageBuilder: (_, __, ___) => _Viewer(asset: asset, title: title, caption: caption),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: height,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFFF6F8FB),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: superseded ? Tone.warn.withValues(alpha: 0.6) : Tone.line),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(asset, fit: BoxFit.contain),
                if (superseded)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Chip2('SUPERSEDED', color: Tone.warn, solid: true),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          if (caption != null) ...[
            const SizedBox(height: 2),
            Text(caption!,
                style: const TextStyle(fontSize: 10.5, color: Tone.muted, height: 1.35)),
          ],
        ],
      ),
    );
  }
}

class _Viewer extends StatelessWidget {
  final String asset;
  final String title;
  final String? caption;

  const _Viewer({required this.asset, required this.title, this.caption});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.92),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
                        if (caption != null)
                          Text(caption!,
                              style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 6,
                child: Center(child: Image.asset(asset, fit: BoxFit.contain)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
