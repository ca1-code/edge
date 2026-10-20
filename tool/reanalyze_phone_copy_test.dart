// Run only against a disposable copy, never the original export or phone DB.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

void main() {
  final path = Platform.environment['EDGE_AUDIT_COPY'];
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'upgrade and re-analyze a disposable copy of the phone database',
    () async {
      expect(path!.endsWith('openstrap-copy.db'), isTrue);
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = path;
      try {
        final db = await LocalDb.instance;
        expect(await db.getVersion(), 27);
        expect((await db.query('sessions')).length, 5);
        final workouts = await LocalDb.rebuildWorkoutHeartRates();
        expect(
          workouts.updated,
          0,
        ); // export has no HR overlapping these sessions
        expect(workouts.missing, 5);
        final engine = DerivationEngine();
        final days = await engine.run(
          const Profile(),
          force: true,
          heavy: true,
        );
        expect(days, 3, reason: '${engine.snapshot()}');
        expect(engine.snapshot()['last_error'], isNull);
        final repo = LocalRepositoryImpl(getProfileMap: () => null);
        final analysis = (await repo.getToday())['analysis'] as Map;
        expect(analysis['sensor_days'], 3);
        expect(analysis['analyzed_days'], 3);
        expect(analysis['pending_days'], 0);
        final inventory = await LocalDb.dataHistoryDays();
        for (final day in inventory.where((d) => (d['raw_count'] as int) > 0)) {
          final heart = await repo.getDayHeart(day['day_id'] as String);
          expect(heart['avg_hr'], isA<num>());
          expect(heart['hr'], isNotEmpty);
        }
        expect((await db.query('sessions')).length, 5);
        expect(
          (await db.rawQuery(
            'SELECT COUNT(*) AS n FROM decoded_onehz',
          )).single['n'],
          35570,
        );
      } finally {
        await LocalDb.close();
      }
    },
    skip: path == null,
  );
}
