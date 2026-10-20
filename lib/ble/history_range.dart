/// WHOOP 5 GET_DATA_RANGE offsets are unverified. The shared protocol decoder
/// scans arbitrary bytes for Unix-looking integers; these must never narrow
/// record admission or imply an outstanding backlog. Keep the response itself
/// for diagnostics while removing inferred time/ring-buffer fields.
Map<String, dynamic> withoutUnverifiedHistoryRange(
  Map<String, dynamic> fields,
) {
  return Map<String, dynamic>.from(fields)
    ..remove('range_oldest')
    ..remove('range_newest')
    ..remove('history_oldest')
    ..remove('history_newest')
    ..remove('pages_behind');
}
