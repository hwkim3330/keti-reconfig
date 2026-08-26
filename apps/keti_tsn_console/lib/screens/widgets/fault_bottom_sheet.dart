// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/fault_data.dart';

class FaultBottomSheet extends ConsumerWidget {
  final List<FaultData> faults;

  const FaultBottomSheet({required this.faults, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
          child: Container(
            height: 420,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xff252a33), Color(0xff1a1d23)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: faults.isEmpty ? _buildEmpty() : _buildFaultList(faults),
          ),
        ),
      ],
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shield_rounded, size: 40, color: Color(0xff10b981)),
          SizedBox(height: 12),
          Text(
            'All Systems Normal',
            style: TextStyle(
              fontSize: 16,
              color: Color(0xff10b981),
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'No faults detected',
            style: TextStyle(fontSize: 13, color: Color(0xff9ca3af)),
          ),
        ],
      ),
    );
  }

  Widget _buildFaultList(List<FaultData> faultList) {
    final sorted = List<FaultData>.from(faultList)
      ..sort((a, b) => b.severity.compareTo(a.severity));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(sorted.length),
        const SizedBox(height: 16),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: sorted.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final fault = sorted[index];
              return _buildFaultCard(fault);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(int count) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          'Active Faults',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Color(0xffe2e8f0),
            letterSpacing: 0.5,
          ),
        ),
        Text(
          '$count fault${count > 1 ? 's' : ''}',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
        ),
      ],
    );
  }

  Widget _buildFaultCard(FaultData fault) {
    final severityColor = _severityColor(fault.severity);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xff2d3340),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: severityColor.withOpacity(0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 24,
                decoration: BoxDecoration(
                  color: severityColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  fault.faultType,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xffe2e8f0),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: severityColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: severityColor.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Text(
                  'LVL ${fault.severity}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: severityColor,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: Colors.grey.shade700,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.info_outline,
                  size: 12,
                  color: Colors.grey.shade500,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  fault.cause,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xff9ca3af),
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          if (fault.countermeasures.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Countermeasures',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xff6b7280),
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 6),
            ...fault.countermeasures.map(
              (measure) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.check_circle_outline_rounded,
                      size: 14,
                      color: Colors.grey.shade600,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        measure,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff6b7280),
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _severityColor(int severity) {
    switch (severity) {
      case 2:
        return const Color(0xffef4444);
      case 1:
        return const Color(0xfff59e0b);
      default:
        return const Color(0xff10b981);
    }
  }
}
