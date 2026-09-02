import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import '../core/reference.dart';
import '../core/theme.dart';

/// The glTF body from the KETI reconfig console, with the ACU / LiDAR devices pinned onto it.
///
/// This is the shuttle shell the reconfig demo uses, not the a2z vehicle the design sheets are
/// drawn for -- so it is labelled as a stand-in. It is here because a solid body reads at a
/// glance where a wireframe box does not; the positions that matter (which port, which cavity)
/// come from the sheets and live on the other tabs.
class ModelVehicleView extends StatelessWidget {
  final String? selectedNodeId;
  final ValueChanged<String?> onSelect;

  const ModelVehicleView({super.key, required this.selectedNodeId, required this.onSelect});

  /// Hotspot anchors in the glTF's own coordinate space. Read off the model rather than guessed:
  /// its bounding box measures 22.1 x 21.7 x 40.0 about a centre of (-1.94, 11.28, -0.08), so
  /// ground is y ~ 0.4, the roof y ~ 22, the front bumper z ~ +20 and the rear z ~ -20. The first
  /// pass used the reconfig console's numbers and put every pin in a heap at mid-body, because
  /// those were tuned against the other variant of this model.
  static const _anchors = <String, String>{
    'hb_front': '0m 4.5m 19m',
    'hb_rear': '0m 4.5m -19m',
    'fk_front': '0m 20.5m 8m',
    'fk_rear': '0m 20.5m -8m',
    'lidar_lh': '-8.8m 19m 0m',
    'lidar_rh': '8.8m 19m 0m',
    'acu_it': '3.5m 3m -14m',
    'acu_no': '-3.5m 3m -14m',
    'display': '0m 12m 14m',
  };

  String get _hotspotHtml {
    final b = StringBuffer();
    for (final e in _anchors.entries) {
      final n = nodeById(e.key);
      if (n == null) continue;
      final cls = switch (n.kind) {
        NodeKind.lidar => 'lidar',
        NodeKind.acu => 'acu',
        _ => 'other',
      };
      final label = n.kind == NodeKind.lidar ? n.name.replaceAll(' · ', ' ') : n.name;
      b.write(
        '<button class="hs $cls" slot="hotspot-${e.key}" data-position="${e.value}" '
        'data-normal="0 1 0"><i></i><span>$label</span></button>',
      );
    }
    return b.toString();
  }

  static const _css = '''
.hs {
  display: flex; align-items: center; gap: 6px;
  background: rgba(255,255,255,0.94);
  border: 1px solid #D9DFE9;
  border-radius: 999px;
  padding: 4px 10px 4px 6px;
  font: 600 11px/1.2 -apple-system, Roboto, sans-serif;
  color: #16202E;
  box-shadow: 0 1px 4px rgba(20,30,50,.14);
  white-space: nowrap;
  transform: translate(-50%, -50%);
}
.hs i { width: 8px; height: 8px; border-radius: 50%; display: block; }
.hs.lidar i { background: #18B6D6; }
.hs.acu i { background: #7A6BF0; }
.hs.other i { background: #EF8A2B; }
.hs[data-visible="false"] { opacity: 0.25; }
''';

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ModelViewer(
          key: const ValueKey('acu_lidar_model'),
          backgroundColor: const Color(0xFFF7F9FC),
          id: 'vehicle',
          src: 'assets/roii_reconfig.glb',
          alt: 'Shuttle body with the ACU and LiDAR positions pinned on',
          cameraControls: true,
          autoRotate: false,
          disablePan: true,
          disableTap: true,
          cameraOrbit: '40deg 68deg 105%',
          cameraTarget: 'auto auto auto',
          innerModelViewerHtml: _hotspotHtml,
          relatedCss: _css,
        ),
        Positioned(
          left: 10,
          bottom: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Tone.line),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, size: 13, color: Tone.muted),
                SizedBox(width: 6),
                Text(
                  'ROii shuttle body, used as a stand-in — the sheets do not include a vehicle model.',
                  style: TextStyle(fontSize: 10.5, color: Tone.muted),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
