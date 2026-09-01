import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/traffic_gen_provider.dart';

/// Inline TSN shaper config (CBS / TAS / FRER) for the unified Show hero. CBS is
/// parametric -- pick egress port + queue/TC + rate so it can be applied at any
/// point of contention -- and commands go over BLE to the bridge Pi. Shown in a
/// bottom sheet so the whole app stays one screen.
class ShaperConfig extends ConsumerStatefulWidget {
  const ShaperConfig({super.key});
  @override
  ConsumerState<ShaperConfig> createState() => _ShaperConfigState();
}

class _ShaperConfigState extends ConsumerState<ShaperConfig> {
  int _tab = 0; // 0 CBS, 1 TAS, 2 FRER
  final _sel = <int, String>{0: '250', 1: '1000', 2: 'vector'};
  String _cbsPort = '2';
  int _cbsQueue = 6;

  static const _blue = Color(0xFF007AFF);
  static const _ink = Color(0xFF1D1D1F);
  static const _ink2 = Color(0xFF9AA3B2);

  static const _tabs = ['CBS', 'TAS', 'FRER'];
  static const _tabSub = [
    '802.1Qav · reserve a queue against the flood',
    '802.1Qbv · time-aware gates',
    '802.1CB · seamless redundancy',
  ];
  static const _params = [
    [['100', 'Mbps'], ['250', 'Mbps'], ['500', 'Mbps']],
    [['250', 'µs'], ['500', 'µs'], ['1000', 'µs']],
    [['vector', ''], ['match', '']],
  ];
  static const _onCmd = ['cbs', 'tas', 'frer'];
  static const _param = ['cbs:mbps:', 'tas:cycle:', 'frer:alg:'];

  void _send(String c) => ref.read(trafficGenProvider.notifier).sendControl(c);

  void _apply(bool on) {
    if (_tab == 0) {
      _send('cbs:cfg:$_cbsPort:$_cbsQueue:${_sel[0]}:${on ? 'on' : 'off'}');
    } else {
      _send('${_onCmd[_tab]}:${on ? 'on' : 'off'}');
    }
  }

  Widget _chip(String text, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: on ? const Color(0xFFEDF2FD) : const Color(0xFFF5F6F9),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: on ? _blue : const Color(0xFFE2E6EE)),
          ),
          child: Text(text,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600, color: on ? _blue : const Color(0xFF6B7280))),
        ),
      );

  Widget _row(String label, List<String> opts, String cur, void Function(String) pick, String Function(String) fmt) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(children: [
          SizedBox(width: 84, child: Text(label, style: const TextStyle(fontSize: 12, color: _ink2, fontWeight: FontWeight.w600))),
          Expanded(
            child: Wrap(spacing: 7, children: [
              for (final o in opts) _chip(fmt(o), cur == o, () => setState(() => pick(o))),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(
          child: Container(width: 40, height: 4, decoration: BoxDecoration(
              color: const Color(0xFFE2E6EE), borderRadius: BorderRadius.circular(2))),
        ),
        const SizedBox(height: 14),
        // tab strip
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: const Color(0xFFF0F2F6), borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            for (var i = 0; i < _tabs.length; i++)
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _tab = i),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: _tab == i ? Colors.white : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: _tab == i ? [const BoxShadow(color: Color(0x14000000), blurRadius: 4)] : null,
                    ),
                    child: Text(_tabs[i], textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _tab == i ? _blue : _ink2)),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 10),
        Text(_tabSub[_tab], style: const TextStyle(fontSize: 11.5, color: _ink2)),
        const SizedBox(height: 10),
        // rate / cycle / algorithm
        Row(children: [
          SizedBox(width: 84, child: Text(_tab == 2 ? 'Algorithm' : (_tab == 1 ? 'Cycle' : 'Reserve'),
              style: const TextStyle(fontSize: 12, color: _ink2, fontWeight: FontWeight.w600))),
          Expanded(child: Wrap(spacing: 7, children: [
            for (final p in _params[_tab])
              _chip('${p[0]}${p[1].isEmpty ? '' : ' ${p[1]}'}', _sel[_tab] == p[0], () {
                setState(() => _sel[_tab] = p[0]);
                _send('${_param[_tab]}${p[0]}');
              }),
          ])),
        ]),
        // CBS-only: egress port + queue/TC
        if (_tab == 0) ...[
          _row('Egress port', const ['1', '2', '4', '6'], _cbsPort, (v) => _cbsPort = v, (v) => 'Gi 1/$v'),
          _row('Queue · TC', const ['0', '2', '6'], '$_cbsQueue', (v) => _cbsQueue = int.parse(v),
              (v) => v == '6' ? 'TC6 video' : (v == '0' ? 'TC0 flood' : 'TC$v')),
        ],
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: _action('Enable', _blue, Colors.white, () { _apply(true); Navigator.of(context).maybePop(); })),
          const SizedBox(width: 12),
          Expanded(child: _action('Disable', const Color(0xFFF0F2F6), _ink, () { _apply(false); Navigator.of(context).maybePop(); })),
        ]),
      ]),
    );
  }

  Widget _action(String label, Color bg, Color fg, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(13)),
          child: Text(label, style: TextStyle(color: fg, fontSize: 15, fontWeight: FontWeight.w700)),
        ),
      );
}
