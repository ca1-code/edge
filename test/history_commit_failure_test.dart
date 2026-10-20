import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/models.dart';

void main() {
  test(
    'failed history commit propagates and retains the unacknowledged chunk',
    () async {
      var fail = true;
      final saved = <int>[];
      final d = HistoricalDrainController(
        onRecord: (_, __) async {},
        onRecordsBatch: null,
        onArchive: null,
        log: (_) {},
        onCommit: (raws, samples, token, {archives}) async {
          if (fail) throw StateError('disk full');
          saved.addAll(raws.map((r) => r.counter));
        },
      );
      d.onHistoricalRecord(
        RawRecord(
          counter: 7,
          hex: '00',
          packetType: 47,
          capturedAt: 1,
          recTs: 1789804358,
        ),
        null,
      );
      await expectLater(d.commit([1, 2, 3, 4, 5, 6, 7, 8]), throwsStateError);
      expect(d.bufferedRecords, 1);
      expect(saved, isEmpty);
      fail = false;
      await d.commit([1, 2, 3, 4, 5, 6, 7, 8]);
      expect(saved, [7]);
      expect(d.bufferedRecords, 0);
    },
  );
}
