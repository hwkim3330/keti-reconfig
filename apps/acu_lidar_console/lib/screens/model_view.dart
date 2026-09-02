import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/reference.dart';
import '../widgets/vehicle_plan.dart' show heightOf;

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

  /// Which devices get a pin. The cameras are left off: ten of them on one shuttle is a screen
  /// of overlapping tags, and they are named in the port bar and the inspector instead.
  static const _pinned = <String>[
    'hb_front', 'hb_rear', 'fk_front', 'fk_rear', 'lidar_lh', 'lidar_rh',
    'acu_it', 'acu_no', 'display', 'tsn_fa', 'tsn_fb', 'tsn_r',
  ];

  /// Hotspots carry normalised coordinates, not model ones, and the page resolves them against
  /// whatever body is loaded. Hard-coded metres had to be re-probed every time the model changed
  /// and silently put every pin in a heap when they were not; this way the Model view and the 3D
  /// view read the same numbers out of `reference.dart` and cannot drift apart.
  String get _hotspotHtml {
    final b = StringBuffer();
    for (final id in _pinned) {
      final n = nodeById(id);
      if (n == null) continue;
      final cls = switch (n.kind) {
        NodeKind.lidar => 'lidar',
        NodeKind.acu => 'acu',
        NodeKind.tsn => 'tsn',
        _ => 'other',
      };
      final label = n.kind == NodeKind.lidar ? n.name.replaceAll(' · ', ' ') : n.name;
      b.write(
        '<button class="hs $cls" slot="hotspot-$id" data-position="0m 0m 0m" '
        'data-normal="0 1 0" data-nx="${n.pos.dx}" data-ny="${n.pos.dy}" '
        'data-nz="${heightOf(n)}"><i></i><span>$label</span></button>',
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
// Only the shell fades. The body is split into named parts, each with its own material, so the
// floor the boxes stand on and the wheels that give it a stance stay solid while the roof, flanks
// and fascias go to glass. Alpha-blending every material at once made the whole vehicle a ghost,
// which is a different picture and a less useful one.
const __SHELL = ['ROOF', 'SIDE_L', 'SIDE_R', 'FASCIA_FRONT', 'FASCIA_REAR', 'TRIM'];
function __isShell(name) {
  return __SHELL.some(function (s) { return (name || '').indexOf(s) >= 0; });
}
function __applyShell(a) {
  const mv = document.querySelector('model-viewer');
  if (!mv || !mv.model) return;
  for (const m of mv.model.materials) {
    try {
      const p = m.pbrMetallicRoughness;
      if (!m.__base) m.__base = Array.from(p.baseColorFactor);
      const alpha = __isShell(m.name) ? a : 1;
      p.setBaseColorFactor([m.__base[0], m.__base[1], m.__base[2], alpha]);
      m.setAlphaMode(alpha >= 0.995 ? 'OPAQUE' : 'BLEND');
    } catch (e) {}
  }
}
window.setShellOpacity = function (a) { window.__shell = a; __applyShell(a); };

// Resolve the normalised hotspot coordinates against the body actually loaded: x is lateral
// (-1 left .. +1 right), y runs 0 at the front bumper to 1 at the rear, z is height 0..1.
function __centre(mv) {
  // getBoundingBoxCenter is not in every model-viewer build. getCameraTarget returns the same
  // point while cameraTarget is auto, which it is. Without the fallback the whole function threw
  // and every pin stayed at 0 0 0 -- twelve labels stacked on one spot, which looks exactly like
  // one label.
  try {
    if (typeof mv.getBoundingBoxCenter === 'function') return mv.getBoundingBoxCenter();
  } catch (e) {}
  return mv.getCameraTarget();
}
function __placePins() {
  const mv = document.querySelector('model-viewer');
  if (!mv || !mv.model) return;
  const d = mv.getDimensions();
  const c = __centre(mv);
  if (!d || !c) return;
  for (const el of mv.querySelectorAll('.hs')) {
    const nx = parseFloat(el.dataset.nx), ny = parseFloat(el.dataset.ny),
          nz = parseFloat(el.dataset.nz);
    if (isNaN(nx) || isNaN(ny) || isNaN(nz)) continue;
    const x = c.x + nx * d.x / 2;
    const y = (c.y - d.y / 2) + nz * d.y;
    const z = (c.z + d.z / 2) - ny * d.z;
    const pos = x.toFixed(3) + 'm ' + y.toFixed(3) + 'm ' + z.toFixed(3) + 'm';
    el.dataset.position = pos;
    // Setting the attribute alone is not enough: model-viewer reads a hotspot's position when
    // the slot is created and only moves it through updateHotspot. Without this every pin stayed
    // where it was born, which was 0 0 0 -- twelve labels on one spot, indistinguishable from one.
    if (typeof mv.updateHotspot === 'function') {
      mv.updateHotspot({ name: el.slot, position: pos, normal: '0 1 0' });
    }
  }
}
document.addEventListener('DOMContentLoaded', function () {
  const mv = document.querySelector('model-viewer');
  if (!mv) return;
  mv.addEventListener('load', function () {
    __applyShell(window.__shell);
    __placePins();
    // The bounds settle a frame or two after load on some builds; a second pass is cheap.
    setTimeout(__placePins, 250);
    setTimeout(__placePins, 1200);
  });
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
      src: 'assets/roii_body_clean.glb',
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
