import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import '../providers/keti_link_provider.dart';
import '../services/keti_link_service.dart';

/// The console: switch port state on one side, the two fault-injection paths on the other.
///
/// Every number on this screen is either measured or explicitly marked as not measured. The
/// previous rig showed a green header and minutes-old counters after its gateway had gone
/// silent, because it watched the connection rather than the data.
class SwitchConsoleScreen extends ConsumerStatefulWidget {
  const SwitchConsoleScreen({super.key});

  @override
  ConsumerState<SwitchConsoleScreen> createState() => _SwitchConsoleScreenState();
}

class _SwitchConsoleScreenState extends ConsumerState<SwitchConsoleScreen> {
  Timer? _tick;

  /// Throughput needs two readings, so the previous snapshot is kept to subtract from.
  SwitchSnapshot? _previous;
  final _rates = <String, double>{};

  @override
  void initState() {
    super.initState();
    // Staleness is a function of elapsed time, not of incoming data: without a repaint the
    // "last update" age would freeze at whatever it was when the updates stopped.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _updateRates(SwitchSnapshot? snapshot) {
    if (snapshot == null) return;
    final previous = _previous;
    if (previous != null && previous.sequence != snapshot.sequence) {
      final seconds =
          snapshot.receivedAt.difference(previous.receivedAt).inMilliseconds / 1000.0;
      if (seconds > 0.2) {
        for (final port in snapshot.ports) {
          final before = previous.ports.where((p) => p.name == port.name).firstOrNull;
          if (before == null) continue;
          final delta = (port.inOctets + port.outOctets) -
              (before.inOctets + before.outOctets);
          // Counters reset when the switch reboots; a negative delta is not a rate.
          if (delta >= 0) _rates[port.name] = delta * 8 / seconds / 1000.0;
        }
      }
    }
    if (previous == null || previous.sequence != snapshot.sequence) {
      _previous = snapshot;
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(ketiStateProvider);
    final state = async.valueOrNull ?? const KetiState();
    _updateRates(state.switchSnapshot);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFFF2F4F7)),
          const ModelViewer(
            backgroundColor: Color(0xFFF2F4F7),
            src: 'lib/assets/roii_reconfig.glb',
            alt: 'KETI reconfigurable vehicle',
            disablePan: true,
            disableTap: true,
            cameraControls: true,
            autoRotate: false,
            cameraOrbit: '45deg 68deg 105%',
            cameraTarget: 'auto 8m auto',
          ),
          Positioned(left: 14, right: 14, top: 10, child: _Header(state: state)),
          Positioned(
            left: 14,
            top: 76,
            bottom: 14,
            width: 300,
            child: _PathRail(state: state),
          ),
          Positioned(
            right: 14,
            top: 76,
            bottom: 14,
            width: 400,
            child: _SwitchPanel(state: state, rates: _rates),
          ),
        ],
      ),
    );
  }
}

bool _fresh(DateTime? at) =>
    at != null && DateTime.now().difference(at) < KetiLinkService.staleAfter;

String _age(DateTime? at) {
  if (at == null) return 'never';
  final seconds = DateTime.now().difference(at).inSeconds;
  return seconds <= 1 ? 'now' : '${seconds}s ago';
}

class _Glass extends StatelessWidget {
  const _Glass({required this.child, this.padding = const EdgeInsets.all(13)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.93),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE3E8EF)),
        boxShadow: const [
          BoxShadow(color: Color(0x14000000), blurRadius: 18, offset: Offset(0, 6)),
        ],
      ),
      child: child,
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state});

  final KetiState state;

  @override
  Widget build(BuildContext context) {
    final snapshot = state.switchSnapshot;
    return _Glass(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          const Text(
            'KETI Reconfig Console',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF172033)),
          ),
          const SizedBox(width: 16),
          for (final device in KetiDevice.values) ...[
            _LinkPill(
              label: device.label,
              connected: state.connected.contains(device),
              fresh: switch (device) {
                KetiDevice.switchController => _fresh(snapshot?.receivedAt),
                KetiDevice.path1 => _fresh(state.pathSnapshots[1]?.receivedAt),
                KetiDevice.path2 => _fresh(state.pathSnapshots[2]?.receivedAt),
              },
            ),
            const SizedBox(width: 6),
          ],
          const Spacer(),
          if (state.scanning)
            const Text('scanning...',
                style: TextStyle(fontSize: 11, color: Color(0xFF7A8699))),
        ],
      ),
    );
  }
}

/// Connected and fresh are different things, and the difference is the whole point: a GATT
/// link stays up when the peer stops talking.
class _LinkPill extends StatelessWidget {
  const _LinkPill({required this.label, required this.connected, required this.fresh});

  final String label;
  final bool connected;
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final (background, foreground, suffix) = switch ((connected, fresh)) {
      (true, true) => (const Color(0xFFE7F6EF), const Color(0xFF0F766E), 'live'),
      (true, false) => (const Color(0xFFFDF3E3), const Color(0xFFB45309), 'silent'),
      _ => (const Color(0xFFF1F3F6), const Color(0xFF7A8699), 'offline'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(9)),
      child: Text('$label: $suffix',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: foreground)),
    );
  }
}

class _PathRail extends ConsumerWidget {
  const _PathRail({required this.state});

  final KetiState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Fault injection',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF172033))),
          const SizedBox(height: 4),
          const Text('Relay on GPIO13 of each path module',
              style: TextStyle(fontSize: 11, color: Color(0xFF7A8699))),
          const SizedBox(height: 12),
          for (final path in [1, 2]) ...[
            _PathCard(
              path: path,
              snapshot: state.pathSnapshots[path],
              connected: state.connected
                  .contains(path == 1 ? KetiDevice.path1 : KetiDevice.path2),
              onSet: (faulted) =>
                  ref.read(ketiLinkServiceProvider).setPathFault(path, faulted),
            ),
            const SizedBox(height: 10),
          ],
          const Spacer(),
          const Text(
            'Losing the tablet returns a path to normal. With no operator attached, the safe '
            'state is the one that keeps traffic flowing.',
            style: TextStyle(fontSize: 10.5, height: 1.4, color: Color(0xFF8A94A6)),
          ),
        ],
      ),
    );
  }
}

class _PathCard extends StatelessWidget {
  const _PathCard({
    required this.path,
    required this.snapshot,
    required this.connected,
    required this.onSet,
  });

  final int path;
  final PathSnapshot? snapshot;
  final bool connected;
  final void Function(bool faulted) onSet;

  @override
  Widget build(BuildContext context) {
    final faulted = snapshot?.faulted ?? false;
    final fresh = _fresh(snapshot?.receivedAt);
    final live = connected && fresh;
    final accent = !live
        ? const Color(0xFF9AA5B5)
        : (faulted ? const Color(0xFFDC2626) : const Color(0xFF0F766E));

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: live && faulted ? const Color(0xFFFDF0F0) : const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE3E8EF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Path $path',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF172033))),
              const SizedBox(width: 8),
              Text(
                !connected
                    ? 'not connected'
                    : (!fresh ? 'silent, ${_age(snapshot?.receivedAt)}' : (faulted ? 'FAULT' : 'NORMAL')),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: accent),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _Button(
                  label: 'Inject fault',
                  active: live && faulted,
                  enabled: live,
                  color: const Color(0xFFDC2626),
                  onTap: () => onSet(true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Button(
                  label: 'Recover',
                  active: live && !faulted,
                  enabled: live,
                  color: const Color(0xFF0F766E),
                  onTap: () => onSet(false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            live
                ? 'relay ${snapshot!.relayClosed ? "closed" : "open"}  ·  '
                    'snapshot #${snapshot!.sequence}  ·  ${_age(snapshot!.receivedAt)}'
                : 'nothing measured',
            style: const TextStyle(fontSize: 10.5, color: Color(0xFF8A94A6)),
          ),
        ],
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({
    required this.label,
    required this.active,
    required this.enabled,
    required this.color,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool enabled;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.12) : Colors.white,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: active ? color : const Color(0xFFE3E8EF)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: enabled ? (active ? color : const Color(0xFF44506A)) : const Color(0xFFB9C1CE),
          ),
        ),
      ),
    );
  }
}

class _SwitchPanel extends StatelessWidget {
  const _SwitchPanel({required this.state, required this.rates});

  final KetiState state;
  final Map<String, double> rates;

  @override
  Widget build(BuildContext context) {
    final snapshot = state.switchSnapshot;
    final connected = state.connected.contains(KetiDevice.switchController);
    final fresh = _fresh(snapshot?.receivedAt);

    return _Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('LAN9662 switch',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF172033))),
          const SizedBox(height: 6),
          if (!connected)
            const _Note('No link to the switch controller -- nothing measured')
          else if (snapshot == null)
            const _Note('Connected, waiting for the first snapshot')
          else if (!fresh)
            _Note('Controller silent since ${_age(snapshot.receivedAt)} -- '
                'the values below are from snapshot #${snapshot.sequence}, not now')
          else if (!snapshot.catalogOk)
            _Note('The switch reports YANG catalog ${snapshot.catalog}, which is not the one '
                'the controller\'s SID table was built from. No port data is trustworthy.')
          else
            _Note('Ethernet ${snapshot.ethernetLinkUp ? "up" : "down"}  ·  '
                '${snapshot.ports.length} ports  ·  snapshot #${snapshot.sequence}  ·  '
                '${_age(snapshot.receivedAt)}'),
          const SizedBox(height: 10),
          if (snapshot != null && snapshot.catalogOk)
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.zero,
                itemCount: snapshot.ports.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _PortRow(
                  port: snapshot.ports[i],
                  kbps: rates[snapshot.ports[i].name],
                  stale: !fresh,
                ),
              ),
            )
          else
            const Spacer(),
          const SizedBox(height: 4),
          const Text(
            'Ports are whatever the switch reports, never a fixed list -- the LAN9692 has more '
            'than this bench part.',
            style: TextStyle(fontSize: 10.5, height: 1.4, color: Color(0xFF8A94A6)),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(fontSize: 11.5, height: 1.35, color: Color(0xFF7A8699)));
  }
}

class _PortRow extends StatelessWidget {
  const _PortRow({required this.port, required this.kbps, required this.stale});

  final SwitchPort port;
  final double? kbps;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final accent = stale
        ? const Color(0xFF9AA5B5)
        : (port.up ? const Color(0xFF0F766E) : const Color(0xFF9AA5B5));
    final faulty = port.inErrors + port.outErrors + port.inDiscards + port.outDiscards > 0;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFFE3E8EF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Port ${port.name}',
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w900, color: Color(0xFF172033))),
              const SizedBox(width: 8),
              Text(port.up ? 'UP' : 'DOWN',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: accent)),
              const Spacer(),
              Text(
                kbps == null ? '--' : '${kbps!.toStringAsFixed(1)} kbps',
                style: const TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w800, color: Color(0xFF44506A)),
              ),
            ],
          ),
          const SizedBox(height: 5),
          _Bar(kbps: kbps ?? 0),
          const SizedBox(height: 5),
          Text(
            'in ${_bytes(port.inOctets)} / ${port.inUnicast} pkt   '
            'out ${_bytes(port.outOctets)} / ${port.outUnicast} pkt',
            style: const TextStyle(fontSize: 10.5, color: Color(0xFF7A8699)),
          ),
          if (faulty)
            Text(
              'errors ${port.inErrors}/${port.outErrors}   '
              'discards ${port.inDiscards}/${port.outDiscards}',
              style: const TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFFB45309)),
            ),
        ],
      ),
    );
  }

  static String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// A log scale, because idle management traffic and a loaded port are orders of magnitude
/// apart and a linear bar would show the quiet ports as nothing at all.
class _Bar extends StatelessWidget {
  const _Bar({required this.kbps});

  final double kbps;

  @override
  Widget build(BuildContext context) {
    final fraction = kbps <= 0
        ? 0.0
        : ((kbps.clamp(0.1, 100000) / 0.1) / 1000000).clamp(0.0, 1.0);
    final scaled = kbps <= 0 ? 0.0 : (0.12 + 0.88 * (fraction == 0 ? 0 : _log10(kbps + 1) / 5));
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: scaled.clamp(0.0, 1.0),
        minHeight: 5,
        backgroundColor: const Color(0xFFE9EDF3),
        valueColor: const AlwaysStoppedAnimation(Color(0xFF4EA1FF)),
      ),
    );
  }

  static double _log10(double v) {
    var result = 0.0;
    var x = v;
    while (x >= 10) {
      x /= 10;
      result += 1;
    }
    return result + (x - 1) / 9;
  }
}
