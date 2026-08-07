// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/fault_provider.dart';

class SystemStatusBar extends ConsumerStatefulWidget {
  const SystemStatusBar({super.key});

  @override
  ConsumerState<SystemStatusBar> createState() => _SystemStatusBarState();
}

class _SystemStatusBarState extends ConsumerState<SystemStatusBar>
    with SingleTickerProviderStateMixin {
  late Timer _clockTimer;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  String _formatTime(DateTime now) {
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
  }

  String _formatDate(DateTime now) {
    final months = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];
    final day = now.day.toString().padLeft(2, '0');
    return '$day ${months[now.month - 1]}'
        ' ${now.year.toString().substring(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final faultState = ref.watch(faultProvider);
    final faultCount = faultState.length;

    return Container(
      constraints: const BoxConstraints(maxWidth: 900),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xff252a33).withOpacity(0.95),
            const Color(0xff1e2229).withOpacity(0.9),
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xff3a3f48).withOpacity(0.8),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Left: brand + status dot
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Pulsing green dot
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  return Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: const Color(0xff10b981),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xff10b981,
                          ).withOpacity(0.3 + _pulseController.value * 0.3),
                          blurRadius: 8 + _pulseController.value * 6,
                          spreadRadius: _pulseController.value * 2,
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(width: 12),
              const Text(
                'PLEOS',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Color(0xffe2e8f0),
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                'MANAGER',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                  color: Colors.grey.shade500,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),

          // Right: fault badge + clock
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (faultCount > 0) _buildFaultBadge(faultCount),
              if (faultCount > 0) const SizedBox(width: 16),
              const Icon(
                Icons.schedule_rounded,
                size: 16,
                color: Color(0xff9ca3af),
              ),
              const SizedBox(width: 8),
              Text(
                _formatTime(DateTime.now()),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Color(0xffe2e8f0),
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _formatDate(DateTime.now()),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFaultBadge(int count) {
    final isCritical = count >= 3;
    final accentColor = isCritical
        ? const Color(0xffef4444)
        : const Color(0xfff59e0b);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: accentColor.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withOpacity(0.4), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: accentColor),
          const SizedBox(width: 4),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: accentColor,
            ),
          ),
        ],
      ),
    );
  }
}
