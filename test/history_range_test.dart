import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/history_range.dart';

void main() {
  test(
    'guessed protocol timestamps cannot restrict WHOOP 5 record admission',
    () {
      final decoded = <String, dynamic>{
        'opcode': 22,
        'range_oldest': 1789800000,
        'range_newest': 1795162238,
        'history_oldest': 1789800000,
        'history_newest': 1795162238,
        'pages_behind': {'capacity': 131072},
        'raw_hex': 'captured payload',
      };
      final safe = withoutUnverifiedHistoryRange(decoded);
      expect(safe, {'opcode': 22, 'raw_hex': 'captured payload'});
      expect(decoded['range_newest'], 1795162238);
    },
  );
}
