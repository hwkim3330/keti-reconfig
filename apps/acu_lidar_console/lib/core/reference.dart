import 'dart:ui' show Offset;

/// Everything in this file is transcribed from the 2026 a2z ACU / LiDAR design sheets
/// (`ACU_LiDAR_reference_images.zip`, five sheets: ACU1_IT, LIDAR_FRNT&REAR (Hummingbird),
/// LIDAR_ROOF_FRNT&REAR (Falcon K1), LIDAR_LH&RH, ACU2_NO).
///
/// The sheets are the only authority here, and they are not internally consistent -- two of
/// them carry a superseded revision of the same picture. So every fact carries where it came
/// from, and the console renders [Provenance.inferred] and [Provenance.conflict] differently
/// from a plain reading. The rule this console inherits from the reconfig console it was cloned
/// from: a number is either sourced or it is visibly marked as not sourced. Nothing in between.
enum Provenance {
  /// Read directly off a sheet.
  sheet,

  /// The sheet shows two revisions that disagree; [Sourced.note] says how.
  conflict,

  /// Not on any sheet. Filled in from the part number or the connector family, and shown muted.
  inferred,
}

class Sourced<T> {
  final T value;
  final Provenance from;

  /// Which sheet image backs this, and -- for a conflict -- what the other revision says.
  final String? note;

  const Sourced(this.value, {this.from = Provenance.sheet, this.note});
}

// ---------------------------------------------------------------------------
// Devices on the vehicle
// ---------------------------------------------------------------------------

enum NodeKind { lidar, camera, acu, tcu, display, tsn }

/// A box on the vehicle. [pos] is a plan-view coordinate: x -1 (left) .. +1 (right),
/// y 0 (front bumper) .. 1 (rear bumper). It is a layout, not a measurement -- the sheets
/// give mounting photos, not vehicle coordinates.
class Node {
  final String id;
  final String name;
  final String? ko;
  final NodeKind kind;
  final String model;
  final Offset pos;
  final String mount;
  final String? refImage;
  final String? connector;
  final String? acuPort;

  const Node({
    required this.id,
    required this.name,
    required this.kind,
    required this.model,
    required this.pos,
    required this.mount,
    this.ko,
    this.refImage,
    this.connector,
    this.acuPort,
  });
}

const lidarNodes = <Node>[
  Node(
    id: 'fk_front',
    name: 'Falcon K1 · roof front',
    ko: 'FalconK 전방',
    kind: NodeKind.lidar,
    model: 'Falcon K1',
    pos: Offset(0, 0.30),
    mount: 'Roof, forward. Sheet 3 shows the harness dropping through the roof panel at the front unit only.',
    refImage: 'assets/ref/fk_mount.png',
    connector: 'CN1 · TE 2387380',
    acuPort: '0-1',
  ),
  Node(
    id: 'fk_rear',
    name: 'Falcon K1 · roof rear',
    ko: 'FalconK 후방',
    kind: NodeKind.lidar,
    model: 'Falcon K1',
    pos: Offset(0, 0.72),
    mount: 'Roof, aft. Same bracket as the front unit; sheet 3 shows no cable break-out at the rear view.',
    refImage: 'assets/ref/fk_mount.png',
    connector: 'CN1 · TE 2387380',
    acuPort: '2-3',
  ),
  Node(
    id: 'hb_front',
    name: 'Hummingbird · front',
    ko: '허밍버드 전방',
    kind: NodeKind.lidar,
    model: 'Hummingbird',
    pos: Offset(0, 0.04),
    mount: 'Front fascia, on a green bracket plate bolted to the bumper beam.',
    refImage: 'assets/ref/hb_mount.png',
    connector: 'CN1 · AMP HYBRID WP LIDAR CODE A · TE 2387380-1',
    acuPort: '2-4',
  ),
  Node(
    id: 'hb_rear',
    name: 'Hummingbird · rear',
    ko: '허밍버드 후방',
    kind: NodeKind.lidar,
    model: 'Hummingbird',
    pos: Offset(0, 0.96),
    mount: 'Rear fascia, bracket plate above the rear lamps.',
    refImage: 'assets/ref/hb_mount.png',
    connector: 'CN1 · AMP HYBRID WP LIDAR CODE A · TE 2387380-1',
    acuPort: '0-2',
  ),
  Node(
    id: 'lidar_lh',
    name: 'Side LiDAR · LH',
    ko: '측방 LiDAR 좌',
    kind: NodeKind.lidar,
    model: 'Hesai (spinning)',
    pos: Offset(-0.93, 0.42),
    mount: 'Roof edge, left. Sheet 4 shows the unit on a mast pigtail, not a bulkhead connector.',
    refImage: 'assets/ref/side_lidar.png',
    connector: 'Coding-A P/N 1897726-2 / 1897725-2 + HSD plug',
  ),
  Node(
    id: 'lidar_rh',
    name: 'Side LiDAR · RH',
    ko: '측방 LiDAR 우',
    kind: NodeKind.lidar,
    model: 'Hesai (spinning)',
    pos: Offset(0.93, 0.42),
    mount: 'Roof edge, right. Mirror of the LH unit.',
    refImage: 'assets/ref/side_lidar.png',
    connector: 'Coding-A P/N 1897726-2 / 1897725-2 + HSD plug',
  ),
];

const ecuNodes = <Node>[
  Node(
    id: 'acu_it',
    name: 'ACU_IT',
    ko: 'ACU 아이티',
    kind: NodeKind.acu,
    model: 'a2z ACU · TOTAL I/O, USB-C, LAN 1-3',
    pos: Offset(0.42, 0.78),
    mount: 'Rear compartment. Red-anodised finned case; three automotive-Ethernet connectors on the board edge.',
    refImage: 'assets/ref/acu_it_case.png',
  ),
  Node(
    id: 'acu_no',
    name: 'ACU_NO',
    ko: 'ACU 엔오',
    kind: NodeKind.acu,
    model: 'a2z ACU · CAM 1-5, LAN, TOTAL I/O, 2× USB-C',
    pos: Offset(-0.42, 0.78),
    mount: 'Rear compartment, relocated on the later sheet revision ("위치변경 (ACU NO)").',
    refImage: 'assets/ref/acu_no_case.png',
  ),
  Node(
    id: 'tcu_m',
    name: 'TCU_M',
    kind: NodeKind.tcu,
    model: 'Telematics, main',
    pos: Offset(0.42, 0.92),
    mount: 'Reached from ACU_IT port 2-2 and from ACU_NO on two 1G links (Orin A / Orin B).',
  ),
  Node(
    id: 'tcu_s',
    name: 'TCU_S',
    kind: NodeKind.tcu,
    model: 'Telematics, sub',
    pos: Offset(-0.42, 0.92),
    mount: 'ACU_IT port 1-4.',
  ),
  Node(
    id: 'display',
    name: 'DISPLAY',
    kind: NodeKind.display,
    model: 'Cabin display',
    pos: Offset(0, 0.20),
    mount: 'ACU_IT port 2-1.',
  ),
];

/// The ten camera feeds land on five dual FAKRA jacks, two per jack. Positions are a layout;
/// the sheet places them by name only.
const cameraNodes = <Node>[
  Node(id: 'cam_tf_110', name: 'TF Camera 110°', kind: NodeKind.camera, model: 'TF · 110°', pos: Offset(-0.30, 0.20), mount: 'Windshield, forward-facing cluster.'),
  Node(id: 'cam_tf_60', name: 'TF Camera 60°', kind: NodeKind.camera, model: 'TF · 60°', pos: Offset(0.0, 0.17), mount: 'Windshield, forward-facing cluster.'),
  Node(id: 'cam_tf_30', name: 'TF Camera 30°', kind: NodeKind.camera, model: 'TF · 30°', pos: Offset(0.30, 0.20), mount: 'Windshield, forward-facing cluster.'),
  Node(id: 'cam_roof_frt', name: 'FRT Inside Roof', kind: NodeKind.camera, model: 'Inside roof · 110°', pos: Offset(-0.22, 0.40), mount: 'Cabin ceiling, front.'),
  Node(id: 'cam_roof_rr', name: 'RR Inside Roof', kind: NodeKind.camera, model: 'Inside roof · 110°', pos: Offset(0.22, 0.60), mount: 'Cabin ceiling, rear.'),
  Node(id: 'cam_rear', name: 'Rear Camera', kind: NodeKind.camera, model: 'Rear · 60°', pos: Offset(0.0, 0.99), mount: 'Rear fascia.'),
  Node(id: 'cam_lh_frt', name: 'Side LH FRT', kind: NodeKind.camera, model: 'Side · 110°', pos: Offset(-0.86, 0.30), mount: 'Left flank, forward.'),
  Node(id: 'cam_lh_rr', name: 'Side LH RR', kind: NodeKind.camera, model: 'Side · 110°', pos: Offset(-0.86, 0.66), mount: 'Left flank, aft.'),
  Node(id: 'cam_rh_frt', name: 'Side RH FRT', kind: NodeKind.camera, model: 'Side · 110°', pos: Offset(0.86, 0.30), mount: 'Right flank, forward.'),
  Node(id: 'cam_rh_rr', name: 'Side RH RR', kind: NodeKind.camera, model: 'Side · 110°', pos: Offset(0.86, 0.66), mount: 'Right flank, aft.'),
];

/// The KETI TSN backbone. **Not on the a2z sheets** -- the sheets run every sensor straight into
/// an ACU port. These three switches are what this project inserts into that harness, and they
/// are drawn in a different colour and listed separately so the two are never read as one
/// document. Two front switches and one rear give the redundant pair of paths the reconfiguration
/// demo needs: lose one and the schedule moves the traffic onto the other.
const tsnNodes = <Node>[
  Node(
    id: 'tsn_fa',
    name: 'TSN-F A',
    ko: '전방 스위치 A',
    kind: NodeKind.tsn,
    model: 'LAN9692 · front, path 1',
    pos: Offset(0.34, 0.26),
    mount: 'Front compartment, right. Aggregates the forward sensors and carries path 1 aft.',
  ),
  Node(
    id: 'tsn_fb',
    name: 'TSN-F B',
    ko: '전방 스위치 B',
    kind: NodeKind.tsn,
    model: 'LAN9692 · front, path 2',
    pos: Offset(-0.34, 0.26),
    mount: 'Front compartment, left. The redundant half of the front pair, carrying path 2 aft.',
  ),
  Node(
    id: 'tsn_r',
    name: 'TSN-R',
    ko: '후방 스위치',
    kind: NodeKind.tsn,
    model: 'LAN9692 · centre',
    pos: Offset(0.0, 0.55),
    mount: 'Mid-cabin, just aft of centre. Pulled forward off the rear bulkhead so both paths '
        'run about the same length and the trunk to ACU_IT is the only long run left.',
  ),
];

/// A trunk between two boxes of the backbone. The pair of front-to-rear runs is the whole point:
/// they are the two routes a schedule can choose between.
class Trunk {
  final String from;
  final String to;
  final String label;

  /// Which of the three inter-switch paths this run is, or null for a link that leaves the
  /// backbone.
  final int? path;

  /// True where an inline fault-injection module sits in the run. Those are the runs the tablet
  /// can cut: the module opens a relay and the switches have to reschedule around it.
  final bool injector;

  /// False where the module is expected but not confirmed on the rig. Drawn as a question, not as
  /// a fact -- the same rule the sheet readings follow.
  final bool confirmed;

  const Trunk(
    this.from,
    this.to,
    this.label, {
    this.path,
    this.injector = false,
    this.confirmed = true,
  });
}

/// Three links between the three switches, each with an injection module in it, plus the run out
/// of the backbone into ACU_IT. Cutting any one of the three is the demo: the schedule moves the
/// traffic onto what is left.
const tsnTrunks = <Trunk>[
  Trunk('tsn_fa', 'tsn_r', 'Path 1 · front A to centre', path: 1, injector: true),
  Trunk('tsn_fb', 'tsn_r', 'Path 2 · front B to centre', path: 2, injector: true),
  Trunk('tsn_fa', 'tsn_fb', 'Path 3 · front cross-link',
      path: 3, injector: true, confirmed: false),
  Trunk('tsn_r', 'acu_it', 'Centre switch to ACU_IT'),
];

const tsnNote =
    'The three switches and the three links between them are the KETI insertion, not a reading of '
    'the a2z sheets. On the sheets every sensor runs straight into an ACU port; here the forward '
    'sensors are aggregated by the front pair and carried on to the centre switch, and every '
    'inter-switch link has an inline injection module the tablet can open. Cutting one is a '
    'reroute, not a lost sensor -- which is the whole point of the exercise. The module on the '
    'A-to-B cross-link is not confirmed on the rig, so it is drawn as a question.';

List<Node> get allNodes => [...lidarNodes, ...ecuNodes, ...tsnNodes, ...cameraNodes];

/// A name that fits a strip cell. The sheet names are descriptive sentences ("Side LH FRT
/// Camera (110°)"); ellipsising them cuts off the part that says which one it is.
String shortName(String id) => switch (id) {
      'cam_tf_110' => 'TF 110°',
      'cam_tf_60' => 'TF 60°',
      'cam_tf_30' => 'TF 30°',
      'cam_roof_frt' => 'Roof FRT',
      'cam_roof_rr' => 'Roof RR',
      'cam_rear' => 'Rear',
      'cam_lh_frt' => 'LH FRT',
      'cam_lh_rr' => 'LH RR',
      'cam_rh_frt' => 'RH FRT',
      'cam_rh_rr' => 'RH RR',
      _ => nodeById(id)?.name ?? id,
    };

Node? nodeById(String id) {
  for (final n in allNodes) {
    if (n.id == id) return n;
  }
  return null;
}

// ---------------------------------------------------------------------------
// ACU_IT: three connectors, ten labelled ports
// ---------------------------------------------------------------------------

class AcuConnector {
  final String id;
  final String title;
  final String partNumber;
  final int cavities;
  final String note;

  const AcuConnector({
    required this.id,
    required this.title,
    required this.partNumber,
    required this.cavities,
    required this.note,
  });
}

const acuItConnectors = <AcuConnector>[
  AcuConnector(
    id: '0',
    title: 'Connector 0 · ACU1_ETH_LIDAR_F_R',
    partNumber: 'TE 2307961-9',
    cavities: 4,
    note: 'Four cavities EH01-EH04, numbered 1-4 right to left on the drawing. The sheet labels '
        'only two of them; EH02/EH04 carry no port label.',
  ),
  AcuConnector(
    id: '1',
    title: 'Connector 1',
    partNumber: '4-way, 2 pins per port',
    cavities: 4,
    note: 'Top pair is the 10GBASE-T1 link (10GB-T1_P / 10GB-T1_N), bottom pair 1000BASE-T1. '
        'Seen from the front, the left pin of each port is the differential positive.',
  ),
  AcuConnector(
    id: '2',
    title: 'Connector 2',
    partNumber: '4-way, 2 pins per port',
    cavities: 4,
    note: 'Both pairs 1000BASE-T1 (1000B-T1_P / 1000B-T1_N). Same left-is-positive rule.',
  ),
];

/// One labelled port on the ACU_IT board edge. [row]/[col] place it on the connector face
/// exactly as the photograph shows it: ports 1 and 2 on the top row, 3 and 4 below.
class AcuPort {
  final String id;
  final String connectorId;
  final int row;
  final int col;
  final String label;

  /// What fits in a ten-across strip. The sheet labels are Korean phrases; truncating them with
  /// an ellipsis loses the word that distinguishes front from rear, which is the whole content.
  final String short;
  final String? peerNodeId;
  final Sourced<String> speed;
  final bool used;
  final String? note;

  const AcuPort({
    required this.id,
    required this.connectorId,
    required this.row,
    required this.col,
    required this.label,
    required this.short,
    required this.speed,
    this.peerNodeId,
    this.used = true,
    this.note,
  });
}

const _t1Unstated = Sourced<String>(
  '1000BASE-T1',
  from: Provenance.inferred,
  note: 'The sheets never state a LiDAR link rate. Both LiDAR connectors carry a single '
      'differential pair (D1/D2), so the link is a BASE-T1 variant; 1000BASE-T1 is the '
      'family default for this sensor class, not a sheet reading.',
);

const acuItPorts = <AcuPort>[
  AcuPort(
    id: '0-1',
    connectorId: '0',
    row: 0,
    col: 0,
    label: 'FalconK 전방',
    short: 'Falcon K1 F',
    peerNodeId: 'fk_front',
    speed: _t1Unstated,
  ),
  AcuPort(
    id: '0-2',
    connectorId: '0',
    row: 0,
    col: 1,
    label: '허밍버드 후방',
    short: 'Hummingbird R',
    peerNodeId: 'hb_rear',
    speed: _t1Unstated,
  ),
  AcuPort(
    id: '1-1',
    connectorId: '1',
    row: 0,
    col: 0,
    label: 'ACU_NO 10G',
    short: 'ACU_NO 10G',
    peerNodeId: 'acu_no',
    speed: Sourced('10GBASE-T1'),
  ),
  AcuPort(
    id: '1-2',
    connectorId: '1',
    row: 0,
    col: 1,
    label: 'ACU_NO 1G',
    short: 'ACU_NO 1G',
    peerNodeId: 'acu_no',
    speed: Sourced('1000BASE-T1'),
  ),
  AcuPort(
    id: '1-3',
    connectorId: '1',
    row: 1,
    col: 0,
    label: '미사용',
    short: 'Unused',
    used: false,
    speed: Sourced('1000BASE-T1',
        from: Provenance.inferred,
        note: 'Wired to the 1000BASE-T1 pair of Connector 1 but marked unused on the sheet.'),
  ),
  AcuPort(
    id: '1-4',
    connectorId: '1',
    row: 1,
    col: 1,
    label: 'TCU_S',
    short: 'TCU_S',
    peerNodeId: 'tcu_s',
    speed: Sourced('1000BASE-T1'),
  ),
  AcuPort(
    id: '2-1',
    connectorId: '2',
    row: 0,
    col: 0,
    label: 'DISPLAY',
    short: 'DISPLAY',
    peerNodeId: 'display',
    speed: Sourced('1000BASE-T1'),
  ),
  AcuPort(
    id: '2-2',
    connectorId: '2',
    row: 0,
    col: 1,
    label: 'TCU_M',
    short: 'TCU_M',
    peerNodeId: 'tcu_m',
    speed: Sourced('1000BASE-T1'),
  ),
  AcuPort(
    id: '2-3',
    connectorId: '2',
    row: 1,
    col: 0,
    label: 'FalconK 후방',
    short: 'Falcon K1 R',
    peerNodeId: 'fk_rear',
    speed: _t1Unstated,
    note: 'Superseded revision of the same photo reads "허밍버드 전방" here.',
  ),
  AcuPort(
    id: '2-4',
    connectorId: '2',
    row: 1,
    col: 1,
    label: '허밍버드 전방',
    short: 'Hummingbird F',
    peerNodeId: 'hb_front',
    speed: _t1Unstated,
    note: 'Superseded revision of the same photo reads "허밍버드 후방" here.',
  ),
];

AcuPort? portById(String id) {
  for (final p in acuItPorts) {
    if (p.id == id) return p;
  }
  return null;
}

/// Why this console prints one of the two revisions and not the other.
const acuItRevisionNote =
    'Sheet 1 carries the port-label photo twice. The later copy reads Port 2-3 "허밍버드 전방" '
    'and Port 2-4 "허밍버드 후방" — which names 허밍버드 후방 twice and never names FalconK 후방, '
    'leaving one of the four LiDARs unconnected. The earlier copy maps all four LiDARs to '
    'distinct ports and is the one used here. Both are shown side by side under Sheets.';

// ---------------------------------------------------------------------------
// ACU_NO: five dual FAKRA jacks and the LAN connector
// ---------------------------------------------------------------------------

class CamJack {
  final String id;
  final int dot; // faceplate marker colour, 0xAARRGGBB
  final String dotName;
  final List<String> feedNodeIds;
  final String? altRevision;

  const CamJack({
    required this.id,
    required this.dot,
    required this.dotName,
    required this.feedNodeIds,
    this.altRevision,
  });
}

const acuNoJacks = <CamJack>[
  CamJack(id: 'CAM 1', dot: 0xFFFFFFFF, dotName: 'white', feedNodeIds: ['cam_roof_frt', 'cam_roof_rr']),
  CamJack(
    id: 'CAM 2',
    dot: 0xFFE53935,
    dotName: 'red',
    feedNodeIds: ['cam_rear', 'cam_lh_rr'],
    altRevision: 'Earlier revision gives the rear camera 110°, not 60°.',
  ),
  CamJack(id: 'CAM 3', dot: 0xFFFDD835, dotName: 'yellow', feedNodeIds: ['cam_lh_frt', 'cam_rh_rr']),
  CamJack(
    id: 'CAM 4',
    dot: 0xFF1E88E5,
    dotName: 'blue',
    feedNodeIds: ['cam_rh_frt', 'cam_tf_110'],
    altRevision: 'Earlier revision names this second feed "TF Left Camera (60°)".',
  ),
  CamJack(
    id: 'CAM 5',
    dot: 0xFF9E9E9E,
    dotName: 'grey',
    feedNodeIds: ['cam_tf_60', 'cam_tf_30'],
    altRevision: 'Earlier revision names these "TF Right Camera (60°)" and "TF Center Camera (110°)".',
  ),
];

class AcuNoLink {
  final String label;
  final String speed;
  final String? note;
  final String? peerNodeId;

  const AcuNoLink(this.label, this.speed, {this.note, this.peerNodeId});
}

const acuNoLan = <AcuNoLink>[
  AcuNoLink('To TCU-M [Orin B]', '1G', peerNodeId: 'tcu_m'),
  AcuNoLink('To TCU-M [Orin A]', '1G',
      peerNodeId: 'tcu_m',
      note: 'One sheet revision crosses this out: 커넥터에서 핀 분리 (1G 예비) — pin removed at the '
          'connector, held as a 1G spare. The later revision drops the mark without saying it '
          'was reinstated.'),
  AcuNoLink('To ACU_IT', '10G', peerNodeId: 'acu_it'),
  AcuNoLink('To ACU_IT', '1G', peerNodeId: 'acu_it'),
];

const fakraJackNote =
    'The camera jacks are KET FAKRA straight dual jacks (KR22101-0□). Housing colour is the '
    'coding key: B white, C blue, D bordeaux violet, E green, I beige, K curry, L carmine red, '
    'Z water blue. The faceplate dots above each jack repeat that coding so a harness cannot be '
    'seated one position across.';

// ---------------------------------------------------------------------------
// Pinouts
// ---------------------------------------------------------------------------

class PinRow {
  final String cav;
  final String csa;
  final String colour;
  final String signal;
  final String comment;

  const PinRow(this.cav, this.csa, this.colour, this.signal, [this.comment = '']);
}

class Pinout {
  final String id;
  final String title;
  final String connector;
  final String? refImage;
  final List<PinRow> rows;
  final String note;

  const Pinout({
    required this.id,
    required this.title,
    required this.connector,
    required this.rows,
    required this.note,
    this.refImage,
  });
}

const pinouts = <Pinout>[
  Pinout(
    id: 'falcon',
    title: 'Falcon K1 · roof LiDAR',
    connector: 'CN1 · TE-2387380',
    refImage: 'assets/ref/fk_cn1_table.png',
    rows: [
      PinRow('D1', 'Dacar647_4 / FORCE QTJP12GD100-B-1G 2×0.13', 'GREEN', 'Ethernet_D−'),
      PinRow('D2', 'Dacar647_4 / FORCE QTJP12GD100-B-1G 2×0.13', 'WHITE', 'Ethernet_D+'),
      PinRow('SHELL', '—', 'BRAIDING', 'GND'),
      PinRow('1', 'SP2202149 (2×0.5)', 'BLACK', 'Power_−', 'Black banana plug'),
      PinRow('4', 'SP2202149 (2×0.5)', 'RED', 'Power_+', 'Red banana plug'),
      PinRow('3', '0.35', 'GRAY', '—'),
      PinRow('2', 'Empty', '—', '—', 'Cavity plug 2208113-2'),
      PinRow('5', 'Empty', '—', '—', 'Cavity plug 2208113-2'),
      PinRow('6', 'Empty', '—', '—', 'Cavity plug 2208113-2'),
    ],
    note: 'Cavities 2, 5 and 6 are plugged, not spare — a cavity plug is fitted, so the harness '
        'cannot later be populated without pulling it.',
  ),
  Pinout(
    id: 'hummingbird',
    title: 'Hummingbird · front & rear LiDAR',
    connector: 'CN1 · AMP HYBRID WP LIDAR CODE A · TE 2387380-1 (LIDAR_FRNT)',
    refImage: 'assets/ref/hb_pins.png',
    rows: [
      PinRow('1', '—', '—', 'Power interface (ground)'),
      PinRow('2', '—', '—', 'Empty pin'),
      PinRow('3', '—', '—', 'Unused pin'),
      PinRow('4', '—', '—', 'Power supply interface (positive)'),
      PinRow('5', '—', '—', 'CAN High'),
      PinRow('6', '—', '—', 'CAN Low'),
      PinRow('D1', '—', '—', 'Ethernet signal receive port'),
      PinRow('D2', '—', '—', 'Ethernet signal transmit port'),
    ],
    note: 'Same TE 2387380 connector family as the Falcon K1, but the two sheets describe D1/D2 '
        'differently: here as receive/transmit, on the Falcon sheet as D−/D+. A single '
        'differential pair cannot be both, so one of the two descriptions is loose. Wire by the '
        'Falcon table (D1 = D−, D2 = D+) and confirm on the bench before crimping.',
  ),
  Pinout(
    id: 'acu_it_pairs',
    title: 'ACU_IT · Connector 1 & 2 pairs',
    connector: 'Emts, 4-way',
    refImage: 'assets/ref/acu_it_pairs.png',
    rows: [
      PinRow('C1 · 1-1 / 1-2', '—', '—', '10GB-T1_P / 10GB-T1_N', 'Connector 1, top row'),
      PinRow('C1 · 3-1 / 3-2', '—', '—', '1000B-T1_N / 1000B-T1_P', 'Connector 1, bottom row'),
      PinRow('C2 · 2-1 / 2-2', '—', '—', '1000B-T1_P / 1000B-T1_N', 'Connector 2, top row'),
      PinRow('C2 · 3-1 / 3-2', '—', '—', '1000B-T1_N / 1000B-T1_P', 'Connector 2, bottom row'),
    ],
    note: 'Sheet note, verbatim: 커넥터를 전면에서 봤을 때, 각 포트의 왼쪽은 Differential Positive '
        '이며, 오른쪽은 Negative. Viewed from the front — so the mating harness is mirrored.',
  ),
  Pinout(
    id: 'side',
    title: 'Side LiDAR · LH & RH',
    connector: 'Coding-A 1897726-2 (10-way) / 1897725-2 (10-way header) + HSD plug',
    refImage: 'assets/ref/side_conn_1897726.png',
    rows: [
      PinRow('1897726-2', '—', '—', '10-way coding-A receptacle', 'Body 28.0 × 15.8 mm'),
      PinRow('1897725-2', '—', '—', '10-way coding-A header', 'Body 24.8 × 12.6 mm'),
      PinRow('HSD', '—', 'water blue', 'Ethernet data', 'Shielded quad plug, sheet shows no pin table'),
    ],
    note: 'Sheet 4 gives outline drawings and part numbers only. No signal assignment is printed '
        'for the side LiDARs, and no ACU_IT port is labelled for them — where these two units '
        'terminate is not answered by this document set.',
  ),
];

// ---------------------------------------------------------------------------
// Reference sheets, as shipped
// ---------------------------------------------------------------------------

class Sheet {
  final String title;
  final String asset;
  final String caption;
  final bool superseded;

  const Sheet(this.title, this.asset, this.caption, {this.superseded = false});
}

const sheetGroups = <String, List<Sheet>>{
  'ACU_IT': [
    Sheet('Port labels', 'assets/ref/acu_it_ports.png',
        'ACU_IT 연결구성. The revision this console follows: all four LiDARs on distinct ports.'),
    Sheet('Port labels · other revision', 'assets/ref/acu_it_ports_altrev.png',
        'The same photo later in the sheet, with 허밍버드 후방 on two ports and FalconK 후방 on none.',
        superseded: true),
    Sheet('Case', 'assets/ref/acu_it_case.png', 'TOTAL I/O, USB-C, LAN 1, LAN 2 (red), LAN 3 (blue).'),
    Sheet('Differential pairs', 'assets/ref/acu_it_pairs.png',
        'Connector 1 and 2 pin map. Left pin of each port is positive, viewed from the front.'),
    Sheet('LiDAR connector', 'assets/ref/acu_it_lidar_conn.png',
        'ACU1_ETH_LIDAR_F_R, TE 2307961-9. Cavities EH01-EH04.'),
  ],
  'Hummingbird': [
    Sheet('Mounting', 'assets/ref/hb_mount.png', 'Front and rear bracket plates.'),
    Sheet('Connector', 'assets/ref/hb_conn.png', 'CN1 face: 6 low-speed cavities plus the D1/D2 data port.'),
    Sheet('Pin definitions', 'assets/ref/hb_pins.png', 'Power, CAN and the Ethernet pair.'),
    Sheet('Connector drawing', 'assets/ref/hb_conn_dwg.png', 'AMP HYBRID WP LIDAR CODE A · 2387380-1.'),
  ],
  'Falcon K1': [
    Sheet('Mounting', 'assets/ref/fk_mount.png', 'Roof front and rear. Only the front unit shows a harness drop.'),
    Sheet('CN1 table', 'assets/ref/fk_cn1_table.png', 'Full wire table: gauge, colour, signal, cavity plugs.'),
    Sheet('Connector', 'assets/ref/fk_conn.png', 'Recessed CN1 in the roof panel.'),
  ],
  'Side LiDAR': [
    Sheet('Unit', 'assets/ref/side_lidar.png', 'Spinning unit on a pigtail.'),
    Sheet('Coding-A 1897726-2', 'assets/ref/side_conn_1897726.png', '10-way receptacle outline.'),
    Sheet('Coding-A 1897725-2', 'assets/ref/side_conn_1897725.png', '10-way header outline.'),
    Sheet('HSD plug', 'assets/ref/side_hsd_plug.png', 'Water-blue shielded data plug.'),
  ],
  'ACU_NO': [
    Sheet('Camera map', 'assets/ref/acu_no_cams.png', 'Ten feeds over CAM 1-5, plus the four LAN links.'),
    Sheet('Camera map · other revision', 'assets/ref/acu_no_cams_altrev.png',
        'Earlier naming (TF Left / Right / Center) and the crossed-out Orin A link.',
        superseded: true),
    Sheet('Case', 'assets/ref/acu_no_case.png', 'Green faceplate: USB-C, CAM 1-5, USB-C, LAN, TOTAL I/O.'),
    Sheet('Faceplate', 'assets/ref/acu_no_faceplate.png', 'Cut-out drawing with the jack colour dots.'),
    Sheet('FAKRA dual jack', 'assets/ref/fakra_dual_jack.png', 'KET KR22101 coding table.'),
  ],
};
