import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/fault_data.dart';
import '../core/constants.dart';
import '../services/fault_stream_service.dart';
import 'viewer_service_provider.dart';
import 'hardware_reconfig_provider.dart';
import '../services/hardware_reconfig_service.dart';

class FaultNotifier extends StateNotifier<Map<int, FaultData>> {
  FaultNotifier(this.ref) : super({}) {
    _initializeFaultStream();
    ref.listen<AsyncValue<HardwareReconfigState>>(hardwareReconfigProvider, (
      previous,
      next,
    ) {
      next.whenData(_applyHardwareState);
    });
  }

  final Ref ref;
  final FaultStreamService _faultStreamService = FaultStreamService();
  Map<String, String> _lastHardwareChannels = const {};
  final Map<String, String> _hardwareTargetOverrides = {};

  void _initializeFaultStream() {
    _faultStreamService.startListening((event) {
      if (event.type == FaultEventType.add && event.faultData != null) {
        addFault(event.faultData!);
      } else if (event.type == FaultEventType.remove) {
        removeFault(event.id);
      }
    });
  }

  void addFault(FaultData fault) {
    state = {...state, fault.id: fault};

    // Update viewer for this target
    _updateViewerForTarget(fault.target);
  }

  void removeFault(int id) {
    final fault = state[id];
    if (fault == null) return;

    final target = fault.target;
    final newState = Map<int, FaultData>.from(state);
    newState.remove(id);
    state = newState;

    // Update viewer for this target
    _updateViewerForTarget(target);
  }

  void clearAll({bool notifyHardware = true}) {
    state = {};
    ref.read(viewerServiceProvider).clearFaultAlerts();
    if (notifyHardware) {
      ref.read(hardwareReconfigServiceProvider).recover();
    }
  }

  void _applyHardwareState(HardwareReconfigState hardware) {
    if (!hardware.connected) return;
    final unchanged =
        _lastHardwareChannels.length == hardware.channels.length &&
        hardware.channels.entries.every(
          (entry) => _lastHardwareChannels[entry.key] == entry.value,
        );
    if (unchanged) return;
    _lastHardwareChannels = Map.unmodifiable(hardware.channels);
    clearAll(notifyHardware: false);
    var id = 500;
    for (final entry in hardware.channels.entries) {
      if (entry.value == 'NORMAL') continue;
      final target = switch (entry.key) {
        'tsn_front_a' => _hardwareTargetOverrides[entry.key] ?? 'Path1Route',
        'tsn_front_b' => _hardwareTargetOverrides[entry.key] ?? 'Path2Route',
        'tsn_rear' => _hardwareTargetOverrides[entry.key] ?? 'Path3Route',
        'lidar_fl' => 'FrontLeftLidar',
        'lidar_fr' => 'FrontRightLidar',
        'lidar_rl' || 'lidar_rr' => 'RearCenterLidar',
        'gnss' => 'TCU',
        'camera' => 'FrontCenterCamera',
        _ => 'ACU_IT',
      };
      addFault(
        FaultData(
          id: id++,
          target: target,
          severity: entry.value == 'DEGRADED' ? 1 : 2,
          faultType: '${entry.key} ${entry.value.toLowerCase()}',
          cause: 'ESP fault-injection controller confirmed ${entry.value}.',
          countermeasures: [
            'Autoware ${hardware.mode} stack selected',
            hardware.mode == 'MRM'
                ? 'Execute minimum-risk stop and hazard request'
                : 'Validate localization confidence and TSN path',
          ],
        ),
      );
    }
  }

  @override
  void dispose() {
    _faultStreamService.dispose();
    super.dispose();
  }

  /// Update 3D viewer alert for a specific target
  /// Shows the highest severity if multiple faults exist for the same target
  void _updateViewerForTarget(String target) {
    final service = ref.read(viewerServiceProvider);

    // Find all faults for this target
    final targetFaults = state.values.where((f) => f.target == target).toList();

    if (targetFaults.isEmpty) {
      // No more faults for this target - hide alert
      service.hideFaultAlert(target);
      if (state.isEmpty) {
        service.stopAlert();
      }
    } else {
      // Show alert with highest severity
      final maxSeverity = targetFaults
          .map((f) => f.severity)
          .reduce((a, b) => a > b ? a : b);

      final config = errorHotspotConfigs[target];
      if (config != null) {
        service.showFaultAlert(target, maxSeverity, config);
      }
    }
  }

  /// Get all faults for a specific target
  List<FaultData> getFaultsByTarget(String target) {
    return state.values.where((f) => f.target == target).toList();
  }

  /// Get a specific fault by id
  FaultData? getFault(int id) => state[id];

  /// Get the first fault for a target
  /// TODO: 여러 개의 fault 가져오는 로직 추가
  FaultData? getFaultByTarget(String target) {
    return state.values.firstWhere(
      (f) => f.target == target,
      orElse: () => FaultData(
        id: 0,
        target: '',
        severity: 0,
        faultType: '',
        cause: '',
        countermeasures: [],
      ),
    );
  }

  void simulateFault() {
    clearAll();
    final testFault1 = FaultData(
      id: 1,
      target: 'RearZC', // Material name이 곧 target
      severity: 2,
      faultType: '시간 동기 상실 (Loss of Time Sync)',
      cause: 'GM  고장 또는 PTP 메시지 전파 경로 상 링크 단절',
      countermeasures: [
        'GM Failover: Secondary GM이 BMCA에 따라 새로운 GM 역할 수행',
        'PTP용 FRER 설정',
      ],
    );
    addFault(testFault1);

    final testFault2 = FaultData(
      id: 2,
      target: 'connection-FrontCenterLidar-FrontZC',
      severity: 1,
      faultType: '간헐적 링크 불안정이 지속적으로 발생해 센서 확보 불가',
      cause: 'FC-Lidar와 ZC 사이 링크의 간헐적 불안정',
      countermeasures: [
        '단일 경로 운용(Fail-Operation): 안정적인 단일 경로로만 트래픽 발생',
        '무중단(Hitless) 이중화 중지',
        '하지만, 자율주행 기능은 정상 수행',
      ],
    );
    addFault(testFault2);
  }

  void applyScenario(String scenarioId) {
    clearAll(notifyHardware: false);
    _hardwareTargetOverrides.clear();
    switch (scenarioId) {
      case 'switchA':
        _hardwareTargetOverrides['tsn_front_a'] = 'FrontSwitchA';
      case 'switchB':
        _hardwareTargetOverrides['tsn_front_b'] = 'FrontSwitchB';
      case 'switchRear':
        _hardwareTargetOverrides['tsn_rear'] = 'RearSwitch';
    }
    _sendScenarioToHardware(scenarioId);
    final faults = switch (scenarioId) {
      'triple' => <FaultData>[],
      'cameraLost' => [
        const FaultData(
          id: 11,
          target: 'FrontCenterCamera',
          severity: 2,
          faultType: 'Camera unavailable',
          cause: '전방 카메라 신뢰도 상실. LiDAR+GNSS 기반 Autoware stack으로 전환',
          countermeasures: [
            'Localization: NDT LiDAR + GNSS',
            'Planning: lanelet route 유지',
            'Control: speed cap 45km/h',
          ],
        ),
      ],
      'gnssDenied' => [
        const FaultData(
          id: 31,
          target: 'TCU',
          severity: 1,
          faultType: 'GNSS denied',
          cause: '터널/도심 협곡으로 GNSS 품질 저하. LiDAR+Camera 위치 추정으로 전환',
          countermeasures: [
            'Localization: LiDAR odometry + visual lane',
            'Planning: local map confidence',
            'Control: lateral smoothing',
          ],
        ),
      ],
      'lidarDegraded' => [
        const FaultData(
          id: 21,
          target: 'FrontCenterLidar',
          severity: 1,
          faultType: 'LiDAR degraded',
          cause: '비/안개/오염으로 point cloud 품질 저하. GNSS+Camera 기반 저속 stack으로 전환',
          countermeasures: [
            'Localization: GNSS + camera lane',
            'Perception: radar fallback',
            'Control: speed cap 35km/h',
          ],
        ),
      ],
      'lidarFrontLeft' => [
        const FaultData(
          id: 81,
          target: 'FrontLeftLidar',
          severity: 1,
          faultType: 'Front-left LiDAR degraded',
          cause: '전방 좌측 LiDAR 오염/가림. 중심/우측 LiDAR와 GNSS+Camera stack 유지',
          countermeasures: [
            'Reduce left point-cloud confidence',
            'Keep NDT with remaining LiDARs',
            'No left lane change',
          ],
        ),
      ],
      'lidarFrontCenter' => [
        const FaultData(
          id: 82,
          target: 'FrontCenterLidar',
          severity: 2,
          faultType: 'Front-center LiDAR unavailable',
          cause: '전방 중심 LiDAR 상실. 좌/우 LiDAR와 GNSS+Camera 기반 degraded stack',
          countermeasures: [
            'Split front LiDAR fusion',
            'Increase camera lane weight',
            'Speed cap 35km/h',
          ],
        ),
      ],
      'lidarFrontRight' => [
        const FaultData(
          id: 83,
          target: 'FrontRightLidar',
          severity: 1,
          faultType: 'Front-right LiDAR degraded',
          cause: '전방 우측 LiDAR 품질 저하. 중심/좌측 LiDAR와 GNSS+Camera stack 유지',
          countermeasures: [
            'Reduce right point-cloud confidence',
            'Keep NDT with remaining LiDARs',
            'No right lane change',
          ],
        ),
      ],
      'lidarRearCenter' => [
        const FaultData(
          id: 84,
          target: 'RearCenterLidar',
          severity: 1,
          faultType: 'Rear-center LiDAR degraded',
          cause: '후방 LiDAR 품질 저하. 후측방 판단 제한, 전방 주행 stack 유지',
          countermeasures: [
            'Rear object confidence down',
            'Disable reverse assist',
            'MRM standby',
          ],
        ),
      ],
      'gnssDrift' => [
        const FaultData(
          id: 91,
          target: 'TCU',
          severity: 1,
          faultType: 'GNSS drift',
          cause: '도심 협곡/터널 진입으로 GNSS 측위값과 오도미터 이동거리 불일치',
          countermeasures: [
            'GNSS fusion weight 0',
            'LiDAR + Camera localization',
            'Localization discontinuity check',
          ],
        ),
      ],
      'gnssOnly' => [
        const FaultData(
          id: 92,
          target: 'FrontCenterLidar',
          severity: 2,
          faultType: 'LiDAR + Camera unavailable',
          cause: '전방 인지 센서 동시 제한. GNSS 단일 기반 제한 운행 또는 MRM 후보',
          countermeasures: [
            'GNSS hold',
            'No autonomous lane change',
            'Prepare MRM safe stop',
          ],
        ),
        const FaultData(
          id: 93,
          target: 'FrontCenterCamera',
          severity: 2,
          faultType: 'Camera unavailable',
          cause: 'Camera visual odometry 사용 불가',
          countermeasures: [
            'Disable visual lane localization',
            'Reduce control authority',
          ],
        ),
      ],
      'tsnSyncLost' => [
        const FaultData(
          id: 101,
          target: 'FrontZC',
          severity: 2,
          faultType: 'TSN time sync lost',
          cause: 'Front zonal gateway GM/PTP 동기 상실',
          countermeasures: [
            'BMCA failover',
            'FRER redundant path',
            'DetNet jitter validation',
          ],
        ),
      ],
      'frerPathLost' => [
        const FaultData(
          id: 102,
          target: 'Path1',
          severity: 1,
          faultType: 'FRER path A lost',
          cause: '전방 Ethernet 링크 A 단절, 복제 프레임 제거 경로 재구성',
          countermeasures: [
            'Path B active',
            'Hitless recovery check',
            'Latency max validation',
          ],
        ),
      ],
      'zgFrontIsolated' => [
        const FaultData(
          id: 103,
          target: 'FrontZC',
          severity: 2,
          faultType: 'ZG-F isolated',
          cause: '전방 Zonal Gateway 통신 고립. 전방 센서 수집 경로 재구성 필요',
          countermeasures: [
            'Route sensors through backup gateway',
            'Camera/LiDAR confidence down',
            'MRM standby',
          ],
        ),
      ],
      'localizationDelayed' => [
        const FaultData(
          id: 111,
          target: 'ACU_IT',
          severity: 1,
          faultType: 'Localization node delayed',
          cause: 'Autoware localization pipeline callback 지연 증가',
          countermeasures: [
            'Resource scheduling',
            'Pipeline watchdog',
            'Mode switch time validation',
          ],
        ),
      ],
      'compoundRain' => [
        const FaultData(
          id: 121,
          target: 'FrontCenterLidar',
          severity: 2,
          faultType: 'LiDAR confidence drop',
          cause: '우천/안개 환경에서 point cloud 품질 저하',
          countermeasures: ['Camera/GNSS fusion increase', 'Speed cap 25km/h'],
        ),
        const FaultData(
          id: 122,
          target: 'FrontCenterCamera',
          severity: 1,
          faultType: 'Camera contrast low',
          cause: '야간/악천후로 lane confidence 감소',
          countermeasures: [
            'Perception confidence monitor',
            'MRM condition check',
          ],
        ),
      ],
      'singleLidar' => [
        const FaultData(
          id: 61,
          target: 'FrontCenterCamera',
          severity: 2,
          faultType: 'Camera + GNSS unavailable',
          cause: '카메라와 GNSS 동시 제한. LiDAR 단일 기반 최소 기능 운행',
          countermeasures: [
            'Localization: LiDAR NDT only',
            'Planning: nearest safe lane',
            'Control: crawl mode',
          ],
        ),
        const FaultData(
          id: 62,
          target: 'TCU',
          severity: 2,
          faultType: 'GNSS unavailable',
          cause: 'GNSS/통신 기반 위치 보조 불가',
          countermeasures: ['Odometry hold', 'MRM candidate search'],
        ),
      ],
      'cameraOnly' => [
        const FaultData(
          id: 71,
          target: 'FrontCenterLidar',
          severity: 2,
          faultType: 'LiDAR + GNSS unavailable',
          cause: 'LiDAR/GNSS 사용 불가. Camera 기반 임시 차선 유지 모드',
          countermeasures: [
            'Localization: visual lane only',
            'Planning: lane keep only',
            'Control: speed cap 15km/h',
          ],
        ),
        const FaultData(
          id: 72,
          target: 'TCU',
          severity: 2,
          faultType: 'GNSS unavailable',
          cause: 'GNSS 위치 보조 불가',
          countermeasures: ['No lane change', 'MRM standby'],
        ),
      ],
      'mrmStop' => [
        const FaultData(
          id: 51,
          target: 'FrontCenterCamera',
          severity: 2,
          faultType: 'Multi-sensor unavailable',
          cause: '센서 조합으로 Autoware 주행 stack 유지 불가',
          countermeasures: [
            'Autoware MRM behavior 실행',
            'Hazard signal',
            'Safe stop trajectory',
          ],
        ),
        const FaultData(
          id: 52,
          target: 'FrontCenterLidar',
          severity: 2,
          faultType: 'LiDAR unavailable',
          cause: '주요 측위 센서 상실',
          countermeasures: ['Stop line search', 'Fallback braking'],
        ),
        const FaultData(
          id: 53,
          target: 'TCU',
          severity: 2,
          faultType: 'GNSS unavailable',
          cause: '위치 보조 상실',
          countermeasures: ['Dead reckoning until stop', 'Remote telemetry'],
        ),
      ],
      _ => <FaultData>[],
    };

    for (final fault in faults) {
      addFault(fault);
    }
  }

  void _sendScenarioToHardware(String scenarioId) {
    final hardware = ref.read(hardwareReconfigServiceProvider);
    switch (scenarioId) {
      case 'triple':
        hardware.recover();
      case 'lidarFrontLeft':
        hardware.setChannel('lidar_fl', 'FAULT');
      case 'lidarFrontCenter':
        hardware.setChannel('lidar_fl', 'FAULT');
        hardware.setChannel('lidar_fr', 'FAULT');
      case 'lidarFrontRight':
        hardware.setChannel('lidar_fr', 'FAULT');
      case 'lidarRearCenter':
        hardware.setChannel('lidar_rr', 'FAULT');
      case 'gnssDrift':
        hardware.setChannel('gnss', 'DEGRADED');
      case 'gnssDenied':
        hardware.setChannel('gnss', 'FAULT');
      case 'cameraLost':
        hardware.setChannel('camera', 'FAULT');
      case 'tsnSyncLost':
        hardware.setChannel('tsn_front_a', 'DEGRADED');
      case 'frerPathLost':
        hardware.setChannel('tsn_front_a', 'FAULT');
      case 'zgFrontIsolated':
      case 'mrmStop':
        hardware.runScenario(3);
      case 'singleLidar':
        hardware.setChannel('gnss', 'FAULT');
        hardware.setChannel('camera', 'FAULT');
      case 'cameraOnly':
        hardware.setChannel('gnss', 'FAULT');
        hardware.setChannel('lidar_fl', 'FAULT');
        hardware.setChannel('lidar_fr', 'FAULT');
        hardware.setChannel('lidar_rl', 'FAULT');
        hardware.setChannel('lidar_rr', 'FAULT');
      default:
        break;
    }
  }
}

final faultProvider = StateNotifierProvider<FaultNotifier, Map<int, FaultData>>(
  (ref) {
    return FaultNotifier(ref);
  },
);
