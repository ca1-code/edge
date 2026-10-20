// Simple append-only file logger for field debugging.
//
// Writes to the app's external files dir on Android so it can be pulled with a
// plain `adb pull` (no run-as needed):
//   /storage/emulated/0/Android/data/wtf.openstrap.openstrap_edge/files/openstrap_sync.log

import 'dart:io';
import 'package:path_provider/path_provider.dart';

class FileLog {
  static File? _file;
  static bool _init = false;
  static Future<void> _tail = Future<void>.value();

  static Future<void> _ensure() async {
    if (_init) return;
    _init = true;
    try {
      final Directory dir = Platform.isAndroid
          ? (await getExternalStorageDirectory() ??
              await getApplicationDocumentsDirectory())
          : await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/openstrap_sync.log');
    } catch (_) {
      _file = null;
    }
  }

  static Future<void> write(String line) {
    final stamped = '${DateTime.now().toIso8601String()} $line';
    _tail = _tail.then((_) async {
      await _ensure();
      try {
        await _file?.writeAsString(
          '$stamped\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {}
    });
    return _tail;
  }

  static Future<String?> path() async {
    await _ensure();
    return _file?.path;
  }

  static Future<void> clear() {
    _tail = _tail.then((_) async {
      await _ensure();
      try {
        await _file?.writeAsString('');
      } catch (_) {}
    });
    return _tail;
  }
}
