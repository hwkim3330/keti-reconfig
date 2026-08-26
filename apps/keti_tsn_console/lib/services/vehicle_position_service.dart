import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// Why the console has no position, when it has none.
///
/// A single nullable position cannot distinguish "permission refused" from "indoors with no
/// sky view", and those need different actions from whoever is standing in front of the
/// tablet. The panel says which one it is.
enum PositionStatus { idle, denied, serviceOff, waiting, fixed, failed }

class VehiclePosition {
  const VehiclePosition({
    required this.status,
    this.position,
    this.detail = '',
  });

  final PositionStatus status;
  final Position? position;
  final String detail;

  bool get hasFix => status == PositionStatus.fixed && position != null;
}

/// The vehicle's own position, for the navigation view.
///
/// Kept separate from the reconfiguration state on purpose: the TSN rig works with no fix at
/// all, so a missing position must never look like a fault on the network panel.
class VehiclePositionService {
  final _positions = StreamController<VehiclePosition>.broadcast();
  StreamSubscription<Position>? _subscription;
  var _latest = const VehiclePosition(status: PositionStatus.idle);

  Stream<VehiclePosition> get positions => _positions.stream;
  VehiclePosition get latest => _latest;

  void _emit(VehiclePosition next) {
    _latest = next;
    if (!_positions.isClosed) _positions.add(next);
  }

  Future<void> start() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _emit(const VehiclePosition(
        status: PositionStatus.serviceOff,
        detail: 'Location is switched off on the tablet',
      ));
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _emit(const VehiclePosition(
        status: PositionStatus.denied,
        detail: 'Location permission not granted',
      ));
      return;
    }

    _emit(const VehiclePosition(
      status: PositionStatus.waiting,
      detail: 'Waiting for a fix',
    ));

    // A last known fix fills the panel immediately instead of leaving it blank for the
    // half-minute a cold start can take indoors. It is labelled as a fix because that is
    // what it is -- an older one.
    final cached = await Geolocator.getLastKnownPosition();
    if (cached != null) {
      _emit(VehiclePosition(
        status: PositionStatus.fixed,
        position: cached,
        detail: 'last known',
      ));
    }

    await _subscription?.cancel();
    _subscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        // The vehicle is either parked on a bench or moving slowly on a test route; metre
        // level updates are plenty and keep the radio quiet.
        distanceFilter: 2,
      ),
    ).listen(
      (position) => _emit(
        VehiclePosition(status: PositionStatus.fixed, position: position),
      ),
      onError: (Object error) => _emit(
        VehiclePosition(status: PositionStatus.failed, detail: '$error'),
      ),
    );
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _positions.close();
  }
}
