import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('force re-analysis rebuilds a retained finalized day', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final temp = await Directory.systemTemp.createTemp('reanalyze-finalized-');
    LocalDb.dbName = '${temp.path}/test.db';
    try {
      final db = await LocalDb.instance;
      final start = DateTime(2026, 9, 23, 12).millisecondsSinceEpoch ~/ 1000;
      final batch = db.batch();
      for (var i = 0; i < 600; i++) {
        batch.insert('decoded_onehz', {
          'counter': i,
          'rec_ts': start + i,
          'hr': 80,
          'ax': 0,
          'ay': 0,
          'az': 1,
          'spo2_red_raw': 0,
          'spo2_ir_raw': 0,
          'skin_temp_raw': 0,
        });
      }
      await batch.commit(noResult: true);
      await db.insert('day_result', {
        'day_id': '2026-09-23',
        'algo_version': kAlgoVersion,
        'computed_at': 1,
        'finalized': 1,
        'payload_json': '{"old":true}',
      });
      final engine = DerivationEngine();
      expect(await engine.run(const Profile(), heavy: true), 0);
      final rebuilt = await engine.run(
        const Profile(),
        heavy: true,
        force: true,
      );
      expect(rebuilt, greaterThan(0), reason: '${engine.snapshot()}');
      final row = (await db.query(
        'day_result',
        where: 'day_id = ?',
        whereArgs: ['2026-09-23'],
      )).single;
      expect(row['computed_at'], isNot(1));
      expect(row['payload_json'], isNot('{"old":true}'));
    } finally {
      await LocalDb.close();
      await temp.delete(recursive: true);
    }
  });
}
