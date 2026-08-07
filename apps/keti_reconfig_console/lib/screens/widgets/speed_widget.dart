// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/services.dart';
import 'package:keti_reconfig_console/screens/widgets/permission_request_widget.dart';

class SpeedWidget extends StatefulWidget {
  const SpeedWidget({super.key});

  @override
  State<SpeedWidget> createState() => _SpeedWidgetState();
}

class _SpeedWidgetState extends State<SpeedWidget>
    with SingleTickerProviderStateMixin {
  static const MethodChannel _permissionChannel = MethodChannel(
    'com.example/permissions',
  );
  static const EventChannel _speedChannel = EventChannel(
    'com.example/car_speed_stream',
  );

  bool _hasCarSpeedPermission = false;
  bool _isLoading = true;
  double _currentSpeed = 0.0;
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _checkPermission();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _checkPermission() async {
    setState(() => _isLoading = true);
    final bool hasPermission;
    try {
      hasPermission =
          await _permissionChannel.invokeMethod<bool>(
            'requestCarSpeedPermission',
          ) ??
          false;
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _hasCarSpeedPermission = false;
        _isLoading = false;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _hasCarSpeedPermission = hasPermission;
      _isLoading = false;
    });
  }

  void _animateSpeed(double target) {
    _animController
      ..value = 0.0
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return _buildGauge(0.0);
    }

    return _hasCarSpeedPermission
        ? StreamBuilder(
            stream: _speedChannel.receiveBroadcastStream(),
            builder: (context, snapshot) {
              if (snapshot.hasError || !snapshot.hasData) {
                return _buildGauge(_currentSpeed);
              }
              final raw = snapshot.data;
              final value = raw is num ? raw.toDouble() : _currentSpeed;
              _currentSpeed = value;
              _animateSpeed(value);
              return _buildGauge(value);
            },
          )
        : PermissionRequestWidget(
            title: 'Car Speed',
            icon: Icons.speed,
            onPressed: _checkPermission,
          );
  }

  Widget _buildGauge(double speed) {
    return Container(
      width: 210,
      height: 210,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xff252a33),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xff3a3f48), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Arc gauge
          PieChart(
            PieChartData(
              sections: _buildSections(speed),
              centerSpaceRadius: 70,
              startDegreeOffset: -90,
              sectionsSpace: 0,
            ),
          ),
          // Tick marks ring
          _buildTickMarks(),
          // Center text
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                speed.toStringAsFixed(0),
                style: const TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.w800,
                  color: Color(0xffe2e8f0),
                  height: 1.1,
                ),
              ),
              Text(
                'km/h',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey.shade500,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTickMarks() {
    return CustomPaint(size: const Size(186, 186), painter: TickMarkPainter());
  }

  List<PieChartSectionData> _buildSections(double speed) {
    double fraction = (speed.clamp(0, 200).toDouble() / 200).clamp(0, 1);

    Color activeColor;
    if (fraction < 0.3) {
      activeColor = const Color(0xff10b981);
    } else if (fraction < 0.6) {
      activeColor = const Color(0xfff59e0b);
    } else {
      activeColor = const Color(0xffef4444);
    }

    return [
      PieChartSectionData(
        value: fraction,
        color: activeColor,
        radius: 76,
        title: '',
        titleStyle: const TextStyle(fontSize: 0),
      ),
      PieChartSectionData(
        value: 1.0 - fraction,
        color: const Color(0xff2d3340),
        radius: 76,
        title: '',
        titleStyle: const TextStyle(fontSize: 0),
      ),
    ];
  }
}

class TickMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 10;

    final tickPaint = Paint()
      ..color = Colors.grey.shade700
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final majorPaint = Paint()
      ..color = Colors.grey.shade500
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    const totalTicks = 40;
    const startAngle = -225 * 3.14159 / 180;
    const sweepAngle = 270 * 3.14159 / 180;

    for (int i = 0; i <= totalTicks; i++) {
      final angle = startAngle + (sweepAngle * i / totalTicks);
      final isMajor = i % 5 == 0;
      final innerR = isMajor ? radius - 8 : radius - 4;
      final outerR = radius;

      final x1 = center.dx + innerR * math.cos(angle);
      final y1 = center.dy + innerR * math.sin(angle);
      final x2 = center.dx + outerR * math.cos(angle);
      final y2 = center.dy + outerR * math.sin(angle);

      canvas.drawLine(
        Offset(x1, y1),
        Offset(x2, y2),
        isMajor ? majorPaint : tickPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant TickMarkPainter oldDelegate) => false;
}
