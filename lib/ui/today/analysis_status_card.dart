import 'package:flutter/material.dart';
import '../design/design.dart';

/// Analysis state belongs to the saved dates, not to today's recovery score.
class AnalysisStatusCard extends StatelessWidget {
  final Map<dynamic, dynamic> analysis;
  final bool running;
  final String progress;
  final VoidCallback onAnalyze;
  final VoidCallback onHistory;
  const AnalysisStatusCard({
    super.key,
    required this.analysis,
    this.running = false,
    this.progress = '',
    required this.onAnalyze,
    required this.onHistory,
  });

  @override
  Widget build(BuildContext context) {
    final sensorDays = (analysis['sensor_days'] as num?)?.toInt() ?? 0;
    final pending = (analysis['pending_days'] as num?)?.toInt() ?? 0;
    final saved = (analysis['saved_days'] as num?)?.toInt() ?? 0;
    final first = analysis['first_sensor_day'];
    final last = analysis['latest_sensor_day'];
    final dates = first == last ? '$last' : '$first to $last';
    final title = running
        ? 'Analyzing saved history'
        : pending > 0
        ? 'Saved days ready for analysis'
        : sensorDays > 0
        ? 'Saved history analyzed'
        : saved > 0
        ? 'Your recorded history'
        : 'Waiting for recordings';
    final message = running
        ? (progress.isEmpty ? 'Analyzing saved days…' : progress)
        : pending > 0
        ? '$pending of $sensorDays sensor days need analysis ($dates).'
        : sensorDays > 0
        ? '$sensorDays sensor day${sensorDays == 1 ? '' : 's'} analyzed ($dates). '
              'Open a saved day to see its results. Re-analysis cannot fill missing recordings.'
        : 'Heart-rate readings are summarized as they arrive. Sleep and HRV need '
              'historical sensor recordings from the band.';
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (running) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: Sp.x3),
          ],
          Text(title, style: AppText.h2),
          const SizedBox(height: Sp.x2),
          Text(message, style: AppText.bodySoft),
          if (!running && pending > 0) ...[
            const SizedBox(height: Sp.x3),
            FilledButton(
              onPressed: onAnalyze,
              child: const Text('Analyze saved days'),
            ),
          ],
          if (saved > 0) ...[
            const SizedBox(height: Sp.x2),
            TextButton(
              onPressed: onHistory,
              child: const Text('View recorded days'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Live-only recordings are useful even without a sleep/day derivation bundle.
class RecordedHeartCard extends StatelessWidget {
  final Map<dynamic, dynamic> heart;
  final VoidCallback onOpen;
  const RecordedHeartCard({
    super.key,
    required this.heart,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    if (heart['avg_hr'] is! num) return const SizedBox.shrink();
    return SurfaceCard(
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Today’s recorded heart rate', style: AppText.title),
          const SizedBox(height: Sp.x3),
          Row(
            children: [
              for (final item in [
                ('avg_hr', 'Average'),
                ('min_hr', 'Lowest'),
                ('max_hr', 'Highest'),
              ])
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${(heart[item.$1] as num?)?.round() ?? '—'}',
                        style: AppText.metricSm,
                      ),
                      Text('${item.$2} bpm', style: AppText.captionMuted),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: Sp.x2),
          Text(
            'From saved readings. Tap for the day’s heart-rate detail.',
            style: AppText.captionMuted,
          ),
        ],
      ),
    );
  }
}
