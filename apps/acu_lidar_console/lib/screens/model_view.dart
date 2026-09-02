import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/reference.dart';

/// The glTF body from the KETI reconfig console, with the ACU / LiDAR devices and the three TSN
/// switches pinned onto it.
///
/// This is the shuttle shell the reconfig demo uses, not the a2z vehicle the design sheets are
/// drawn for -- so it is labelled as a stand-in. The body is held translucent because the boxes
/// that matter here are inside it: opaque, model-viewer marks the interior hotspots occluded and
/// fades them out, which is the opposite of what the view exists for.
class ModelVehicleView extends StatefulWidget {
  final String? selectedNodeId;
  final ValueChanged<String?> onSelect;

  /// 0..1, applied to every material in the glTF.
  final double shellOpacity;

  const ModelVehicleView({
    super.key,
    required this.selectedNodeId,
    required this.onSelect,
    this.shellOpacity = 0.42,
  });

  @override
  State<ModelVehicleView> createState() => _ModelVehicleViewState();
}

class _ModelVehicleViewState extends State<ModelVehicleView>
    with AutomaticKeepAliveClientMixin {
  WebViewController? _web;

  /// The WebView costs about a second of blank frame to create. Switching away from this view
  /// and back must not pay that again, so the state is kept alive and the page it sits on keeps
  /// all three renderings in an IndexedStack.
  @override
  bool get wantKeepAlive => true;

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
    // The KETI backbone: the front pair either side of the forward compartment, and the third
    // switch pulled forward off the rear bulkhead to sit near the middle of the vehicle.
    'tsn_fa': '5m 4m 11m',
    'tsn_fb': '-5m 4m 11m',
    'tsn_r': '0m 4m -1m',
  };

  String get _hotspotHtml {
    final b = StringBuffer();
    for (final e in _anchors.entries) {
      final n = nodeById(e.key);
      if (n == null) continue;
      final cls = switch (n.kind) {
        NodeKind.lidar => 'lidar',
        NodeKind.acu => 'acu',
        NodeKind.tsn => 'tsn',
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
  border: 1px solid #DCE2EC;
  border-radius: 8px;
  padding: 4px 10px 4px 6px;
  font: 700 11px/1.2 -apple-system, Roboto, sans-serif;
  color: #101826;
  box-shadow: 0 1px 5px rgba(16,24,38,.16);
  white-space: nowrap;
  transform: translate(-50%, -50%);
}
.hs i { width: 8px; height: 8px; border-radius: 50%; display: block; }
.hs.lidar i { background: #0EA5C4; }
.hs.acu i { background: #7A64EC; }
.hs.tsn i { background: #BE3F97; }
.hs.other i { background: #E07C1B; }
/* Behind the body, not hidden by it: the shell is translucent on purpose. */
.hs[data-visible="false"] { opacity: 0.6; }
''';

  /// Transparency has to be a material edit, not a CSS one -- the body must actually blend for
  /// the boxes behind it to show through. Base colour factors are saved on first use so the
  /// control can go back to fully opaque without reloading the model.
  static const _js = '''
window.__shell = 0.42;
function __applyShell(a) {
  const mv = document.querySelector('model-viewer');
  if (!mv || !mv.model) return;
  for (const m of mv.model.materials) {
    try {
      const p = m.pbrMetallicRoughness;
      if (!m.__base) m.__base = Array.from(p.baseColorFactor);
      p.setBaseColorFactor([m.__base[0], m.__base[1], m.__base[2], a]);
      m.setAlphaMode(a >= 0.995 ? 'OPAQUE' : 'BLEND');
    } catch (e) {}
  }
}
window.setShellOpacity = function (a) { window.__shell = a; __applyShell(a); };
document.addEventListener('DOMContentLoaded', function () {
  const mv = document.querySelector('model-viewer');
  if (!mv) return;
  mv.addEventListener('load', function () { __applyShell(window.__shell); });
});
''';

  @override
  void didUpdateWidget(ModelVehicleView old) {
    super.didUpdateWidget(old);
    if (old.shellOpacity != widget.shellOpacity) _push();
  }

  void _push() =>
      _web?.runJavaScript('window.setShellOpacity(${widget.shellOpacity.toStringAsFixed(3)})');

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ModelViewer(
      key: const ValueKey('acu_lidar_model'),
      backgroundColor: const Color(0xFFF6F8FC),
      id: 'vehicle',
      src: 'assets/roii_reconfig.glb',
      alt: 'Shuttle body with the ACU, LiDAR and TSN switch positions pinned on',
      cameraControls: true,
      // Nothing on this view moves on its own. A console that drifts its camera or waves a
      // prompt hand while it is idle reads as a screensaver, and it makes the same photograph
      // of the rig impossible to take twice.
      autoRotate: false,
      autoPlay: false,
      interactionPrompt: InteractionPrompt.none,
      disablePan: true,
      disableTap: true,
      cameraOrbit: '40deg 68deg 105%',
      cameraTarget: 'auto auto auto',
      innerModelViewerHtml: _hotspotHtml,
      relatedCss: _css,
      relatedJs: _js,
      onWebViewCreated: (c) {
        _web = c;
        _push();
      },
    );
  }
}
