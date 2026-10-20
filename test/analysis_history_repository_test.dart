import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temp;
  late LocalRepositoryImpl repo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('analysis-history-test-');
    LocalDb.dbName = '${temp.path}/test.db';
    repo = LocalRepositoryImpl(getProfileMap: () => null);
  });
  tearDown(() async {
    await LocalDb.flushLiveHeartRate();
    await LocalDb.close();
    await temp.delete(recursive: true);
  });

  int second(String day, [int offset = 0]) =>
      DateTime.parse(day).millisecondsSinceEpoch ~/ 1000 + offset;

  Future<void> sensorDay(String day, {int hr = 80}) async {
    final db = await LocalDb.instance;
    // Multiple records still represent one day needing analysis.
    for (var offset = 0; offset < 2; offset++) {
      final ts = second(day, offset);
      await db.insert('decoded_onehz', {
        'counter': ts,
        'rec_ts': ts,
        'hr': hr,
        'ax': 0,
        'ay': 0,
        'az': 1,
        'spo2_red_raw': 0,
        'spo2_ir_raw': 0,
        'skin_temp_raw': 0,
      });
    }
  }

  Future<void> result(
    String day, {
    int version = kAlgoVersion,
    bool skipped = false,
    bool partial = false,
  }) => LocalDb.putDayResult(
    dayId: day,
    algoVersion: version,
    payloadJson: jsonEncode({
      'date': day,
      if (skipped) 'skipped': true,
      if (partial) 'partial': true,
      // No sleep/RHR is needed for valid measured HR to remain accessible.
      'flags': ['NO_SLEEP_DETECTED'],
      'hr_stats': {'avg': 80, 'min': 70, 'max': 90},
      'scalars': <String, dynamic>{},
    }),
    windowJson: '{}',
    skipped: skipped,
    partial: partial,
  );

  test(
    'empty store has no pending analysis or historical date range',
    () async {
      final today = await repo.getToday();
      final analysis = today['analysis'] as Map;
      expect(analysis['sensor_days'], 0);
      expect(analysis['analyzed_days'], 0);
      expect(analysis['pending_days'], 0);
      expect(analysis['saved_days'], 0);
      expect(analysis['first_sensor_day'], isNull);
      expect(analysis['latest_sensor_day'], isNull);
      final heart = today['recorded_heart'] as Map;
      expect(heart['avg_hr'], isNull);
      expect(heart['min_hr'], isNull);
      expect(heart['max_hr'], isNull);
      expect(heart['hr'], isEmpty);
    },
  );

  test(
    'successfully analyzed old days do not ask for analysis again',
    () async {
      for (final day in ['2020-09-03', '2020-09-04', '2020-09-05']) {
        await sensorDay(day);
        await result(day);
      }

      final today = await repo.getToday();
      final analysis = today['analysis'] as Map;
      expect(analysis['sensor_days'], 3);
      expect(analysis['analyzed_days'], 3);
      expect(analysis['pending_days'], 0);
      expect(analysis['saved_days'], 3);
      expect(analysis['first_sensor_day'], '2020-09-03');
      expect(analysis['latest_sensor_day'], '2020-09-05');
      expect((today['recorded_heart'] as Map)['avg_hr'], isNull);

      final historical = await repo.getDayHeart('2020-09-03');
      expect(historical['avg_hr'], 80);
      expect(historical['resting_hr'], isNull);
      expect(historical['hr'], isNotEmpty);
    },
  );

  test(
    'missing, partial, failed, and outdated results remain pending',
    () async {
      const days = [
        '2020-09-01', // no result
        '2020-09-02', // partial current result
        '2020-09-03', // failed current result supersedes an older success
        '2020-09-04', // complete, but outdated
        '2020-09-05', // complete current result
        '2020-09-06', // complete newer result from an imported backup
      ];
      for (final day in days) {
        await sensorDay(day);
      }
      await result(days[1], partial: true);
      await result(days[2], version: kAlgoVersion - 1);
      await result(days[2], skipped: true);
      await result(days[3], version: kAlgoVersion - 1);
      await result(days[4]);
      await result(days[5], version: kAlgoVersion + 1);

      final analysis = (await repo.getToday())['analysis'] as Map;
      expect(analysis['sensor_days'], 6);
      expect(analysis['analyzed_days'], 2);
      expect(analysis['pending_days'], 4);
      expect(analysis['saved_days'], 6);

      final rows = await LocalDb.dataHistoryDays();
      final byDay = {for (final row in rows) row['day_id']: row};
      expect(byDay[days[0]]!['has_derived'], isFalse);
      expect(byDay[days[1]]!['has_derived'], isTrue);
      expect(byDay[days[1]]!['analysis_partial'], isTrue);
      expect(byDay[days[1]]!['analysis_failed'], isFalse);
      expect(byDay[days[2]]!['has_derived'], isFalse);
      expect(byDay[days[2]]!['analysis_failed'], isTrue);
      expect(byDay[days[4]]!['analysis_failed'], isFalse);
      expect(byDay[days[4]]!['analysis_partial'], isFalse);
    },
  );

  test(
    'live-only history is visible without requiring sensor analysis',
    () async {
      const day = '2020-09-20';
      await LocalDb.recordLiveHeartRate(second(day, 60), 70);
      await LocalDb.recordLiveHeartRate(second(day, 61), 90);

      final rows = await LocalDb.dataHistoryDays();
      expect(rows, hasLength(1));
      expect(rows.single['day_id'], day);
      expect(rows.single['live_count'], 2);
      expect(rows.single['raw_count'], 0);
      expect(rows.single['has_derived'], isFalse);

      final analysis = (await repo.getToday())['analysis'] as Map;
      expect(analysis['saved_days'], 1);
      expect(analysis['sensor_days'], 0);
      expect(analysis['analyzed_days'], 0);
      expect(analysis['pending_days'], 0);
      expect(analysis['first_sensor_day'], isNull);
      expect(analysis['latest_sensor_day'], isNull);
      expect((await repo.getDayHeart(day))['avg_hr'], 80);
    },
  );

  test(
    'saved inventory counts unique raw, derived, live, and workout days',
    () async {
      await sensorDay('2020-09-01');
      await result('2020-09-01');
      await LocalDb.recordLiveHeartRate(second('2020-09-01', 30), 70);
      await result('2020-09-02'); // compact result retained after raw removal
      await LocalDb.recordLiveHeartRate(second('2020-09-03', 30), 80);
      await LocalDb.putSession({
        'id': 'older-workout',
        'start_ts': second('2020-09-04', 3600),
        'end_ts': second('2020-09-04', 5400),
        'type': 'run',
        'status': 'done',
        'source': 'manual',
        'created_at': 1,
      });

      final analysis = (await repo.getToday())['analysis'] as Map;
      expect(analysis['saved_days'], 4);
      expect(analysis['sensor_days'], 1);
      expect(analysis['analyzed_days'], 1);
      expect(analysis['pending_days'], 0);
      final rows = await LocalDb.dataHistoryDays();
      expect(rows, hasLength(4));
      expect(rows.map((row) => row['day_id']), [
        '2020-09-04',
        '2020-09-03',
        '2020-09-02',
        '2020-09-01',
      ]);
      expect(rows.last['live_count'], 1);
      expect(rows.last['raw_count'], 2);
    },
  );

  test(
    'Today measured HR is available before derivation and excludes old days',
    () async {
      await sensorDay('2020-09-01', hr: 200);
      await result('2020-09-01');
      final today = todayLabel();
      await LocalDb.recordLiveHeartRate(second(today), 60);
      await LocalDb.recordLiveHeartRate(second(today, 1), 90);
      await LocalDb.recordLiveHeartRate(second(today, 2), 120);

      final response = await repo.getToday();
      final heart = response['recorded_heart'] as Map;
      expect(heart['avg_hr'], 90);
      expect(heart['min_hr'], 60);
      expect(heart['max_hr'], 120);
      expect(heart['hr'], isNotEmpty);
      expect((response['recording'] as Map)['recorded_seconds'], 3);
      expect((response['analysis'] as Map)['pending_days'], 0);
      expect(response['sleep'], isEmpty);
    },
  );
}
