// ignore_for_file: deprecated_member_use

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/traffic_gen_provider.dart';
import '../services/traffic_gen_ble.dart';
import '../services/traffic_gen_service.dart';

/// Traffic generator console. Drives pi-trafgen on the Pi over WiFi and plots the
/// live TX rate. This is a separate node from the BLE switches - it does not share
/// the [KetiLinkService] transport.
///
/// The palette matches the reconfig console's glass panels: dark surfaces, one blue
/// accent for throughput and one orange for packet rate, so the two consoles read as
/// one product.
class TrafficGenScreen extends ConsumerWidget {
  const TrafficGenScreen({super.key});

  static const _bg = Color(0xFF14171C);
  static const _panel = Color(0xFF1E2229);
  static const _panelHi = Color(0xFF252A33);
  static const _line = Color(0xFF3A3F48);
  static const _ink = Color(0xFFF2F4F7);
  static const _ink2 = Color(0xFF9AA3B2);
  static const _ink3 = Color(0xFF6B7482);
  static const _blue = Color(0xFF4A90D9);
  static const _orange = Color(0xFFE07B4C);
  static const _green = Color(0xFF35B27E);
  static const _red = Color(0xFFE06767);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(trafficGenProvider);
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(state: state),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // left: gauges + live chart
                    Expanded(
                      flex: 3,
                      child: Column(
                        children: [
                          _Gauges(state: state),
                          const SizedBox(height: 12),
                          Expanded(child: _ChartPanel(state: state)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    // right: controls + stream editor
                    Expanded(
                      flex: 2,
                      child: Column(
                        children: [
                          _ControlPanel(state: state),
                          const SizedBox(height: 12),
                          Expanded(child: _StreamEditor(state: state)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// shared bits
// ---------------------------------------------------------------------------
class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(12)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: TrafficGenScreen._panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TrafficGenScreen._line, width: 1),
      ),
      child: child,
    );
  }
}

String _compact(num n) {
  if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(2)}M';
  if (n >= 1e3) return '${(n / 1e3).toStringAsFixed(1)}k';
  return n.toStringAsFixed(0);
}

// ---------------------------------------------------------------------------
// top bar
// ---------------------------------------------------------------------------
class _TopBar extends ConsumerWidget {
  const _TopBar({required this.state});
  final TrafficGenState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = state.status;
    final el = st.elapsed.floor();
    final clock =
        '${(el ~/ 60).toString().padLeft(2, '0')}:${(el % 60).toString().padLeft(2, '0')}';

    Color linkColor;
    String linkText;
    switch (state.link) {
      case TgLink.online:
        linkColor = TrafficGenScreen._green;
        linkText = 'online';
        break;
      case TgLink.connecting:
        linkColor = TrafficGenScreen._orange;
        linkText = 'connecting';
        break;
      case TgLink.offline:
        linkColor = TrafficGenScreen._red;
        linkText = 'offline';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        color: TrafficGenScreen._panelHi,
        border: Border(bottom: BorderSide(color: TrafficGenScreen._line)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: TrafficGenScreen._ink),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const Text('Traffic Generator',
              style: TextStyle(
                  color: TrafficGenScreen._ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2)),
          const SizedBox(width: 14),
          _pill(st.iface.isEmpty ? '—' : st.iface, TrafficGenScreen._ink2),
          const SizedBox(width: 6),
          _pill(st.linkMbps != null ? '${st.linkMbps} Mbps' : 'no link',
              st.operstate == 'up' ? TrafficGenScreen._green : TrafficGenScreen._red),
          const SizedBox(width: 6),
          _pill(linkText, linkColor),
          const Spacer(),
          _TransportToggle(transport: state.transport),
          const SizedBox(width: 10),
          if (!state.isBle) const _HostButton(),
          if (!state.isBle) const SizedBox(width: 10),
          Icon(Icons.timer_outlined,
              size: 16,
              color: st.running ? TrafficGenScreen._green : TrafficGenScreen._ink3),
          const SizedBox(width: 4),
          Text(clock,
              style: TextStyle(
                  color: st.running ? TrafficGenScreen._ink : TrafficGenScreen._ink3,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Text(text,
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

/// WiFi / BLE segmented control. BLE start/stop needs no network - it matches
/// the reconfig demo's Bluetooth-central model.
class _TransportToggle extends ConsumerWidget {
  const _TransportToggle({required this.transport});
  final TgTransport transport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(trafficGenProvider.notifier);
    Widget seg(TgTransport t, IconData icon, String label) {
      final on = t == transport;
      return GestureDetector(
        onTap: () => n.setTransport(t),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: on ? TrafficGenScreen._blue : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: on ? Colors.white : TrafficGenScreen._ink3),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    color: on ? Colors.white : TrafficGenScreen._ink3,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ]),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: TrafficGenScreen._bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TrafficGenScreen._line),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg(TgTransport.wifi, Icons.wifi_rounded, 'WiFi'),
        seg(TgTransport.ble, Icons.bluetooth_rounded, 'BLE'),
      ]),
    );
  }
}

class _HostButton extends ConsumerWidget {
  const _HostButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton.icon(
      icon: const Icon(Icons.lan_outlined, size: 16, color: TrafficGenScreen._ink2),
      label: Text(ref.read(trafficGenProvider.notifier).baseUrl.replaceFirst('http://', ''),
          style: const TextStyle(color: TrafficGenScreen._ink2, fontSize: 12)),
      onPressed: () => _editHost(context, ref),
    );
  }

  Future<void> _editHost(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(trafficGenProvider.notifier);
    final current = notifier.baseUrl.replaceFirst('http://', '');
    final parts = current.split(':');
    final hostCtrl = TextEditingController(text: parts.first);
    final portCtrl = TextEditingController(text: parts.length > 1 ? parts[1] : '8080');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TrafficGenScreen._panel,
        title: const Text('Generator address', style: TextStyle(color: TrafficGenScreen._ink)),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: hostCtrl,
                style: const TextStyle(color: TrafficGenScreen._ink),
                decoration: const InputDecoration(labelText: 'host / IP'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: portCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: TrafficGenScreen._ink),
                decoration: const InputDecoration(labelText: 'port'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Connect')),
        ],
      ),
    );
    if (ok == true) {
      await notifier.setEndpoint(
          hostCtrl.text.trim(), int.tryParse(portCtrl.text.trim()) ?? 8080);
    }
  }
}

// ---------------------------------------------------------------------------
// gauges
// ---------------------------------------------------------------------------
class _Gauges extends StatelessWidget {
  const _Gauges({required this.state});
  final TrafficGenState state;

  @override
  Widget build(BuildContext context) {
    final s = state.last;
    final pct = (s.mbps / 1000 * 100).clamp(0, 100).toDouble();
    return Row(
      children: [
        Expanded(
          child: _GaugeTile(
            label: 'THROUGHPUT',
            value: s.mbps.toStringAsFixed(1),
            unit: 'Mbps',
            sub: '${pct.toStringAsFixed(0)}% of 1G line rate',
            fill: pct / 100,
            color: TrafficGenScreen._blue,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _GaugeTile(
            label: 'PACKET RATE',
            value: _compact(s.pps),
            unit: 'pps',
            sub: '${(s.pps / 1000).toStringAsFixed(1)} kpps',
            fill: (s.pps / 1488095).clamp(0, 1).toDouble(),
            color: TrafficGenScreen._orange,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _GaugeTile(
            label: 'SENT',
            value: _compact(s.sentPackets),
            unit: 'pkts',
            sub: '${_compact(s.txErrors)} err / ${_compact(s.txDropped)} drop',
            subColor: (s.txErrors > 0 || s.txDropped > 0)
                ? TrafficGenScreen._red
                : TrafficGenScreen._ink2,
            fill: null,
            color: TrafficGenScreen._green,
          ),
        ),
      ],
    );
  }
}

class _GaugeTile extends StatelessWidget {
  const _GaugeTile({
    required this.label,
    required this.value,
    required this.unit,
    required this.sub,
    required this.fill,
    required this.color,
    this.subColor,
  });

  final String label;
  final String value;
  final String unit;
  final String sub;
  final double? fill;
  final Color color;
  final Color? subColor;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(
                  color: TrafficGenScreen._ink3, fontSize: 10, letterSpacing: 1)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  style: const TextStyle(
                      color: TrafficGenScreen._ink,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      fontFeatures: [FontFeature.tabularFigures()])),
              const SizedBox(width: 4),
              Text(unit,
                  style: const TextStyle(color: TrafficGenScreen._ink3, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 6),
          if (fill != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: fill!.clamp(0, 1),
                minHeight: 6,
                backgroundColor: TrafficGenScreen._panelHi,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          const SizedBox(height: 6),
          Text(sub,
              style: TextStyle(
                  color: subColor ?? TrafficGenScreen._ink2,
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// live chart
// ---------------------------------------------------------------------------
class _ChartPanel extends StatelessWidget {
  const _ChartPanel({required this.state});
  final TrafficGenState state;

  @override
  Widget build(BuildContext context) {
    final hist = state.history;
    final mbpsSpots = <FlSpot>[];
    final ppsSpots = <FlSpot>[];
    for (var i = 0; i < hist.length; i++) {
      mbpsSpots.add(FlSpot(i.toDouble(), hist[i].mbps));
      ppsSpots.add(FlSpot(i.toDouble(), hist[i].pps));
    }
    final maxMbps =
        (hist.isEmpty ? 10.0 : hist.map((e) => e.mbps).reduce((a, b) => a > b ? a : b)) * 1.15;
    final maxPps =
        (hist.isEmpty ? 1000.0 : hist.map((e) => e.pps).reduce((a, b) => a > b ? a : b)) * 1.15;
    final safeMbps = maxMbps < 10 ? 10.0 : maxMbps;
    final safePps = maxPps < 1000 ? 1000.0 : maxPps;

    // Packet-rate is drawn on the same 0..1 normalised axis as throughput so a
    // single y-scale carries both (the right-hand tick labels re-map to pps).
    List<FlSpot> norm(List<FlSpot> spots, double max) =>
        [for (final s in spots) FlSpot(s.x, s.y / max)];

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _legendDot(TrafficGenScreen._blue, 'Throughput (Mbps)'),
              const SizedBox(width: 16),
              _legendDot(TrafficGenScreen._orange, 'Packet rate (pps)'),
              const Spacer(),
              Text('${hist.length ~/ 2}s window',
                  style: const TextStyle(color: TrafficGenScreen._ink3, fontSize: 10)),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: LineChart(
              LineChartData(
                minY: 0,
                maxY: 1,
                minX: 0,
                maxX: (hist.length - 1).clamp(1, 240).toDouble(),
                clipData: const FlClipData.all(),
                gridData: FlGridData(
                  drawVerticalLine: false,
                  horizontalInterval: 0.25,
                  getDrawingHorizontalLine: (_) =>
                      const FlLine(color: Color(0xFF2A2F37), strokeWidth: 1),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 42,
                      interval: 0.25,
                      getTitlesWidget: (v, _) => Text(
                        (safeMbps * v).toStringAsFixed(0),
                        style: const TextStyle(color: TrafficGenScreen._blue, fontSize: 9),
                      ),
                    ),
                  ),
                  rightTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 42,
                      interval: 0.25,
                      getTitlesWidget: (v, _) => Text(
                        _compact(safePps * v),
                        style: const TextStyle(color: TrafficGenScreen._orange, fontSize: 9),
                      ),
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineTouchData: const LineTouchData(enabled: false),
                lineBarsData: [
                  _line(norm(mbpsSpots, safeMbps), TrafficGenScreen._blue),
                  _line(norm(ppsSpots, safePps), TrafficGenScreen._orange),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  LineChartBarData _line(List<FlSpot> spots, Color color) => LineChartBarData(
        spots: spots,
        isCurved: false,
        color: color,
        barWidth: 2,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: true, color: color.withOpacity(0.12)),
      );

  Widget _legendDot(Color color, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: TrafficGenScreen._ink2, fontSize: 11)),
        ],
      );
}

// ---------------------------------------------------------------------------
// control panel: presets + start/stop + banner
// ---------------------------------------------------------------------------
class _ControlPanel extends ConsumerWidget {
  const _ControlPanel({required this.state});
  final TrafficGenState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(trafficGenProvider.notifier);
    // Over BLE there is no /api/system, so fall back to the built-in preset list
    // baked into the app.
    final presets = state.isBle
        ? [for (final p in kBuiltinPresets) TgPreset(key: p.key, label: p.label, note: p.label)]
        : (state.system?.presets ?? const <TgPreset>[]);
    final block = state.isBle ? null : state.system?.blockReason;
    final locked = state.running;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (block != null) _banner(block, TrafficGenScreen._red, Icons.error_outline),
          if (state.message != null)
            _banner(state.message!,
                state.isError ? TrafficGenScreen._red : TrafficGenScreen._ink2,
                state.isError ? Icons.warning_amber_rounded : Icons.info_outline),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in presets)
                _PresetChip(
                  preset: p,
                  enabled: !locked,
                  onTap: () => n.loadPreset(p.key),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (state.plan != null)
            Text(
              'planned  ${state.plannedMbps.toStringAsFixed(1)} Mbps · '
              '${_compact(state.plannedPps)} pps'
              '${state.plannedOverLine ? "   ⚠ over 1G" : ""}',
              style: TextStyle(
                  color: state.plannedOverLine ? TrafficGenScreen._red : TrafficGenScreen._ink2,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          const SizedBox(height: 10),
          // one-tap TSN test traffic: load the CBS profile (PCP->TC as on the 9662)
          // and start. Big and obvious for the demo.
          _BigButton(
            label: state.running ? 'TSN ON' : 'TSN ON',
            icon: Icons.bolt_rounded,
            color: state.running ? TrafficGenScreen._blue : TrafficGenScreen._green,
            enabled: block == null && state.link == TgLink.online,
            onTap: () async {
              await n.loadPreset('cbs_tc2_tc6');
              await n.start();
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _BigButton(
                  label: 'STOP',
                  icon: Icons.stop_rounded,
                  color: TrafficGenScreen._red,
                  enabled: state.running,
                  onTap: n.stop,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: _BigButton(
                  label: 'START',
                  icon: Icons.play_arrow_rounded,
                  color: TrafficGenScreen._green,
                  enabled: !state.running && block == null && state.link == TgLink.online,
                  onTap: n.start,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _banner(String text, Color color, IconData icon) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
                child: Text(text, style: TextStyle(color: color, fontSize: 12))),
          ],
        ),
      );
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({required this.preset, required this.enabled, required this.onTap});
  final TgPreset preset;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: preset.note,
      child: Material(
        color: TrafficGenScreen._panelHi,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: TrafficGenScreen._line),
            ),
            child: Text(preset.label,
                style: TextStyle(
                    color: enabled ? TrafficGenScreen._ink : TrafficGenScreen._ink3,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: Colors.white),
                const SizedBox(width: 6),
                Text(label,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// stream editor
// ---------------------------------------------------------------------------
class _StreamEditor extends ConsumerWidget {
  const _StreamEditor({required this.state});
  final TrafficGenState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(trafficGenProvider.notifier);
    final cfg = state.config;
    final locked = state.running;

    return _Panel(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('STREAMS',
                  style: TextStyle(
                      color: TrafficGenScreen._ink3, fontSize: 11, letterSpacing: 1)),
              const Spacer(),
              if (!state.isBle && cfg != null)
                _IfaceDropdown(cfg: cfg, system: state.system, enabled: !locked),
              if (!state.isBle) const SizedBox(width: 8),
              if (!state.isBle)
                _MiniButton(
                  label: '+ stream',
                  enabled: !locked && cfg != null,
                  onTap: () => n.edit((c) {
                    final cpus = state.system?.cpus ?? 4;
                    final idx = c.streams.length;
                    c.streams.add(TgStream(
                      name: 'stream ${idx + 1}',
                      cpu: idx % cpus,
                      queue: idx % 4,
                    ));
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: state.isBle
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        'Over BLE: presets + start/stop.\nSwitch to WiFi to edit individual streams.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: TrafficGenScreen._ink3, height: 1.5),
                      ),
                    ),
                  )
                : cfg == null
                    ? const Center(
                        child: Text('no config',
                            style: TextStyle(color: TrafficGenScreen._ink3)))
                    : ListView.separated(
                    itemCount: cfg.streams.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) =>
                        _StreamCard(index: i, stream: cfg.streams[i], locked: locked),
                  ),
          ),
        ],
      ),
    );
  }
}

class _IfaceDropdown extends ConsumerWidget {
  const _IfaceDropdown({required this.cfg, required this.system, required this.enabled});
  final TgConfig cfg;
  final TgSystem? system;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(trafficGenProvider.notifier);
    final items = system?.interfaces ?? const [];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: TrafficGenScreen._panelHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TrafficGenScreen._line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: items.any((i) => i.name == cfg.iface) ? cfg.iface : null,
          hint: Text(cfg.iface, style: const TextStyle(color: TrafficGenScreen._ink, fontSize: 12)),
          dropdownColor: TrafficGenScreen._panelHi,
          isDense: true,
          style: const TextStyle(color: TrafficGenScreen._ink, fontSize: 12),
          items: [
            for (final i in items)
              DropdownMenuItem(
                value: i.name,
                child: Text('${i.name}  ${i.speedMbps ?? "?"}M ${i.operstate}',
                    style: const TextStyle(fontSize: 12)),
              ),
          ],
          onChanged: enabled ? (v) => n.edit((c) => c.iface = v ?? c.iface) : null,
        ),
      ),
    );
  }
}

class _StreamCard extends ConsumerWidget {
  const _StreamCard({required this.index, required this.stream, required this.locked});
  final int index;
  final TgStream stream;
  final bool locked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(trafficGenProvider.notifier);
    return Opacity(
      opacity: stream.enabled ? 1 : 0.5,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: TrafficGenScreen._panelHi,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: TrafficGenScreen._line),
        ),
        child: Column(
          children: [
            Row(
              children: [
                _Toggle(
                  on: stream.enabled,
                  enabled: !locked,
                  onTap: () => n.edit((_) => stream.enabled = !stream.enabled),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _InlineText(
                    value: stream.name,
                    bold: true,
                    enabled: !locked,
                    onChanged: (v) => n.edit((_) => stream.name = v),
                  ),
                ),
                _rateModeChips(n),
                if (!locked)
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        size: 18, color: TrafficGenScreen._ink3),
                    onPressed: () => n.edit((c) => c.streams.removeAt(index)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _NumField(
                    label: 'frame B',
                    value: stream.frameSize,
                    enabled: !locked,
                    onChanged: (v) => n.edit((_) { if (v != null) stream.frameSize = v; })),
                if (stream.rateMode != 'max')
                  _NumField(
                      label: stream.rateMode == 'mbps' ? 'Mbps' : 'pps',
                      value: stream.rateValue.round(),
                      enabled: !locked,
                      onChanged: (v) => n.edit((_) { if (v != null) stream.rateValue = v.toDouble(); })),
                _NumField(
                    label: 'VLAN',
                    value: stream.vlanId,
                    nullable: true,
                    enabled: !locked,
                    onChanged: (v) => n.edit((_) => stream.vlanId = v)),
                _NumField(
                    label: 'PCP',
                    value: stream.pcp,
                    enabled: !locked,
                    onChanged: (v) => n.edit((_) { if (v != null) stream.pcp = v.clamp(0, 7); })),
                _NumField(
                    label: 'CPU',
                    value: stream.cpu,
                    enabled: !locked,
                    onChanged: (v) => n.edit((_) { if (v != null) stream.cpu = v; })),
                _NumField(
                    label: 'queue',
                    value: stream.queue,
                    enabled: !locked,
                    onChanged: (v) => n.edit((_) { if (v != null) stream.queue = v; })),
                _TextFieldMini(
                    label: 'dst MAC',
                    value: stream.dstMac,
                    width: 150,
                    enabled: !locked,
                    onChanged: (v) => n.edit((_) => stream.dstMac = v)),
                _TextFieldMini(
                    label: 'dst IP',
                    value: stream.dstIp,
                    width: 120,
                    enabled: !locked,
                    onChanged: (v) => n.edit((_) => stream.dstIp = v)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _rateModeChips(TrafficGenNotifier n) {
    Widget chip(String mode, String label) {
      final on = stream.rateMode == mode;
      return GestureDetector(
        onTap: locked ? null : () => n.edit((_) => stream.rateMode = mode),
        child: Container(
          margin: const EdgeInsets.only(left: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: on ? TrafficGenScreen._blue.withOpacity(0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: on ? TrafficGenScreen._blue : TrafficGenScreen._line),
          ),
          child: Text(label,
              style: TextStyle(
                  color: on ? TrafficGenScreen._blue : TrafficGenScreen._ink2,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      chip('max', 'max'),
      chip('mbps', 'Mbps'),
      chip('pps', 'pps'),
    ]);
  }
}

// ---- little inputs --------------------------------------------------------
class _Toggle extends StatelessWidget {
  const _Toggle({required this.on, required this.enabled, required this.onTap});
  final bool on;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 40,
        height: 22,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: on ? TrafficGenScreen._green.withOpacity(0.35) : TrafficGenScreen._bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: TrafficGenScreen._line),
        ),
        child: Align(
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: on ? TrafficGenScreen._green : TrafficGenScreen._ink3,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineText extends StatefulWidget {
  const _InlineText(
      {required this.value, required this.onChanged, this.bold = false, this.enabled = true});
  final String value;
  final ValueChanged<String> onChanged;
  final bool bold;
  final bool enabled;

  @override
  State<_InlineText> createState() => _InlineTextState();
}

class _InlineTextState extends State<_InlineText> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      enabled: widget.enabled,
      style: TextStyle(
          color: TrafficGenScreen._ink,
          fontSize: 13,
          fontWeight: widget.bold ? FontWeight.w700 : FontWeight.w500),
      decoration: const InputDecoration(
          isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.zero),
      onSubmitted: widget.onChanged,
      onEditingComplete: () => widget.onChanged(_c.text),
    );
  }
}

class _NumField extends StatefulWidget {
  const _NumField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.nullable = false,
    this.enabled = true,
  });
  final String label;
  final int? value;
  final ValueChanged<int?> onChanged;
  final bool nullable;
  final bool enabled;

  @override
  State<_NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<_NumField> {
  late final _c =
      TextEditingController(text: widget.value?.toString() ?? '');

  @override
  void didUpdateWidget(covariant _NumField old) {
    super.didUpdateWidget(old);
    final incoming = widget.value?.toString() ?? '';
    if (incoming != _c.text && !_c.selection.isValid) _c.text = incoming;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _commit(String v) {
    final t = v.trim();
    if (t.isEmpty) {
      if (widget.nullable) widget.onChanged(null);
      return;
    }
    final parsed = int.tryParse(t);
    if (parsed != null) widget.onChanged(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return _FieldShell(
      label: widget.label,
      width: 68,
      child: TextField(
        controller: _c,
        enabled: widget.enabled,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
        style: const TextStyle(
            color: TrafficGenScreen._ink,
            fontSize: 13,
            fontFeatures: [FontFeature.tabularFigures()]),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: widget.nullable ? 'none' : null,
          hintStyle: const TextStyle(color: TrafficGenScreen._ink3, fontSize: 12),
        ),
        onSubmitted: _commit,
        onEditingComplete: () => _commit(_c.text),
      ),
    );
  }
}

class _TextFieldMini extends StatefulWidget {
  const _TextFieldMini({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.width,
    this.enabled = true,
  });
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final double width;
  final bool enabled;

  @override
  State<_TextFieldMini> createState() => _TextFieldMiniState();
}

class _TextFieldMiniState extends State<_TextFieldMini> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _FieldShell(
      label: widget.label,
      width: widget.width,
      child: TextField(
        controller: _c,
        enabled: widget.enabled,
        style: const TextStyle(color: TrafficGenScreen._ink, fontSize: 13),
        decoration: const InputDecoration(
            isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.zero),
        onSubmitted: widget.onChanged,
        onEditingComplete: () => widget.onChanged(_c.text),
      ),
    );
  }
}

class _FieldShell extends StatelessWidget {
  const _FieldShell({required this.label, required this.child, required this.width});
  final String label;
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(color: TrafficGenScreen._ink3, fontSize: 9)),
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: TrafficGenScreen._bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: TrafficGenScreen._line),
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({required this.label, required this.enabled, required this.onTap});
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: TrafficGenScreen._panelHi,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: TrafficGenScreen._line),
            ),
            child: Text(label,
                style: const TextStyle(
                    color: TrafficGenScreen._ink, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}
