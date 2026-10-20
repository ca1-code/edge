import 'package:flutter/material.dart';
import '../design/design.dart';

/// Visible measurement coverage, shared by day HR and activity screens.
class RecordingNotice extends StatelessWidget {
  final Map<dynamic, dynamic>? recording;
  const RecordingNotice({super.key, this.recording});

  @override
  Widget build(BuildContext context) {
    final q = recording;
    if (q == null) return const SizedBox.shrink();
    final minutes = (q['recorded_min'] as num? ?? 0).round();
    final hasRecording = (q['recorded_seconds'] as num? ?? minutes * 60) > 0;
    final duration = minutes < 1
        ? 'less than 1m'
        : '${minutes ~/ 60}h ${minutes % 60}m';
    final coverage = (q['coverage_pct'] as num? ?? 0).clamp(0, 100);
    final pct = coverage > 0 && coverage < 1 ? '<1' : '${coverage.round()}';
    final live = (q['live_seconds'] as num? ?? 0) > 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x4),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              !hasRecording
                  ? 'No HR recording for this day'
                  : 'Recorded $duration · $pct% coverage',
              style: AppText.body,
            ),
            const SizedBox(height: Sp.x2),
            Text(
              !hasRecording
                  ? 'Live HR can work while history is missing. Sync the band to download recorded history.'
                  : 'Statistics describe the recorded data. Gaps mean missing recordings, not necessarily time off your wrist.'
                        '${live ? ' Includes live HR saved while connected.' : ''}',
              style: AppText.caption,
            ),
          ],
        ),
      ),
    );
  }
}
