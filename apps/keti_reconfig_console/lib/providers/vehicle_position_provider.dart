import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/vehicle_position_service.dart';

final vehiclePositionServiceProvider = Provider<VehiclePositionService>((ref) {
  final service = VehiclePositionService();
  ref.onDispose(service.dispose);
  return service;
});

/// The vehicle's position, or the reason there isn't one.
final vehiclePositionProvider = StreamProvider<VehiclePosition>((ref) {
  final service = ref.watch(vehiclePositionServiceProvider);
  service.start();
  return service.positions;
});
