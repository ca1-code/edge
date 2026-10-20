// ignore_for_file: invalid_use_of_visible_for_testing_member, avoid_print

// Run on a PRIVATE COPY of an export (never the phone's live database):
// EDGE_TELEMETRY_DB=/path/to/copy/openstrap.db flutter test tool/replay_telemetry_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/recording_quality.dart';

void main() {
  final path = Platform.environment['EDGE_TELEMETRY_DB'];
  test(
    'replay exported measurements with coverage and no invented sleep',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(
        path!,
        options: OpenDatabaseOptions(readOnly: true),
      );
      try {
        final rows = await db.query('decoded_onehz', orderBy: 'rec_ts');
        final rr = await db.query(
          'decoded_rr',
          orderBy: 'rr_ts_ms, beat_index',
        );
        List<int> ints(String key) => [
          for (final r in rows) (r[key] as num?)?.toInt() ?? 0,
        ];
        List<double> doubles(String key) => [
          for (final r in rows) (r[key] as num?)?.toDouble() ?? 0,
        ];
        final sub = Substrate(
          tsSec: ints('rec_ts'),
          hr: ints('hr'),
          ax: doubles('ax'),
          ay: doubles('ay'),
          az: doubles('az'),
          rrTsMs: [for (final r in rr) (r['rr_ts_ms'] as num).toDouble()],
          rrMs: [for (final r in rr) (r['rr_ms'] as num).toDouble()],
          spo2Red: ints('spo2_red_raw'),
          spo2Ir: ints('spo2_ir_raw'),
          skinTemp: ints('skin_temp_raw'),
          skinContact: List.filled(rows.length, 0),
        );
        expect(sub.length, greaterThan(0));
        final prepared = prepareDerivationPayload(sub);
        final report = <Map<String, dynamic>>[];
        for (final day in prepared.days) {
          final d = day.daySub, s = day.sleepSub;
          final bundle = deriveDayBundle(
            DayBundleInput(
              date: day.date,
              dayTsSec: d.tsSec,
              dayHr: d.hr,
              dayRrTsMs: d.rrTsMs,
              dayRrMs: d.rrMs,
              sleepTsSec: s.tsSec,
              sleepHr: s.hr,
              sleepRrTsMs: s.rrTsMs,
              sleepRrMs: s.rrMs,
              sleepSpo2Red: s.spo2Red,
              sleepSpo2Ir: s.spo2Ir,
              sleepSkinTemp: s.skinTemp,
              sleepJson: day.sleepJson,
              hypnoStages: day.hypnoStages,
              sleepOnsetSec: day.sleepOnsetSec,
              sleepOffsetSec: day.sleepOffsetSec,
              profile: const {},
              dayFlags: day.flags,
            ).toJson(),
          );
          final scalars = bundle['scalars'] as Map;
          if (day.sleepJson['tst_sec'] != null) {
            expect(
              hasSleepRecordingCoverage(
                sub.tsSec,
                day.sleepOnsetSec,
                day.sleepOffsetSec,
              ),
              isTrue,
            );
          } else {
            expect(scalars['rhr'], isNull);
            expect(scalars['rmssd'], isNull);
            expect(scalars['readiness'], isNull);
          }
          final date = DateTime.parse(day.date);
          final q = recordingCoverage(
            d.tsSec,
            startSec: date.millisecondsSinceEpoch ~/ 1000,
            endSec:
                DateTime(
                  date.year,
                  date.month,
                  date.day + 1,
                ).millisecondsSinceEpoch ~/
                1000,
          );
          report.add({
            'date': day.date,
            'recorded_min': q['recorded_min'],
            'coverage_pct': q['coverage_pct'],
            'sleep_min': day.sleepJson['tst_sec'] == null
                ? null
                : (day.sleepJson['tst_sec'] as num) / 60,
            'hr_stats': bundle['hr_stats'],
            'rhr': scalars['rhr'],
            'rmssd': scalars['rmssd'],
            'flags': day.flags,
          });
        }
        // Kept outside the repository: the report contains personal measurements.
        final output = Platform.environment['EDGE_AUDIT_REPORT'];
        if (output != null) {
          await File(
            output,
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        }
        print(const JsonEncoder.withIndent('  ').convert(report));
      } finally {
        await db.close();
      }
    },
    skip: path == null
        ? 'Set EDGE_TELEMETRY_DB to a private export copy.'
        : false,
  );
}
