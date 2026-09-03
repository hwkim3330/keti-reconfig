import 'package:flutter/material.dart';

import 'rig.dart';
import 'theme.dart';

/// What the rig has said, newest first.
///
/// Kept out of the home screen on purpose: the tiles answer "what is the state now", and mixing a
/// scrolling history into them makes the current state harder to read, not easier. This is for
/// after something went wrong -- which module dropped, in what order, and whether the fault that
/// appeared came from a button or from the module restoring itself.
class LogSheet extends StatefulWidget {
  const LogSheet({super.key, required this.rig});

  final Rig rig;

  static Future<void> show(BuildContext context, Rig rig) => showModalBottomSheet(
        context: context,
        backgroundColor: K.surface,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (_) => LogSheet(rig: rig),
      );

  @override
  State<LogSheet> createState() => _LogSheetState();
}

class _LogSheetState extends State<LogSheet> {
  @override
  void initState() {
    super.initState();
    widget.rig.addListener(_onRig);
  }

  void _onRig() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.rig.removeListener(_onRig);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.rig.log;
    return FractionallySizedBox(
      heightFactor: 0.8,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 44,
            height: 4,
            decoration:
                BoxDecoration(color: K.border, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
            child: Row(children: [
              const Text('로그',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800, color: K.text)),
              const SizedBox(width: 8),
              Text('${lines.length}',
                  style: K.mono.copyWith(fontSize: 12, color: K.dim)),
              const Spacer(),
              TextButton(
                onPressed: widget.rig.clearLog,
                style: TextButton.styleFrom(foregroundColor: K.muted),
                child: const Text('비우기', style: TextStyle(fontSize: 12)),
              ),
            ]),
          ),
          Expanded(
            child: lines.isEmpty
                ? const Center(
                    child: Text('아직 기록 없음',
                        style: TextStyle(color: K.dim, fontSize: 13)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: lines.length,
                    itemBuilder: (context, i) {
                      final l = lines[i];
                      final colour = l.path == 0 ? K.muted : K.pathColour(l.path);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_hms(l.at),
                                style: K.mono.copyWith(fontSize: 11, color: K.dim)),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 46,
                              child: Text(
                                l.path == 0 ? 'rig' : 'path ${l.path}',
                                style: K.mono.copyWith(fontSize: 11, color: colour),
                              ),
                            ),
                            Expanded(
                              child: Text(l.text,
                                  style: const TextStyle(
                                      fontSize: 12, color: K.text, height: 1.3)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

String _hms(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
