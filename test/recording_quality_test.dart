import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/recording_quality.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

void main() {
  test('two recorded hours are 8.33 percent of a day, not 100 percent', () {
    final q = recordingCoverage(
      List.generate(7200, (i) => 36000 + i),
      startSec: 0,
      endSec: 86400,
    );
    expect(q['coverage_pct'], closeTo(100 / 12, .001));
    expect(q['recorded_min'], 120);
  });
  test('duplicates and samples outside the window cannot inflate coverage', () {
    final q = recordingCoverage([-1, 0, 0, 1, 100], startSec: 0, endSec: 100);
    expect(q['recorded_seconds'], 2);
    expect(q['longest_gap_sec'], 98);
  });
  test('sleep cannot span an unrecorded overnight gap', () {
    final ts = [
      for (var i = 0; i < 3600; i++) i,
      for (var i = 8 * 3600; i < 9 * 3600; i++) i,
    ];
    expect(hasSleepRecordingCoverage(ts, 0, 9 * 3600), isFalse);
    expect(
      hasSleepRecordingCoverage(List.generate(9 * 3600, (i) => i), 0, 9 * 3600),
      isTrue,
    );
  });
  test('sparse RR cannot produce HRV even when a few pairs are available', () {
    final ts = List.generate(20, (i) => 15000.0 * i);
    expect(recordedHrvWindows(ts, List.filled(20, 1000)), isEmpty);
  });
  test('continuous RR produces a timestamped window with known RMSSD', () {
    final ts = List.generate(300, (i) => 1000.0 * i);
    final rr = List.generate(300, (i) => i.isEven ? 990.0 : 1010.0);
    final w = recordedHrvWindows(ts, rr);
    expect(w, hasLength(1));
    expect(w.single['v'], closeTo(20, .001));
    expect(w.single['t'], 0);
  });
  test(
    'spectral estimators cannot compress a long RR gap into continuous time',
    () {
      final continuous = List.generate(601, (i) => i * 1000.0);
      final rr = List<double>.filled(601, 1000);
      expect(hasContinuousRrRecording(continuous, rr), isTrue);
      final gap = [
        for (var i = 0; i < 601; i++) continuous[i] + (i > 300 ? 3600000 : 0),
      ];
      expect(hasContinuousRrRecording(gap, rr), isFalse);
    },
  );
  test('daytime HR without sleep never becomes nocturnal RHR or readiness', () {
    final b = deriveDayBundle({
      'date': '2026-09-04',
      'day_ts': List.generate(3600, (i) => 1788519600 + i),
      'day_hr': List.filled(3600, 85),
      'profile': {},
      'rhr_history': List.filled(10, 60.0),
    });
    final s = b['scalars'] as Map;
    expect(s['rhr'], isNull);
    expect(s['sleeping_hr_avg'], isNull);
    expect(s['readiness'], isNull);
    expect((b['hr_stats'] as Map)['avg'], 85);
  });
}
