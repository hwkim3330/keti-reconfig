import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'screens/console_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const ProviderScope(child: KetiTsnReconfigApp()));
}

class KetiTsnReconfigApp extends StatelessWidget {
  const KetiTsnReconfigApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KETI TSN Reconfig',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const ConsoleShell(),
    );
  }
}
