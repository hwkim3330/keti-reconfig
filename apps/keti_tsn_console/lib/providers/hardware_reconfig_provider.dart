import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/hardware_reconfig_service.dart';

final hardwareReconfigServiceProvider = Provider<HardwareReconfigService>((
  ref,
) {
  final service = HardwareReconfigService(directBle: true);
  service.connect();
  ref.onDispose(service.dispose);
  return service;
});

final hardwareReconfigProvider = StreamProvider<HardwareReconfigState>((ref) {
  return ref.watch(hardwareReconfigServiceProvider).states;
});
