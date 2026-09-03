import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_drawer.dart';
import 'host.dart';
import 'log_sheet.dart';
import 'path_card.dart';
import 'rig.dart';
import 'theme.dart';

/// KETI rig launcher.
///
/// The tablet's home screen *is* the console. One app, because the panel it runs on is a 2 GB
/// Snapdragon 425: the older consoles put a WebView and a glTF viewer on screen at once and this
/// hardware cannot hold both. Nothing here draws a 3D scene, a chart or a web page. What it does
/// draw is the only control surface the rig actually needs -- four fault-injection modules over
/// BLE -- plus enough of a launcher that the tablet is still a tablet.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const LauncherApp());
}

class LauncherApp extends StatelessWidget {
  const LauncherApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'KETI',
        debugShowCheckedModeBanner: false,
        theme: K.theme(),
        home: const HomeScreen(),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final Rig _rig = Rig();
  Timer? _clock;
  DateTime _now = DateTime.now();
  bool _isHome = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rig.addListener(_onRig);
    _clock = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Ask before the first scan rather than after it comes back empty. On this tablet (API 25)
    // the scan needs ACCESS_FINE_LOCATION and location services on, and returns nothing at all --
    // no error, no callback -- when either is missing.
    if (!await Host.blePermissionsGranted()) await Host.requestBlePermissions();
    await _refreshDeviceState();
    _rig.startScan();
  }

  Future<void> _refreshDeviceState() async {
    final loc = await Host.locationEnabled();
    final home = await Host.isDefaultHome();
    if (!mounted) return;
    setState(() {
      _rig.locationBlocked = !loc;
      _isHome = home;
    });
  }

  void _onRig() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from Settings is how location and the default-home choice usually change.
    if (state == AppLifecycleState.resumed) {
      _refreshDeviceState();
      _rig.startScan();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    _rig.removeListener(_onRig);
    _rig.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: K.bg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            // One breakpoint. The panel is 601x961 dp: portrait puts the modules in a 2x2, and
            // landscape lays all four in a row, which is how they sit on the bench.
            final wide = box.maxWidth > 700;
            return Column(
              children: [
                _header(),
                if (_banner() != null) _banner()!,
                Expanded(child: _grid(wide)),
                _scenarioBar(),
                _dock(),
              ],
            );
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // header
  // ---------------------------------------------------------------------------

  Widget _header() {
    final live = _rig.allLive;
    final count = _rig.connectedCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: Row(
        children: [
          Image.asset('assets/keti-white.png', height: 20, filterQuality: FilterQuality.medium),
          const SizedBox(width: 10),
          const Text(
            'TSN RECONFIG',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 1.6, color: K.muted),
          ),
          const Spacer(),
          _pill(
            live ? K.ok : (count > 0 ? K.warn : K.dim),
            _rig.adapter == AdapterState.ready
                ? (_rig.scanning && count < pathCount ? '스캔 $count/$pathCount' : '$count/$pathCount')
                : _adapterLabel(),
          ),
          const SizedBox(width: 8),
          _iconButton(Icons.article_outlined, () => LogSheet.show(context, _rig)),
          _iconButton(Icons.refresh, () {
            _rig.resync();
            _refreshDeviceState();
          }),
          const SizedBox(width: 6),
          Text(_hhmm(_now), style: K.mono.copyWith(fontSize: 15, color: K.text)),
        ],
      ),
    );
  }

  String _adapterLabel() => switch (_rig.adapter) {
        AdapterState.unsupported => 'BLE 없음',
        AdapterState.unauthorised => '권한 없음',
        AdapterState.off => '블루투스 꺼짐',
        AdapterState.ready => '준비',
      };

  /// The one-line reason a scan cannot work, with the button that fixes it. Only ever shown when
  /// something is actually wrong -- an always-present hint bar is read as decoration and stops
  /// being read at all.
  Widget? _banner() {
    final (String text, String action, VoidCallback onTap)? issue = switch (_rig.adapter) {
      AdapterState.off => ('블루투스가 꺼져 있다', '켜기', () => _rig.turnOnBluetooth()),
      AdapterState.unauthorised => (
          'BLE 권한이 없다',
          '허용',
          () => Host.requestBlePermissions().then((_) => _rig.startScan())
        ),
      AdapterState.unsupported => ('이 기기는 BLE 를 지원하지 않는다', '', () {}),
      AdapterState.ready when _rig.locationBlocked => (
          '위치 서비스가 꺼져 있으면 안드로이드 7 에서 BLE 스캔이 아무것도 못 찾는다',
          '위치 설정',
          () => Host.openLocationSettings()
        ),
      AdapterState.ready when !_isHome => (
          '기본 홈으로 지정되어 있지 않다',
          '홈 설정',
          () => Host.openHomeSettings()
        ),
      _ => null,
    };
    if (issue == null) return null;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
      decoration: BoxDecoration(
        color: K.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: K.warn.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        const Icon(Icons.warning_amber_rounded, size: 16, color: K.warn),
        const SizedBox(width: 8),
        Expanded(
          child: Text(issue.$1,
              style: const TextStyle(fontSize: 11.5, color: K.warn, height: 1.25)),
        ),
        if (issue.$2.isNotEmpty)
          TextButton(
            onPressed: issue.$3,
            style: TextButton.styleFrom(
                minimumSize: const Size(0, 32), foregroundColor: K.warn),
            child: Text(issue.$2, style: const TextStyle(fontSize: 12)),
          ),
      ]),
    );
  }

  // ---------------------------------------------------------------------------
  // modules
  // ---------------------------------------------------------------------------

  /// The cards fill whatever height is left, so the aspect ratio is derived from the box rather
  /// than picked. A fixed ratio fit the portrait panel and clipped the bottom row's buttons off
  /// the moment the warning banner appeared above it -- and the banner appears exactly when
  /// something is wrong, which is when the buttons matter.
  Widget _grid(bool wide) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
        child: LayoutBuilder(
          builder: (context, box) {
            const gap = 10.0;
            // Portrait keeps two columns and grows downwards; landscape puts the whole rig in one
            // row, which is how the modules sit on the bench. Both derive from pathCount so
            // adding a module is a one-line change in rig.dart.
            final cols = wide ? pathCount : 2;
            final rows = (pathCount / cols).ceil();
            final cellW = (box.maxWidth - gap * (cols - 1)) / cols;
            final cellH = (box.maxHeight - gap * (rows - 1)) / rows;
            return GridView.count(
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: cols,
              childAspectRatio: cellW / cellH,
              mainAxisSpacing: gap,
              crossAxisSpacing: gap,
              children: [
                for (var n = 1; n <= pathCount; n++)
                  PathCard(
                    link: _rig.links[n]!,
                    onToggle: () => _rig.toggle(n),
                  ),
              ],
            );
          },
        ),
      );

  // ---------------------------------------------------------------------------
  // scenarios
  // ---------------------------------------------------------------------------

  /// Whole-rig states, because that is what a demo is driven in. "CUT n" restores the other three
  /// rather than adding to whatever was already cut -- a scenario button that depends on what was
  /// pressed before it is not a scenario button.
  Widget _scenarioBar() {
    final any = _rig.connectedCount > 0;
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        children: [
          _action('전체 복구', K.ok, any ? () => _rig.setAll(false) : null),
          for (var n = 1; n <= pathCount; n++)
            _action('$n 만 절단', K.pathColour(n),
                _rig.links[n]!.state == LinkState.connected ? () => _rig.cutOnly(n) : null),
          _action('전체 절단', K.fault, any ? () => _rig.setAll(true) : null),
        ],
      ),
    );
  }

  Widget _action(String label, Color colour, VoidCallback? onTap) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          color: onTap == null ? K.surface : colour.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap == null
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    onTap();
                  },
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: onTap == null ? K.dim : colour,
                ),
              ),
            ),
          ),
        ),
      );

  // ---------------------------------------------------------------------------
  // launcher dock
  // ---------------------------------------------------------------------------

  Widget _dock() => Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: K.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _rig.allLive
                    ? '모듈 4대 모두 응답 중'
                    : '${_rig.connectedCount}/$pathCount 연결 · 태블릿이 끊기면 모듈은 스스로 NORMAL 로 돌아간다',
                maxLines: 2,
                style: const TextStyle(fontSize: 10.5, color: K.dim, height: 1.25),
              ),
            ),
            const SizedBox(width: 10),
            _dockButton(Icons.apps, '앱', () => AppDrawerSheet.show(context)),
          ],
        ),
      );

  Widget _dockButton(IconData icon, String label, VoidCallback onTap) => Material(
        color: K.surfaceHi,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(children: [
              Icon(icon, size: 18, color: K.text),
              const SizedBox(width: 8),
              Text(label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: K.text)),
            ]),
          ),
        ),
      );

  // ---------------------------------------------------------------------------

  Widget _pill(Color colour, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: colour)),
      );

  Widget _iconButton(IconData icon, VoidCallback onTap) => IconButton(
        onPressed: onTap,
        icon: Icon(icon, size: 19),
        color: K.muted,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        padding: EdgeInsets.zero,
      );
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
