import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/keti_link_service.dart';

final ketiLinkServiceProvider = Provider<KetiLinkService>((ref) {
  final service = KetiLinkService();
  ref.onDispose(service.dispose);
  service.start();
  return service;
});

final ketiStateProvider = StreamProvider<KetiState>((ref) {
  final service = ref.watch(ketiLinkServiceProvider);
  // The stream only carries changes, so seed it with what the service already holds --
  // otherwise the console shows nothing until the next notification happens to arrive.
  return service.states.startWith(service.state);
});

extension _SeedFirst<T> on Stream<T> {
  Stream<T> startWith(T value) async* {
    yield value;
    yield* this;
  }
}
