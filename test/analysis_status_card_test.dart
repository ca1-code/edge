import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui/today/analysis_status_card.dart';

void main() {
  testWidgets(
    'completed old days lead to history instead of another analysis loop',
    (tester) async {
      var history = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnalysisStatusCard(
              analysis: const {
                'saved_days': 3,
                'sensor_days': 3,
                'pending_days': 0,
                'first_sensor_day': '2020-09-03',
                'latest_sensor_day': '2020-09-05',
              },
              onAnalyze: () => fail('Already analyzed'),
              onHistory: () => history = true,
            ),
          ),
        ),
      );
      expect(find.text('Saved history analyzed'), findsOneWidget);
      expect(find.text('Analyze saved days'), findsNothing);
      await tester.tap(find.text('View recorded days'));
      expect(history, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending days expose analysis and processing uses the exact progress text',
    (tester) async {
      var analyzed = false;
      Widget card({bool running = false}) => MaterialApp(
        home: Scaffold(
          body: AnalysisStatusCard(
            analysis: const {
              'saved_days': 3,
              'sensor_days': 3,
              'pending_days': 2,
              'first_sensor_day': '2020-09-03',
              'latest_sensor_day': '2020-09-05',
            },
            running: running,
            progress: 'Processing 2/3 days',
            onAnalyze: () => analyzed = true,
            onHistory: () {},
          ),
        ),
      );
      await tester.pumpWidget(card());
      await tester.tap(find.text('Analyze saved days'));
      expect(analyzed, isTrue);
      await tester.pumpWidget(card(running: true));
      expect(find.text('Processing 2/3 days'), findsOneWidget);
      expect(find.text('Analyze saved days'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
