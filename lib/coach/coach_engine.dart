// CoachEngine — the agentic core. Talks to Anthropic or a compatible provider directly
// (BYOK), runs a tool-calling loop over read-only data tools + a plot tool + action
// tools (writes require user confirmation), and streams items back to the UI.
//
// Data flow: user asks → model calls data tools (we read via the LocalRepository
// seam) → model reasons → optionally calls plot_chart with a figure it built →
// optionally proposes an action (we confirm) → model returns the final text.
//
// CLOUD EXCISED: the data tools used to hit the authed backend via ApiClient. They
// now go through LocalRepository (lib/data/local_repository.dart) — the same
// surface, implemented on-device by the future analytics re-layer. The LLM call
// itself still uses `http` directly (BYOK, the user's own provider — not our backend).

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../data/day_label.dart';
import '../data/local_repository.dart';
import 'coach_config.dart';
import 'coach_db.dart';
import 'coach_prompt.dart';
import 'anthropic_messages.dart';

// ── value types ──────────────────────────────────────────────────────────────

/// A figure the model built from data it fetched; the app renders it animated.
class ChartSpec {
  final String type; // 'bar' | 'line' | 'area'
  final String title;
  final List<String> xLabels;
  final List<ChartSeries> series;
  final String unit;
  final String? note;
  ChartSpec({
    required this.type,
    required this.title,
    required this.xLabels,
    required this.series,
    this.unit = '',
    this.note,
  });

  // Some OpenAI-compatible models (e.g. minimax via NVIDIA NIM) wrap array params
  // as {"item":[...]} and emit numbers as strings. Be liberal in what we accept.
  static List<dynamic> _asList(dynamic v) {
    if (v is List) return v;
    if (v is Map && v['item'] is List) return v['item'] as List;
    if (v is Map && v['items'] is List) return v['items'] as List;
    return const [];
  }

  static double? _asNum(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) {
      final d = double.tryParse(v.trim());
      if (d != null) return d;
      // tolerate "62 ms", units glued on, etc. — take the first number found.
      final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(v);
      return m == null ? null : double.tryParse(m.group(0)!);
    }
    if (v is Map) return _asNum(v['value'] ?? v['y'] ?? v['v']); // {value:62}/{y:62}
    return null;
  }

  Map<String, dynamic> toJson() => {
        'type': type, 'title': title, 'x_labels': xLabels, 'unit': unit, 'note': note,
        'series': series.map((s) => {'name': s.name, 'values': s.values}).toList(),
      };

  static ChartSpec? tryParse(Map<String, dynamic> j) {
    try {
      final rawSeries = _asList(j['series']);
      final series = rawSeries.whereType<Map>().map((s) {
        final vals = _asList(s['values'] ?? s['data'] ?? s['y']).map(_asNum).toList();
        return ChartSeries(name: (s['name'] ?? s['label'] ?? '').toString(), values: vals);
      }).where((s) => s.values.any((v) => v != null)).toList(); // drop all-null series
      if (series.isEmpty) return null;
      final xs = _asList(j['x_labels'] ?? j['labels'] ?? j['x']).map((e) => '$e').toList();
      return ChartSpec(
        type: (j['type'] ?? 'bar').toString(),
        title: (j['title'] ?? '').toString(),
        xLabels: xs,
        series: series,
        unit: (j['unit'] ?? j['y_unit'] ?? '').toString(),
        note: j['note']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

class ChartSeries {
  final String name;
  final List<double?> values;
  ChartSeries({required this.name, required this.values});
}

/// A write the model wants to perform — surfaced to the user for confirmation.
class ActionRequest {
  final String tool;
  final String title;     // e.g. "Log a period"
  final String summary;   // human description of exactly what will happen
  final Map<String, dynamic> args;
  ActionRequest({required this.tool, required this.title, required this.summary, required this.args});
}

/// One rendered chat item.
enum CoachItemKind { user, assistant, chart, render, error }

class CoachItem {
  final CoachItemKind kind;
  final String? text;
  final ChartSpec? chart;
  /// Generic render spec ({type, title?, ...payload}) drawn by [CoachRender].
  final Map<String, dynamic>? render;
  CoachItem.user(this.text) : kind = CoachItemKind.user, chart = null, render = null;
  CoachItem.assistant(this.text) : kind = CoachItemKind.assistant, chart = null, render = null;
  CoachItem.error(this.text) : kind = CoachItemKind.error, chart = null, render = null;
  CoachItem.chart(this.chart) : kind = CoachItemKind.chart, text = null, render = null;
  CoachItem.render(this.render) : kind = CoachItemKind.render, text = null, chart = null;

  Map<String, dynamic> toJson() =>
      {'kind': kind.name, 'text': text, 'chart': chart?.toJson(), 'render': render};

  static CoachItem fromJson(Map<String, dynamic> j) {
    final k = j['kind'];
    if (k == 'chart' && j['chart'] is Map) {
      final c = ChartSpec.tryParse((j['chart'] as Map).cast<String, dynamic>());
      if (c != null) return CoachItem.chart(c);
    }
    if (k == 'render' && j['render'] is Map) {
      return CoachItem.render((j['render'] as Map).cast<String, dynamic>());
    }
    final t = j['text']?.toString();
    if (k == 'user') return CoachItem.user(t);
    if (k == 'error') return CoachItem.error(t);
    return CoachItem.assistant(t);
  }
}

/// Lightweight index entry for a saved chat session (for the history list).
class CoachSessionMeta {
  final String id;
  final String title;
  final int updatedAt; // ms since epoch
  final String preview;
  CoachSessionMeta(this.id, this.title, this.updatedAt, this.preview);
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'updatedAt': updatedAt, 'preview': preview};
  static CoachSessionMeta fromJson(Map<String, dynamic> j) => CoachSessionMeta(
        (j['id'] ?? '').toString(), (j['title'] ?? '').toString(),
        (j['updatedAt'] as num?)?.toInt() ?? 0, (j['preview'] ?? '').toString());
}

// ── engine ───────────────────────────────────────────────────────────────────

class CoachEngine {
  final CoachConfig config;
  final LocalRepository api;
  final String storageKey; // per-user, so accounts don't share a transcript
  final http.Client _http;

  // OpenAI-format running history (system is added per-request) — the context we
  // resend every turn so the model remembers the conversation.
  final List<Map<String, dynamic>> _history = [];

  // Serializable display transcript (text bubbles + charts) shown in the UI.
  final List<CoachItem> transcript = [];

  // Current session identity (sessions are persisted per-user, many per user).
  String _sessionId = '';
  String _title = '';
  int _createdAt = 0;
  String get sessionId => _sessionId;

  final Random _rand = Random();
  static const List<String> _shenanigans = [
    'Reading your overnight RR…',
    'Doing the Banister math…',
    'Asking your heart rate a few questions…',
    'Decoding last night…',
    'Auditing 90 days of you…',
    'Letting the data confess…',
    'Lining up the z-scores…',
    'Chasing a hunch through your HRV…',
    'Pulling the thread…',
  ];

  CoachEngine({required this.config, required this.api, this.storageKey = 'anon',
    http.Client? client}) : _http = client ?? http.Client();

  void reset() { _history.clear(); transcript.clear(); }
  bool get hasHistory => _history.isNotEmpty;

  Future<Directory> _dir() => getApplicationDocumentsDirectory();
  Future<File> _sessionFile(String id) async => File('${(await _dir()).path}/coach_s_${storageKey}_$id.json');
  Future<File> _indexFile() async => File('${(await _dir()).path}/coach_idx_$storageKey.json');
  String _newId() => '${DateTime.now().millisecondsSinceEpoch}';

  /// All saved sessions for this user, most recent first.
  Future<List<CoachSessionMeta>> listSessions() async {
    try {
      final f = await _indexFile();
      if (!await f.exists()) return [];
      final list = (jsonDecode(await f.readAsString()) as List)
          .map((e) => CoachSessionMeta.fromJson((e as Map).cast<String, dynamic>())).toList();
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list;
    } catch (_) {
      return [];
    }
  }

  /// On open: resume the most recent session, or start fresh if none.
  Future<void> restore() async {
    final metas = await listSessions();
    if (metas.isEmpty) {
      newSession();
      return;
    }
    await openSession(metas.first.id);
  }

  /// Start a brand-new conversation (not written to disk until first message).
  void newSession() {
    _sessionId = _newId();
    _title = '';
    _createdAt = 0;
    _history.clear();
    transcript.clear();
  }

  /// Load a specific session into the working set.
  Future<void> openSession(String id) async {
    try {
      final f = await _sessionFile(id);
      if (!await f.exists()) {
        newSession();
        return;
      }
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _sessionId = id;
      _title = (j['title'] ?? '').toString();
      _createdAt = (j['createdAt'] as num?)?.toInt() ?? 0;
      _history
        ..clear()
        ..addAll(((j['history'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()));
      transcript
        ..clear()
        ..addAll(((j['transcript'] as List?) ?? const [])
            .map((e) => CoachItem.fromJson((e as Map).cast<String, dynamic>())));
    } catch (_) {
      newSession();
    }
  }

  /// Persist the current session (caps history, updates the index).
  Future<void> persist() async {
    if (transcript.isEmpty) return;
    if (_sessionId.isEmpty) _sessionId = _newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_createdAt == 0) _createdAt = now;
    if (_title.isEmpty) _title = _deriveTitle();
    if (_history.length > 60) {
      // Keep complete turns: starting on a tool result loses its required
      // preceding assistant tool call and Anthropic rejects the next request.
      final start = _history.indexWhere(
          (m) => m['role'] == 'user', _history.length - 60);
      if (start > 0) _history.removeRange(0, start);
    }
    try {
      final f = await _sessionFile(_sessionId);
      await f.writeAsString(jsonEncode({
        'title': _title, 'createdAt': _createdAt, 'updatedAt': now,
        'history': _history, 'transcript': transcript.map((e) => e.toJson()).toList(),
      }));
      await _updateIndex(_sessionId, _title, now, _preview());
    } catch (_) {}
  }

  Future<void> _updateIndex(String id, String title, int updatedAt, String preview) async {
    final metas = await listSessions();
    metas.removeWhere((m) => m.id == id);
    metas.insert(0, CoachSessionMeta(id, title, updatedAt, preview));
    final keep = metas.take(30).toList();
    for (final d in metas.skip(30)) {
      try {
        final f = await _sessionFile(d.id);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    try {
      final f = await _indexFile();
      await f.writeAsString(jsonEncode(keep.map((m) => m.toJson()).toList()));
    } catch (_) {}
  }

  /// Delete a session (and start fresh if it was the current one).
  Future<void> deleteSession(String id) async {
    try {
      final f = await _sessionFile(id);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    final metas = await listSessions()..removeWhere((m) => m.id == id);
    try {
      final f = await _indexFile();
      await f.writeAsString(jsonEncode(metas.map((m) => m.toJson()).toList()));
    } catch (_) {}
    if (id == _sessionId) newSession();
  }

  String _deriveTitle() {
    for (final it in transcript) {
      if (it.kind == CoachItemKind.user && (it.text ?? '').trim().isNotEmpty) {
        final t = it.text!.trim();
        return t.length > 40 ? '${t.substring(0, 40)}…' : t;
      }
    }
    return 'New chat';
  }

  String _preview() {
    for (final it in transcript.reversed) {
      final t = it.text?.trim();
      if (t != null && t.isNotEmpty) return t.length > 80 ? '${t.substring(0, 80)}…' : t;
    }
    return '';
  }

  /// Live model list from the provider's /models endpoint (OpenAI-compatible).
  /// Static so Settings can probe an as-yet-unsaved base URL + key.
  static Future<List<String>> fetchModels(String apiBase, String apiKey,
      {http.Client? client}) async {
    final b = CoachConfig.normalizeBase(apiBase);
    // Anthropic's native Models API authenticates with x-api-key +
    // anthropic-version (a bearer token is rejected) and paginates with
    // has_more/last_id, but its response shape (data[].id) matches OpenAI's.
    final isAnthropic = CoachConfig.providerForBase(b) == CoachProvider.anthropic;
    final ids = <String>[];
    String? after;
    final seenPages = <String>{};
    final c = client ?? http.Client();
    try {
    do {
      final uri = Uri.parse('$b/models').replace(queryParameters: isAnthropic
          ? {'limit': '1000', 'after_id': ?after}
          : null);
      final resp = await c.get(
        uri,
        headers: isAnthropic
            ? {'x-api-key': apiKey, 'anthropic-version': '2023-06-01'}
            : {'Authorization': 'Bearer $apiKey'},
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw _providerError(resp, apiKey);
      }
      final j = jsonDecode(resp.body);
      final data = (j['data'] as List?) ?? const [];
      ids.addAll(data
          .map((e) => (e as Map)['id']?.toString() ?? '')
          .where((s) => s.isNotEmpty));
      after = (isAnthropic && j['has_more'] == true) ? j['last_id']?.toString() : null;
      if (after != null && !seenPages.add(after)) {
        throw CoachException('Provider returned a repeated model page. Try again.');
      }
    } while (after != null);
    } on TimeoutException {
      throw CoachException('The provider did not respond in time. Check your connection and try again.');
    } finally {
      if (client == null) c.close();
    }
    ids.sort();
    return ids.toSet().toList();
  }

  // LOCAL day label — the coach's SQL views (v_daily/v_metric/…) are keyed by
  // the device-local dates the derivation engine files days under, so "today"
  // must be local too (a UTC date here pointed the model one day back until
  // ~05:30 for a UTC+5:30 user).
  static String _today() => todayLabel();

  /// Run one user turn. Emits items via [onItem]; reports the current tool via
  /// [onStatus]; asks the user to confirm writes via [confirm] (returns true to
  /// proceed). Returns when the model produces its final answer (or hits the cap).
  Future<void> send(
    String userText, {
    required void Function(CoachItem) onItem,
    required void Function(String?) onStatus,
    required Future<bool> Function(ActionRequest) confirm,
  }) async {
    void emit(CoachItem it) { transcript.add(it); onItem(it); }
    emit(CoachItem.user(userText));
    _history.add({'role': 'user', 'content': userText});

    const maxIters = 10;
    for (var i = 0; i < maxIters; i++) {
      onStatus(_shenanigans[_rand.nextInt(_shenanigans.length)]);
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': '$kCoachSystemPrompt\n\nToday is ${_today()} (device-local date; all day-keyed data uses these local dates).'},
        ..._history,
      ];

      final reply = await _chat(messages);
      final toolCalls = (reply['tool_calls'] as List?) ?? const [];
      final content = (reply['content'] as String?)?.trim();

      if (toolCalls.isEmpty) {
        if (content != null && content.isNotEmpty) _emitAssistantText(content, emit);
        _history.add({'role': 'assistant', 'content': content ?? '',
          if (reply[AnthropicMessages.nativeContentKey] != null)
            AnthropicMessages.nativeContentKey: reply[AnthropicMessages.nativeContentKey],
        });
        onStatus(null);
        return;
      }

      // Assistant turn that requested tools (echo any interim text).
      if (content != null && content.isNotEmpty) _emitAssistantText(content, emit);
      _history.add({'role': 'assistant', 'content': content ?? '', 'tool_calls': toolCalls,
        if (reply[AnthropicMessages.nativeContentKey] != null)
          AnthropicMessages.nativeContentKey: reply[AnthropicMessages.nativeContentKey],
      });

      for (final tcRaw in toolCalls) {
        final tc = tcRaw as Map;
        final id = tc['id']?.toString() ?? '';
        final fn = (tc['function'] as Map?) ?? const {};
        final name = fn['name']?.toString() ?? '';
        Map<String, dynamic> args = {};
        try {
          final a = fn['arguments'];
          if (a is String && a.isNotEmpty) {
            args = jsonDecode(a) as Map<String, dynamic>;
          } else if (a is Map) {
            args = a.cast<String, dynamic>();
          }
        } catch (_) {}

        onStatus(_statusFor(name, args));
        final result = await _runTool(name, args, onItem: emit, confirm: confirm);
        _history.add({'role': 'tool', 'tool_call_id': id, 'name': name, 'content': result});
      }
    }
    emit(CoachItem.assistant('I dug through several steps but couldn’t wrap that up — try narrowing the question.'));
    onStatus(null);
  }

  // Some providers (esp. ones with shaky tool-calling) sometimes answer with a
  // fenced JSON code block instead of actually calling plot_chart/render — that
  // renders as an unexplained grey code block in the UI (GptMarkdown's default
  // code-field styling), not a chart. Detect a chart/render JSON payload inside
  // any fence and draw it as a real figure instead; leave real code fences (rare,
  // the coach is told never to write code) or non-figure JSON untouched.
  static void _emitAssistantText(String content, void Function(CoachItem) emit) {
    final fence = RegExp(r'```[a-zA-Z0-9_-]*\n([\s\S]*?)```');
    final figures = <CoachItem>[];
    final cleaned = content.replaceAllMapped(fence, (m) {
      try {
        final decoded = jsonDecode((m.group(1) ?? '').trim());
        if (decoded is Map && decoded['type'] != null) {
          final j = decoded.cast<String, dynamic>();
          final type = j['type'].toString().toLowerCase();
          if ((type == 'bar' || type == 'line' || type == 'area') && j['series'] != null) {
            final spec = ChartSpec.tryParse(j);
            if (spec != null) {
              figures.add(CoachItem.chart(spec));
              return '';
            }
          }
          figures.add(CoachItem.render(j));
          return '';
        }
      } catch (_) {
        // not JSON / not a figure — leave the fence as-is.
      }
      return m.group(0) ?? '';
    }).trim();
    if (cleaned.isNotEmpty) emit(CoachItem.assistant(cleaned));
    for (final f in figures) {
      emit(f);
    }
  }

  // ── provider call ────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> _chat(List<Map<String, dynamic>> messages) =>
      postChat(config, {
        'model': config.model,
        'messages': messages,
        'tools': _toolDefs,
        'tool_choice': 'auto',
        'temperature': 0.3,
      }, client: _http);

  /// True when [model] names a Claude version that rejects OpenAI sampling
  /// params (temperature/top_p/top_k) with a 400: Opus >= 4.7, Sonnet and
  /// Haiku >= 5, and the Fable/Mythos family. Claude is served under many
  /// provider namings — bare "claude-…", OpenRouter "anthropic/claude-…",
  /// Bedrock-style "anthropic.claude-…-v1:0" — with "-" or "." version
  /// separators, so match the id anywhere and parse family + version instead
  /// of keying off a prefix. Older Claude models still accept sampling and are
  /// deliberately excluded, as is every non-Claude model. Public for tests.
  static bool claudeRejectsSampling(String model) {
    final m = model.toLowerCase();
    final i = m.indexOf('claude');
    if (i < 0) return false;
    final id = m.substring(i);
    if (id.startsWith('claude-fable') || id.startsWith('claude-mythos')) {
      return true;
    }
    // Minor is capped at 2 digits with no digit following, so a date suffix
    // (claude-opus-4-20250514) never parses as a minor version.
    final v =
        RegExp(r'^claude-(opus|sonnet|haiku)[-.](\d+)(?:[-.](\d{1,2})(?!\d))?')
            .firstMatch(id);
    // Legacy version-first ids (claude-3-5-sonnet-…) all accept sampling.
    if (v == null) return false;
    final major = int.parse(v.group(2)!);
    final minor = int.tryParse(v.group(3) ?? '') ?? 0;
    if (v.group(1) == 'opus') {
      return major > 4 || (major == 4 && minor >= 7);
    }
    return major >= 5; // sonnet, haiku
  }

  /// Shared provider POST. Every LLM call in the app
  /// (the coach tool loop, the daily briefings, the journal chat) goes through
  /// here so there is exactly ONE provider client + error contract. Returns the
  /// first choice's `message` map. Throws [CoachException] on any provider error.
  static Future<Map<String, dynamic>> postChat(
    CoachConfig config,
    Map<String, dynamic> body, {
    http.Client? client,
  }) async {
    if (config.apiKey?.trim().isNotEmpty != true) {
      throw CoachException('Add your API key in AI Coach settings first.');
    }
    final c = client ?? http.Client();
    // Recent Claude models reject sampling params with a 400, on Anthropic's
    // own endpoint and through any pass-through provider alike. Strip them for
    // exactly those model versions; older Claude models and every other
    // provider keep their sampling params untouched.
    if (claudeRejectsSampling(body['model'] as String? ?? '')) {
      body = {...body}
        ..remove('temperature')
        ..remove('top_p')
        ..remove('top_k');
    }
    try {
      final native = config.provider == CoachProvider.anthropic;
      final payload = native
          ? AnthropicMessages.request(body)
          : AnthropicMessages.openAiRequest(body);
      final resp = await c
          .post(
            Uri.parse('${config.apiBase}/${native ? 'messages' : 'chat/completions'}'),
            headers: {
              if (native) ...{
                'x-api-key': config.apiKey!,
                'anthropic-version': '2023-06-01',
              } else 'Authorization': 'Bearer ${config.apiKey}',
              'content-type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 120));
      if (resp.statusCode != 200) {
        throw _providerError(resp, config.apiKey!);
      }
      final j = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      if (native) {
        if (j['stop_reason'] == 'max_tokens') {
          throw CoachException('Claude reached its response limit. Try a narrower question or choose another model.');
        }
        final message = AnthropicMessages.response(j);
        if ((message['content'] as String).isEmpty &&
            (message['tool_calls'] as List).isEmpty) {
          throw CoachException('Claude returned no answer. Try again or choose another model.');
        }
        return message;
      }
      final choices = (j['choices'] as List?) ?? const [];
      if (choices.isEmpty) throw CoachException('Empty response from provider.');
      return (choices.first as Map)['message'] as Map<String, dynamic>;
    } on TimeoutException {
      throw CoachException('The provider did not respond in time. Check your connection and try again.');
    } on FormatException {
      throw CoachException('The provider returned an unreadable response. Check your model and provider settings.');
    } finally {
      if (client == null) c.close();
    }
  }

  /// One-shot multi-turn text completion (no tools). Reuses [postChat] — the
  /// briefing + journal engines call this instead of owning an HTTP client.
  static Future<String> chatOnce({
    required CoachConfig config,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.4,
    http.Client? client,
  }) async {
    final msg = await postChat(config, {
      'model': config.model,
      'messages': messages,
      'temperature': temperature,
    }, client: client);
    return ((msg['content'] as String?) ?? '').trim();
  }

  /// One-shot "system + user → text" completion. The simplest reuse surface.
  static Future<String> completeText({
    required CoachConfig config,
    required String system,
    required String user,
    double temperature = 0.4,
  }) =>
      chatOnce(config: config, temperature: temperature, messages: [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ]);

  static String _briefErr(String body) {
    try {
      final j = jsonDecode(body);
      return (j['error']?['message'] ?? body).toString();
    } catch (_) {
      return body.length > 300 ? body.substring(0, 300) : body;
    }
  }

  static CoachException _providerError(http.Response response, String apiKey) {
    final advice = switch (response.statusCode) {
      401 => 'The API key was rejected. Check the key and selected provider.',
      403 => 'This key does not have access. Check its provider permissions.',
      404 => 'The model or endpoint was not found. Fetch the available models in AI Coach settings.',
      429 => 'The provider has reached a usage or rate limit. Check your API balance and retry later.',
      529 => 'Claude is temporarily busy. Please try again shortly.',
      _ => 'Provider request failed.',
    };
    var detail = _briefErr(response.body);
    if (apiKey.isNotEmpty) detail = detail.replaceAll(apiKey, '[redacted]');
    if (detail.length > 300) detail = '${detail.substring(0, 300)}…';
    return CoachException('$advice (${response.statusCode}) $detail');
  }

  // ── tool execution ───────────────────────────────────────────────────────────
  Future<String> _runTool(
    String name,
    Map<String, dynamic> args, {
    required void Function(CoachItem) onItem,
    required Future<bool> Function(ActionRequest) confirm,
  }) async {
    try {
      switch (name) {
        // data — one read-only SQL tool over the derived views
        case 'run_sql':
          return await CoachDb.runCoachSql('${args['sql'] ?? ''}');

        // plot — legacy bar/line/area figure
        case 'plot_chart':
          final spec = ChartSpec.tryParse(args);
          if (spec == null) return 'Could not parse figure; check the schema.';
          onItem(CoachItem.chart(spec));
          return 'Chart rendered for the user.';

        // render — rich typed widget spec ({type, title?, ...payload})
        case 'render':
          if (args['type'] == null) return 'render needs a "type" field.';
          onItem(CoachItem.render(Map<String, dynamic>.from(args)));
          return 'Rendered "${args['type']}" for the user.';

        // actions (confirmed)
        case 'log_journal':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Log journal',
            summary: 'Add journal for ${args['date']}: tags ${args['tags'] ?? []}, note "${args['note'] ?? ''}".',
            args: args,
          ), () async {
            await api.postJournal('${args['date']}',
                ((args['tags'] as List?) ?? const []).map((e) => '$e').toList(), '${args['note'] ?? ''}');
            return 'Journal saved.';
          });
        case 'log_period':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Log period',
            summary: 'Log a period start on ${args['date']}.', args: args,
          ), () async { await api.postCycleLog('${args['date']}', kind: 'start'); return 'Period logged.'; });
        case 'start_workout':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Start workout',
            summary: 'Start a ${args['type'] ?? 'workout'} session now.', args: args,
          ), () async { final r = await api.startWorkout('${args['type'] ?? 'other'}'); return _enc(r); });
        case 'end_workout':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'End workout',
            summary: 'End the active workout.', args: args,
          ), () async { final r = await api.endWorkout('${args['workout_id']}'); return _enc(r); });
        case 'set_step_goal':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Set step goal',
            summary: 'Set your daily step goal to ${args['goal']}.', args: args,
          ), () async { await api.setStepGoal((args['goal'] as num).toInt()); return 'Step goal updated.'; });

        default:
          return 'Unknown tool: $name';
      }
    } catch (e) {
      return 'Tool $name failed: ${e is RepositoryException ? e.body : e}';
    }
  }

  Future<String> _action(
    Future<bool> Function(ActionRequest) confirm,
    ActionRequest req,
    Future<String> Function() run,
  ) async {
    final ok = await confirm(req);
    if (!ok) return 'User declined the action. Do not retry it.';
    return await run();
  }

  String _enc(Object? data) {
    final s = jsonEncode(data);
    return s.length > 16000 ? '${s.substring(0, 16000)}…(truncated)' : s;
  }

  String _statusFor(String name, Map<String, dynamic> args) {
    switch (name) {
      case 'run_sql': return 'Querying your data…';
      case 'plot_chart': return 'Plotting…';
      case 'render': return 'Rendering ${args['type'] ?? 'figure'}…';
      default: return 'Working…';
    }
  }

  void dispose() => _http.close();

  // ── tool schema (OpenAI format) ───────────────────────────────────────────────
  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, [List<String> required = const []]) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': required},
        },
      };

  static final List<Map<String, dynamic>> _toolDefs = [
    _fn('run_sql',
        'Read your health data by running ONE read-only SQLite SELECT over the '
        'derived views. Views & columns: '
        'v_metric(date,key,value); '
        'v_daily(date,resting_hr,hrv,sdnn,readiness,strain,resp_rate,stress,'
        'sleep_efficiency,sleep_min,deep_min,rem_min,light_min,nap_min,steps,'
        'active_calories,total_calories,skin_temp_z,lf_hf,hrv_cv,dip_pct,'
        'odi_per_hour,worn_min,hrr_bpm,brv_cv,irregular_flag); '
        'v_series(date,series,t,v) — series ∈ hr_curve,strain_curve,hrv_timeline,'
        'hrv_day,resp_day,skin_temp_day,zone_timeline,activity_curve; ALWAYS filter '
        'WHERE date=\'YYYY-MM-DD\' AND series=\'…\'; '
        'v_hypnogram(date,start_ts,end_ts,stage); '
        'v_sessions(id,start_ts,end_ts,type,status,calories,strain,max_hr,'
        'duration_min,steps,hrr_bpm,source,zone_min_json); '
        'v_baselines(key,value,mean,z,delta,ratio,n,updated_at); '
        'v_insights(id,kind,title,body,date,created_at,read). '
        'Read-only, derived only — no other tables. Dates are \'YYYY-MM-DD\'; '
        'timestamps are epoch seconds. Prefer aggregates (AVG/MIN/MAX/COUNT) over '
        'SELECT *. Results are capped at 200 rows.',
        {'sql': {'type': 'string', 'description': 'a single SELECT statement'}},
        ['sql']),
    _fn('plot_chart', 'Render a simple chart from data you fetched (bar/line/area). Build the figure yourself.', {
      'type': {'type': 'string', 'enum': ['bar', 'line', 'area']},
      'title': {'type': 'string'},
      'x_labels': {'type': 'array', 'items': {'type': 'string'}},
      'series': {'type': 'array', 'items': {'type': 'object', 'properties': {
        'name': {'type': 'string'},
        'values': {'type': 'array', 'items': {'type': ['number', 'null']}},
      }}},
      'unit': {'type': 'string'},
      'note': {'type': 'string'},
    }, ['type', 'x_labels', 'series']),
    _fn('render',
        'Render a RICH figure from data you fetched. Pick a "type" and provide its '
        'payload. Types: line/area/bar/multi_series {x_labels,series:[{name,values}],unit}; '
        'scatter {points:[{x,y,label?}],x_label,y_label}; '
        'dual_axis {x_labels,left:{name,values,unit},right:{name,values,unit}}; '
        'stacked_zone_bar {x_labels,zones:[{name,values}]}; '
        'hypnogram {segments:[{start,end,stage}]} (stage∈wake|light|deep|rem, epoch sec); '
        'kpi_grid {cards:[{label,value,unit?,delta?,baseline?,spark?:[n]}]}; '
        'gauge {value,min?,max?,label?,unit?}; '
        'heatmap {rows:[label],cols:[label],values:[[n]],unit?}; '
        'range_band {label,value,min,max,unit?}; '
        'table {columns:[..],rows:[[..]]}. Always include a "title".',
        {
          'type': {'type': 'string'},
          'title': {'type': 'string'},
        }, ['type']),
    _fn('log_journal', 'Log a journal entry (asks the user to confirm).', {
      'date': {'type': 'string'}, 'tags': {'type': 'array', 'items': {'type': 'string'}}, 'note': {'type': 'string'},
    }, ['date']),
    _fn('log_period', 'Log a period start (asks the user to confirm).', {'date': {'type': 'string'}}, ['date']),
    _fn('start_workout', 'Start a live workout (asks the user to confirm).', {'type': {'type': 'string'}}),
    _fn('end_workout', 'End the active workout (asks the user to confirm).', {'workout_id': {'type': 'string'}}, ['workout_id']),
    _fn('set_step_goal', 'Set the daily step goal (asks the user to confirm).', {'goal': {'type': 'integer'}}, ['goal']),
  ];
}

class CoachException implements Exception {
  final String message;
  CoachException(this.message);
  @override
  String toString() => message;
}
