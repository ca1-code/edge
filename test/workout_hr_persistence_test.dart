import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/reanalysis_result.dart';

void main() {
  late Directory temp;
  late LocalRepositoryImpl repo;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('workout-summary-');
    LocalDb.dbName = '${temp.path}/test.db';
    repo = LocalRepositoryImpl(getProfileMap: () => {'age': 30});
  });
  tearDown(() async {
    await LocalDb.close();
    await temp.delete(recursive: true);
  });
  Map<String, dynamic> workout(String id) => {
    'id': id,
    'start_ts': 100,
    'end_ts': 159,
    'type': 'run',
    'status': 'done',
    'created_at': 1,
  };

  test('finish waits for received HR and saves a permanent average', () async {
    // Deliberately leave writes pending, as the BLE callback does.
    final pending = [
      for (var i = 0; i < 60; i++)
        LocalDb.recordLiveHeartRate(100 + i, i < 30 ? 120 : 160),
    ];
    await LocalDb.putSession(workout('run'));
    await Future.wait(pending);
    final row = (await LocalDb.session('run'))!;
    expect(row['avg_hr'], 140);
    expect(row['hr_sample_count'], 60);
    final db = await LocalDb.instance;
    await db.delete('live_hr');
    await LocalDb.close();
    expect((await repo.getWorkout('run'))['avg_hr'], 140);
    expect(
      ((await repo.getWorkouts(range: 'all'))['workouts'] as List)
          .single['avg_hr'],
      140,
    );
    await LocalDb.putSession({'id': 'run', 'type': 'ride'});
    expect((await repo.getWorkout('run'))['min_hr'], 120);
    final originalEnd = (await LocalDb.session('run'))!['end_ts'];
    await repo.endWorkout('run');
    expect((await LocalDb.session('run'))!['end_ts'], originalEnd);
  });

  test(
    're-analysis recovers old workouts without claiming absent data',
    () async {
      await LocalDb.putSession(workout('recoverable'));
      await LocalDb.putSession({
        ...workout('missing'),
        'start_ts': 200,
        'end_ts': 250,
      });
      await LocalDb.recordLiveHeartRate(100, 120);
      await LocalDb.recordLiveHeartRate(101, 160);
      final result = await LocalDb.rebuildWorkoutHeartRates();
      expect(result.updated, 1);
      expect(result.missing, 1);
      expect((await LocalDb.session('recoverable'))!['avg_hr'], 140);
      expect((await LocalDb.session('missing'))!['avg_hr'], isNull);
      await (await LocalDb.instance).delete('live_hr', where: 'rec_ts = 101');
      await LocalDb.rebuildWorkoutHeartRates();
      expect((await repo.getWorkout('recoverable'))['avg_hr'], 140);
    },
  );

  test(
    'historical retention saves workout summary before deleting samples',
    () async {
      await LocalDb.putSession(workout('history'));
      final db = await LocalDb.instance;
      for (var i = 0; i < 60; i++) {
        await db.insert('decoded_onehz', {
          'counter': i,
          'rec_ts': 100 + i,
          'hr': 130,
          'ax': 0,
          'ay': 0,
          'az': 1,
          'spo2_red_raw': 0,
          'spo2_ir_raw': 0,
          'skin_temp_raw': 0,
        });
      }
      await LocalDb.pruneDecodedBeforeRecTs(200);
      expect(await LocalDb.hrSamplesInRange(100, 159), isEmpty);
      expect((await repo.getWorkout('history'))['avg_hr'], 130);
      expect((await LocalDb.session('history'))!['hr_sample_count'], 60);
    },
  );

  test('failure is not reported as an empty successful re-analysis', () {
    final report = const ReanalysisResult(
      days: 1,
      workouts: 2,
      missingWorkouts: 3,
      error: 'test failure',
    ).message;
    expect(report, contains('Rebuilt 1 day and 2 workout HR summaries'));
    expect(report, contains('3 workouts have no saved HR readings'));
    expect(report, contains('Analysis could not finish: test failure'));
  });
}
