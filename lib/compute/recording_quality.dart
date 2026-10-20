import 'dart:math' as math;

/// Coverage of recorded seconds, not an inference about wrist contact.
/// Missing downloads and off-wrist time are indistinguishable here.
Map<String, dynamic> recordingCoverage(
  Iterable<int> timestamps, {
  required int startSec,
  required int endSec,
}) {
  final seconds =
      timestamps.where((t) => t >= startSec && t < endSec).toSet().toList()
        ..sort();
  final span = endSec > startSec ? endSec - startSec : 0;
  var longestGap = 0;
  var cursor = startSec;
  var segments = 0;
  int? previous;
  final hourly = List<double>.filled(24, 0);
  for (final t in seconds) {
    if (previous == null || t - previous > 120) segments++;
    previous = t;
    hourly[DateTime.fromMillisecondsSinceEpoch(t * 1000).hour] += 1 / 60;
    if (t - cursor > longestGap) longestGap = t - cursor;
    cursor = t + 1;
  }
  if (endSec - cursor > longestGap) longestGap = endSec - cursor;
  return {
    'recorded_seconds': seconds.length,
    'recorded_min': seconds.length / 60,
    'expected_seconds': span,
    'coverage_pct': span == 0 ? 0.0 : 100 * seconds.length / span,
    'longest_gap_sec': longestGap,
    'first_record_ts': seconds.isEmpty ? null : seconds.first,
    'last_record_ts': seconds.isEmpty ? null : seconds.last,
    'basis': 'recorded_seconds',
    'segments': segments,
    'hourly': hourly,
  };
}

/// Five-minute RMSSD observations. Reject sparse windows and never form a
/// successive difference across a missing/invalid beat. Times remain absolute.
/// This is a data-quality gate, not a validated clinical HRV estimator.
List<Map<String, num>> recordedHrvWindows(
  List<double> timestampsMs,
  List<double> intervalsMs,
) {
  if (timestampsMs.length != intervalsMs.length) return const [];
  final bins = <int, List<int>>{};
  for (var i = 0; i < intervalsMs.length; i++) {
    if (!timestampsMs[i].isFinite) continue;
    (bins[timestampsMs[i] ~/ 300000] ??= []).add(i);
  }
  final result = <Map<String, num>>[];
  final keys = bins.keys.toList()..sort();
  for (final bin in keys) {
    final ids = bins[bin]!;
    if (ids.length < 120) continue;
    double covered = 0, squared = 0;
    var pairs = 0;
    for (var j = 1; j < ids.length; j++) {
      final prev = ids[j - 1], cur = ids[j];
      final a = intervalsMs[prev], b = intervalsMs[cur];
      final dt = timestampsMs[cur] - timestampsMs[prev];
      if (cur != prev + 1 ||
          dt <= 0 ||
          dt > 2500 ||
          !a.isFinite ||
          !b.isFinite ||
          a < 300 ||
          a > 2000 ||
          b < 300 ||
          b > 2000) {
        continue;
      }
      final delta = b - a;
      if (delta.abs() > 200 || delta.abs() > .2 * a) continue;
      squared += delta * delta;
      covered += math.min(dt, b);
      pairs++;
    }
    if (pairs < 120 || covered < 240000) continue;
    result.add({
      't': bin * 300,
      'v': math.sqrt(squared / pairs),
      'coverage_pct': math.min(100, 100 * covered / 300000),
    });
  }
  return result;
}

/// Conservative product gates: never stage hours of absent samples as sleep.
/// These thresholds describe data sufficiency, not physiological validation.
bool hasSleepRecordingCoverage(
  Iterable<int> timestamps,
  int onsetSec,
  int offsetSec,
) {
  final q = recordingCoverage(
    timestamps,
    startSec: onsetSec,
    endSec: offsetSec,
  );
  return offsetSec > onsetSec &&
      (q['coverage_pct'] as num) >= 80 &&
      (q['longest_gap_sec'] as int) <= 300;
}

/// Algorithms that reconstruct NN time from intervals must not concatenate
/// separate recording fragments. Require at least five continuous minutes.
bool hasContinuousRrRecording(List<double> times, List<double> intervals) {
  if (times.length != intervals.length || times.length < 120) return false;
  final span = times.last - times.first;
  if (!span.isFinite || span < 300000) return false;
  double covered = 0;
  for (var i = 1; i < times.length; i++) {
    final dt = times[i] - times[i - 1];
    final rr = intervals[i];
    if (!dt.isFinite || dt <= 0 || dt > 2500) return false;
    if (rr.isFinite && rr >= 300 && rr <= 2000) {
      covered += math.min(dt, rr);
    }
  }
  return covered >= .8 * span;
}
