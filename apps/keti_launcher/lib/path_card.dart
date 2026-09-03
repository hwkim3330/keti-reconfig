import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'rig.dart';
import 'theme.dart';

/// One module. The whole card is the control -- on a 7" panel held at arm's length next to a
/// bench, a button inside a card is a smaller target than the card itself.
///
/// It shows four things and refuses to show a fifth: which module, whether it is talking, whether
/// the path is cut, and how long ago it last said so. It never shows a value it cannot date.
class PathCard extends StatelessWidget {
  const PathCard({super.key, required this.link, required this.onToggle});

  final PathLink link;
  final Future<void> Function() onToggle;

  @override
  Widget build(BuildContext context) {
    final n = link.path;
    final accent = K.pathColour(n);
    final report = link.report;
    final now = DateTime.now();
    final stale = report != null && report.staleAt(now);
    final connected = link.state == LinkState.connected;
    final faulted = report?.faulted ?? false;

    final (Color colour, String state, String detail) = switch (link.state) {
      // Two different faults wear the same word, and they send you to different places. Having
      // heard an advertisement means the board is powered and in range, so a tile stuck here is
      // about connecting. Never having heard one means the board is off, out of range, or held
      // by another central -- a held module stops advertising entirely.
      LinkState.missing => (
          K.dim,
          '연결 안 됨',
          link.rssi == null ? '광고 안 보임 · 전원/거리/다른 센트럴' : '광고는 잡힘 · 연결 대기'
        ),
      LinkState.connecting => (K.warn, '연결 중', 'GATT'),
      LinkState.connected when report == null => (K.warn, '대기', '첫 보고 기다리는 중'),
      LinkState.connected when stale => (K.warn, '응답 없음', '${_age(now, report.at)} 전 마지막'),
      LinkState.connected => faulted
          ? (K.fault, 'FAULT', '경로 끊김 · 릴레이 ${report!.relayClosed ? "닫힘" : "열림"}')
          : (K.ok, 'NORMAL', '경로 정상 · 릴레이 ${report!.relayClosed ? "닫힘" : "열림"}'),
    };

    final actionable = connected && report != null && !link.pending;

    return Material(
      color: K.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: actionable
            ? () {
                HapticFeedback.mediumImpact();
                onToggle();
              }
            : null,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: faulted && connected && !stale ? K.fault : K.border,
              width: faulted && connected && !stale ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: connected ? accent : K.dim,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // The name carries the module's colour, not just the dot beside it. A 10 dp dot
                  // is the whole identity channel otherwise, and at that size the difference
                  // between blue and cyan is a guess.
                  Text(
                    'PATH $n',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: connected ? accent : K.dim,
                    ),
                  ),
                  const Spacer(),
                  if (link.rssi != null)
                    Text('${link.rssi} dBm',
                        style: K.mono.copyWith(fontSize: 10, color: K.dim)),
                ],
              ),
              const Spacer(),
              // Shrink-to-fit rather than wrap or ellipsis: in landscape four cards share the
              // width and "연결 안 됨" is wider than "FAULT". A state word that wraps or gets cut
              // is the one thing on this screen that has to be readable from across the bench.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  state,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 30,
                    height: 1.05,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: colour,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: K.muted)),
              const Spacer(),
              // The sequence number and the age are the only proof the module is alive: a GATT
              // connection stays up long after a wedged board has stopped talking.
              Row(
                children: [
                  Text(
                    report == null ? 'seq --' : 'seq ${report.sequence}',
                    style: K.mono.copyWith(fontSize: 10, color: K.dim),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    report == null ? '' : _age(now, report.at),
                    style: K.mono.copyWith(
                        fontSize: 10, color: stale ? K.warn : K.dim),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _button(faulted, actionable, connected),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button(bool faulted, bool actionable, bool connected) {
    final label = link.pending
        ? '전송 중…'
        : !connected
            ? '대기'
            : faulted
                ? 'RESTORE'
                : 'CUT';
    final colour = !actionable
        ? K.surfaceHi
        : faulted
            ? K.ok.withValues(alpha: 0.16)
            : K.fault.withValues(alpha: 0.16);
    final fg = !actionable
        ? K.dim
        : faulted
            ? K.ok
            : K.fault;

    return SizedBox(
      width: double.infinity,
      height: 44,
      child: Material(
        color: colour,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: actionable
              ? () {
                  HapticFeedback.mediumImpact();
                  onToggle();
                }
              : null,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _age(DateTime now, DateTime at) {
  final s = now.difference(at).inSeconds;
  if (s < 1) return 'now';
  if (s < 60) return '${s}s';
  final m = s ~/ 60;
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h';
}
