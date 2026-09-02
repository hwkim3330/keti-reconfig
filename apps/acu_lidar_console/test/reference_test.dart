import 'package:acu_lidar_console/core/reference.dart';
import 'package:flutter_test/flutter_test.dart';

/// The reference data is hand-transcribed from photographs of design sheets, so the failure mode
/// is a typo that reads perfectly well on screen -- a port pointing at a device id that does not
/// exist, or a camera quietly landing on two jacks. These check the shape of the transcription,
/// not the sheets themselves.
void main() {
  test('node ids are unique', () {
    final ids = allNodes.map((n) => n.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('every ACU_IT port peer resolves to a node', () {
    for (final p in acuItPorts) {
      if (p.peerNodeId == null) continue;
      expect(nodeById(p.peerNodeId!), isNotNull, reason: 'port ${p.id} -> ${p.peerNodeId}');
    }
  });

  test('every node that names a port points at a port that names it back', () {
    for (final n in allNodes) {
      if (n.acuPort == null) continue;
      final port = portById(n.acuPort!);
      expect(port, isNotNull, reason: '${n.id} -> port ${n.acuPort}');
      expect(port!.peerNodeId, n.id, reason: 'port ${port.id} should point back at ${n.id}');
    }
  });

  test('the four wired LiDARs sit on four distinct ports', () {
    // The whole reason one revision of sheet 1 is marked superseded: it gives 허밍버드 후방 two
    // ports and FalconK 후방 none. If that ever creeps back in, this fails.
    final wired = lidarNodes.where((n) => n.acuPort != null).toList();
    expect(wired.length, 4);
    expect(wired.map((n) => n.acuPort).toSet().length, 4);
  });

  test('ten camera feeds spread two per jack, no feed on two jacks', () {
    final onJacks = acuNoJacks.expand((j) => j.feedNodeIds).toList();
    expect(onJacks.length, 10);
    expect(onJacks.toSet().length, 10);
    for (final j in acuNoJacks) {
      expect(j.feedNodeIds.length, 2, reason: '${j.id} is a dual jack');
    }
    expect(
      onJacks.toSet(),
      cameraNodes.map((n) => n.id).toSet(),
      reason: 'every camera node lands on a jack and vice versa',
    );
  });

  test('port ids are unique and every connector cavity is addressed once', () {
    final ids = acuItPorts.map((p) => p.id).toList();
    expect(ids.toSet().length, ids.length);
    for (final conn in acuItConnectors) {
      final slots = acuItPorts
          .where((p) => p.connectorId == conn.id)
          .map((p) => '${p.row}:${p.col}')
          .toList();
      expect(slots.toSet().length, slots.length, reason: 'connector ${conn.id} double-books a slot');
    }
  });

  test('inferred values carry a note saying why', () {
    for (final p in acuItPorts) {
      if (p.speed.from == Provenance.sheet) continue;
      expect(p.speed.note, isNotNull, reason: 'port ${p.id} speed is not a sheet reading');
    }
  });

  test('every sheet image referenced by the data is also listed under Sheets', () {
    final listed = sheetGroups.values.expand((g) => g.map((s) => s.asset)).toSet();
    for (final n in allNodes) {
      if (n.refImage == null) continue;
      expect(listed, contains(n.refImage), reason: '${n.id} points at an unlisted image');
    }
    for (final p in pinouts) {
      if (p.refImage == null) continue;
      expect(listed, contains(p.refImage), reason: 'pinout ${p.id} points at an unlisted image');
    }
  });
}
