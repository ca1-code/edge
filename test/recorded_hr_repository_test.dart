import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

void main() {
  late LocalRepositoryImpl repo;
  late Directory temp;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('recorded-hr-test-');
    LocalDb.dbName = '${temp.path}/test.db';
    repo = LocalRepositoryImpl(getProfileMap: () => {'age': 30});
  });
  tearDown(() async {
    await LocalDb.close();
    await temp.delete(recursive: true);
  });

  test(
    'v25 upgrade preserves existing sessions and adds live recording',
    () async {
      final db = await LocalDb.instance;
      await db.insert('sessions', {
        'id': 'preserved',
        'start_ts': 100,
        'end_ts': 200,
        'type': 'run',
        'status': 'done',
        'source': 'manual',
        'created_at': 1,
      });
      await db.execute('DROP VIEW v_recording');
      await db.execute('DROP TABLE live_hr');
      await db.setVersion(25);
      await LocalDb.close();
      final upgraded = await LocalDb.instance;
      expect(await upgraded.getVersion(), 27);
      expect(
        await upgraded.query(
          'sessions',
          where: 'id = ?',
          whereArgs: ['preserved'],
        ),
        hasLength(1),
      );
      await LocalDb.recordLiveHeartRate(200, 75);
      expect(await upgraded.query('live_hr'), hasLength(1));
    },
  );
  test(
    'saved live HR supports workout averages and never duplicates a second',
    () async {
      const start = 1789804358;
      await LocalDb.putSession({
        'id': 'run',
        'start_ts': start,
        'end_ts': start + 60,
        'type': 'run',
        'status': 'done',
        'source': 'manual',
        'created_at': start * 1000,
      });
      for (var i = 0; i < 60; i++) {
        await LocalDb.recordLiveHeartRate(start + i, i < 30 ? 120 : 160);
      }
      await LocalDb.recordLiveHeartRate(start, 200);
      final workout = await repo.getWorkout('run');
      expect(workout['avg_hr'], 140);
      expect(workout['min_hr'], 120);
      expect(workout['max_hr'], 160);
      expect(
        (await LocalDb.sessionHrStats(start, start + 60))['run']?['n'],
        60,
      );
      expect(await LocalDb.getCursorInt('rec_ts_hw'), isNull);
    },
  );
  test(
    'historical HR wins an overlapping second without double counting',
    () async {
      const ts = 1789804358;
      await LocalDb.recordLiveHeartRate(ts, 100);
      final db = await LocalDb.instance;
      await db.insert('decoded_onehz', {
        'counter': 1,
        'rec_ts': ts,
        'hr': 120,
        'ax': 0,
        'ay': 0,
        'az': 1,
        'spo2_red_raw': 0,
        'spo2_ir_raw': 0,
        'skin_temp_raw': 0,
      });
      final rows = await LocalDb.hrSamplesInRange(ts, ts);
      expect(rows, hasLength(1));
      expect(rows.single['hr'], 120);
      expect(rows.single['source'], 'historical');
    },
  );
  test('Today never substitutes a two-week-old day', () async {
    final db = await LocalDb.instance;
    final old = dayLabelOf(DateTime.now().subtract(const Duration(days: 14)));
    await db.insert('day_result', {
      'day_id': old,
      'algo_version': 44,
      'computed_at': 1,
      'payload_json': jsonEncode({
        'date': old,
        'scalars': {'rhr': 69, 'rmssd': 94},
        'hr_stats': {'avg': 82, 'max': 149, 'min': 54},
      }),
    });
    final heart = await repo.getDayHeart(todayLabel());
    expect(heart['resting_hr'], isNull);
    expect(heart['avg_hr'], isNull);
    expect((heart['recording'] as Map)['recorded_seconds'], 0);
    final today = await repo.getToday();
    expect(today['daily'], isEmpty);
    expect(today['sleep'], isEmpty);
  });
  test('daily maximum comes from measurements, not minute averages', () async {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day - 1);
    final start = day.millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < 60; i++) {
      await LocalDb.recordLiveHeartRate(start + i, i == 30 ? 180 : 60);
    }
    final heart = await repo.getDayHeart(dayLabelOf(day));
    expect(heart['max_hr'], 180);
    expect(heart['min_hr'], 60);
    expect(heart['avg_hr'], 62);
    final db = await LocalDb.instance;
    final evidence = (await db.query(
      'v_recording',
      where: 'date = ?',
      whereArgs: [dayLabelOf(day)],
    )).single;
    expect(evidence['max_hr'], 180);
    expect(evidence['recorded_seconds'], 60);
    expect(evidence['live_seconds'], 60);
    expect((heart['recording'] as Map)['recorded_min'], 1);
  });
  test('this week is the current week even when all data is old', () async {
    final db = await LocalDb.instance;
    final old = dayLabelOf(DateTime.now().subtract(const Duration(days: 14)));
    await db.insert('metric_series', {'date': old, 'key': 'rhr', 'value': 69});
    final trend = await repo.getTrend('rhr');
    final buckets = trend['buckets'] as List;
    expect(buckets, hasLength(7));
    expect(buckets.every((b) => b['has'] == false), isTrue);
  });
}
