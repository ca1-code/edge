import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/kit/kit.dart';
import 'package:openstrap_edge/ui/kit/charts.dart' show LabeledBars;
import 'package:openstrap_edge/ui/screens/metric_screen.dart';
import 'package:openstrap_edge/ui/screens/screens.dart';

void main() {
  late LocalRepositoryImpl repo;
  late Directory temp;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('partial-trend-');
    LocalDb.dbName = '${temp.path}/test.db';
    repo = LocalRepositoryImpl(getProfileMap: () => null);
  });
  tearDown(() async {
    await LocalDb.close();
    await temp.delete(recursive: true);
    AppColors.active = kLightPalette;
  });

  Future<void> scalar(String date, double value, {String key = 'rhr'}) async {
    await (await LocalDb.instance).insert('metric_series', {
      'date': date,
      'key': key,
      'value': value,
    });
  }

  test('one day is enough for a week; absent dates stay null', () async {
    await scalar('2026-10-17', 62);
    final trend = await repo.getTrend('resting_hr', anchor: '2026-10-19');
    final summary = trend['summary'] as Map;
    expect(summary['avg'], 62);
    expect(summary['days_with_data'], 1);
    expect(summary['days_in_period'], 7);
    expect(summary['partial'], isTrue);
    final buckets = trend['buckets'] as List;
    expect(buckets, hasLength(7));
    expect(buckets.where((b) => b['has'] == true), hasLength(1));
    expect(
      buckets.where((b) => b['has'] == false).every((b) => b['value'] == null),
      isTrue,
    );
  });

  test(
    'month average weights available days, not sparse weekly buckets',
    () async {
      await scalar('2026-10-01', 50);
      for (var day = 13; day <= 19; day++) {
        await scalar('2026-10-$day', 100);
      }
      final trend = await repo.getTrend(
        'resting_hr',
        scale: 'month',
        anchor: '2026-10-19',
      );
      final summary = trend['summary'] as Map;
      expect(summary['avg'], 93.8); // (50 + 7 * 100) / 8, not (50 + 100) / 2
      expect(summary['days_with_data'], 8);
      expect(summary['days_in_period'], 28);
      expect(
        (trend['buckets'] as List).where((b) => b['has'] == true),
        hasLength(2),
      );
    },
  );

  test('3M stops at selected date and averages available days', () async {
    await scalar('2026-08-03', 50);
    await scalar('2026-10-02', 70);
    await scalar('2026-10-03', 90);
    await scalar('2026-10-20', 200); // after the anchor, must not leak in
    final trend = await repo.getTrend(
      'resting_hr',
      scale: 'quarter',
      anchor: '2026-10-19',
    );
    final summary = trend['summary'] as Map;
    expect(summary['avg'], 70);
    expect(summary['days_with_data'], 3);
    expect(summary['days_in_period'], 80);
    final buckets = trend['buckets'] as List;
    expect(buckets.map((b) => b['value']), [50, null, 80]);
    expect(
      buckets.last['t_end'],
      DateTime.utc(2026, 10, 20).millisecondsSinceEpoch ~/ 1000,
    );
  });

  test(
    'recorded HR includes live and historical partial days without sleep',
    () async {
      final ts = DateTime(2026, 10, 19, 12).millisecondsSinceEpoch ~/ 1000;
      await LocalDb.recordLiveHeartRate(ts, 60);
      await LocalDb.recordLiveHeartRate(ts + 1, 100);
      await (await LocalDb.instance).insert('decoded_onehz', {
        'counter': 1,
        'rec_ts': ts,
        'hr': 80,
        'ax': 0,
        'ay': 0,
        'az': 1,
        'spo2_red_raw': 0,
        'spo2_ir_raw': 0,
        'skin_temp_raw': 0,
      });
      for (final scale in ['week', 'month', 'quarter']) {
        final trend = await repo.getTrend(
          'hr',
          scale: scale,
          anchor: '2026-10-19',
        );
        expect((trend['summary'] as Map)['avg'], 90);
        expect((trend['summary'] as Map)['days_with_data'], 1);
        expect(trend['label'], 'recorded HR');
        expect(trend['unit'], 'bpm');
      }
      final resting = await repo.getTrend('resting_hr', anchor: '2026-10-19');
      expect((resting['summary'] as Map)['avg'], isNull);
    },
  );

  test(
    'pruned HR uses latest saved summary; measurements win on overlap',
    () async {
      final db = await LocalDb.instance;
      for (final version in [44, 45]) {
        await db.insert('day_result', {
          'day_id': '2026-10-17',
          'algo_version': version,
          'computed_at': 1,
          'payload_json': jsonEncode({
            'hr_stats': {'avg': version == 44 ? 200 : 70},
          }),
        });
      }
      final trend = await repo.getTrend('hr', anchor: '2026-10-19');
      expect((trend['summary'] as Map)['avg'], 70);
      await LocalDb.recordLiveHeartRate(
        DateTime(2026, 10, 17, 12).millisecondsSinceEpoch ~/ 1000,
        90,
      );
      final updated = await repo.getTrend('hr', anchor: '2026-10-19');
      expect((updated['summary'] as Map)['avg'], 90);
    },
  );

  test(
    'recorded HR respects local midnight and DST when bounding dates',
    () async {
      final start = DateTime(2026, 10, 25).millisecondsSinceEpoch ~/ 1000;
      final end = DateTime(2026, 10, 26).millisecondsSinceEpoch ~/ 1000;
      await LocalDb.recordLiveHeartRate(start - 1, 200);
      await LocalDb.recordLiveHeartRate(start, 60);
      await LocalDb.recordLiveHeartRate(end - 1, 100);
      await LocalDb.recordLiveHeartRate(end, 200);
      final series = await LocalDb.recordedHrSeries('2026-10-25', '2026-10-26');
      expect(series, hasLength(1));
      expect(series.single['date'], '2026-10-25');
      expect(series.single['value'], 80);
    },
  );

  test('zero is a real metric; no observations stays absent', () async {
    await scalar('2026-10-19', 0, key: 'strain');
    final zero = await repo.getTrend('strain', anchor: '2026-10-19');
    expect((zero['summary'] as Map)['avg'], 0);
    expect((zero['summary'] as Map)['days_with_data'], 1);
    final empty = await repo.getTrend('hr', anchor: '2026-10-19');
    expect((empty['summary'] as Map)['avg'], isNull);
    expect((empty['summary'] as Map)['days_with_data'], 0);
  });

  test(
    'comparison needs both complete periods, not just one day each',
    () async {
      for (var day = 6; day <= 19; day++) {
        await scalar(
          '2026-10-${day.toString().padLeft(2, '0')}',
          day < 13 ? 60 : 70,
        );
      }
      final full = await repo.getTrend('resting_hr', anchor: '2026-10-19');
      expect((full['summary'] as Map)['delta_vs_prev'], 10);
      expect((full['summary'] as Map)['partial'], isFalse);
      await (await LocalDb.instance).delete(
        'metric_series',
        where: 'date = ?',
        whereArgs: ['2026-10-13'],
      );
      final partial = await repo.getTrend('resting_hr', anchor: '2026-10-19');
      expect((partial['summary'] as Map)['avg'], 70);
      expect((partial['summary'] as Map)['delta_vs_prev'], isNull);
    },
  );

  for (final scale in ['week', 'month', 'quarter']) {
    testWidgets('$scale renders a sparse measured-zero period in both themes', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final count = scale == 'week'
          ? 7
          : scale == 'month'
          ? 4
          : 3;
      final periodDays = scale == 'week'
          ? 7
          : scale == 'month'
          ? 28
          : 80;
      for (final palette in [kLightPalette, kDarkPalette]) {
        AppColors.active = palette;
        var tapped = -1;
        await t.pumpWidget(
          MaterialApp(
            theme: buildOpenStrapTheme(palette),
            home: Scaffold(
              body: SingleChildScrollView(
                child: TrendBoard(
                  data: {
                    'summary': {
                      'avg': 0,
                      'days_with_data': 1,
                      'days_in_period': periodDays,
                    },
                    'buckets': [
                      for (var i = 0; i < count; i++)
                        {
                          'has': i == 0,
                          'value': i == 0 ? 0 : null,
                          'label': 'D$i',
                        },
                    ],
                  },
                  title: 'Strain',
                  icon: Ic.heart,
                  metric: 'strain',
                  scale: scale,
                  accent: AppColors.coral,
                  onTapBar: (i) => tapped = i,
                ),
              ),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 900));
        expect(find.text('No data in this period'), findsNothing);
        expect(
          find.text('Based on 1 of $periodDays days · partial period'),
          findsOneWidget,
        );
        expect(find.text('—'), findsNWidgets(count - 1));
        final bars = t.widget<LabeledBars>(find.byType(LabeledBars));
        expect(bars.present, [true, ...List.filled(count - 1, false)]);
        await t.tap(find.text('D0'));
        expect(tapped, 0);
        expect(t.takeException(), isNull);
      }
    });
  }

  testWidgets('Heart menu requests recorded HR rather than sleep-derived RHR', (
    t,
  ) async {
    late Widget screen;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            screen = const HeartScreen().build(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect((screen as MetricScreen).metric, 'hr');
  });
}
