import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/coach/anthropic_messages.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

class TestConfig extends CoachConfig {
  final bool native;
  TestConfig({this.native = true});
  @override
  String get apiBase =>
      native ? CoachConfig.anthropicBaseUrl : CoachConfig.defaultBaseUrl;
  @override
  String get model => native ? CoachConfig.anthropicDefaultModel : 'test-model';
  @override
  String get apiKey => 'sk-ant-test-only';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native tool loop preserves blocks and returns parallel tool results',
    () async {
      var requests = 0;
      final blocks = [
        {'type': 'thinking', 'thinking': 'test', 'signature': 'signature'},
        {
          'type': 'tool_use',
          'id': 'one',
          'name': 'render',
          'input': {'type': 'note', 'text': 'First'},
        },
        {
          'type': 'tool_use',
          'id': 'two',
          'name': 'render',
          'input': {'type': 'note', 'text': 'Second'},
        },
      ];
      final client = MockClient((request) async {
        requests++;
        expect(
          request.url.toString(),
          '${CoachConfig.anthropicBaseUrl}/messages',
        );
        expect(request.headers['x-api-key'], 'sk-ant-test-only');
        expect(request.headers['anthropic-version'], '2023-06-01');
        expect(request.headers.containsKey('authorization'), isFalse);
        final body = jsonDecode(request.body) as Map;
        expect(body['system'], isNotEmpty);
        expect(body['max_tokens'], greaterThan(0));
        expect(body.containsKey('temperature'), isFalse);
        expect((body['tools'] as List).first['input_schema'], isA<Map>());
        expect(body['tool_choice'], {'type': 'auto'});
        if (requests == 1) {
          return http.Response(
            jsonEncode({'content': blocks, 'stop_reason': 'tool_use'}),
            200,
          );
        }
        final messages = body['messages'] as List;
        expect(messages[messages.length - 2]['content'], blocks);
        expect(messages.last['role'], 'user');
        expect(
          (messages.last['content'] as List).map((e) => e['tool_use_id']),
          ['one', 'two'],
        );
        return http.Response(
          jsonEncode({
            'content': [
              {'type': 'text', 'text': 'Finished.'},
            ],
            'stop_reason': 'end_turn',
          }),
          200,
        );
      });
      final engine = CoachEngine(
        config: TestConfig(),
        api: LocalRepositoryImpl(getProfileMap: () => null),
        client: client,
      );
      final items = <CoachItem>[];
      await engine.send(
        'Show my data',
        onItem: items.add,
        onStatus: (_) {},
        confirm: (_) async => false,
      );
      expect(requests, 2);
      expect(items.where((e) => e.kind == CoachItemKind.render), hasLength(2));
      expect(items.last.text, 'Finished.');
      engine.dispose();
    },
  );

  test(
    'briefings use native text response; compatible provider keeps its protocol',
    () async {
      for (final native in [true, false]) {
        final config = TestConfig(native: native);
        final answer = await CoachEngine.chatOnce(
          config: config,
          messages: [
            {'role': 'system', 'content': 'Use recorded data.'},
            {'role': 'user', 'content': 'Summarize.'},
          ],
          client: MockClient((request) async {
            final body = jsonDecode(request.body) as Map;
            if (native) {
              expect(body['system'], 'Use recorded data.');
              return http.Response(
                jsonEncode({
                  'content': [
                    {'type': 'text', 'text': 'Measured summary'},
                  ],
                }),
                200,
              );
            }
            expect(request.url.path, '/v1/chat/completions');
            expect(request.headers['authorization'], 'Bearer sk-ant-test-only');
            expect(body['temperature'], 0.4);
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': 'Measured summary',
                    },
                  },
                ],
              }),
              200,
            );
          }),
        );
        expect(answer, 'Measured summary');
      }
    },
  );

  test('native models paginate and normalize a pasted Messages URL', () async {
    var calls = 0;
    final models = await CoachEngine.fetchModels(
      'https://api.anthropic.com/v1/messages/',
      'test-key',
      client: MockClient((request) async {
        calls++;
        expect(request.url.path, '/v1/models');
        expect(request.headers['x-api-key'], 'test-key');
        if (calls == 1) {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'z'},
              ],
              'has_more': true,
              'last_id': 'z',
            }),
            200,
          );
        }
        expect(request.url.queryParameters['after_id'], 'z');
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'a'},
            ],
            'has_more': false,
          }),
          200,
        );
      }),
    );
    expect(models, ['a', 'z']);
    expect(calls, 2);
  });

  test(
    'provider errors explain invalid keys without exposing the key',
    () async {
      await expectLater(
        CoachEngine.chatOnce(
          config: TestConfig(),
          messages: const [],
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'error': {'message': 'Invalid sk-ant-test-only'},
              }),
              401,
            ),
          ),
        ),
        throwsA(
          isA<CoachException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('API key was rejected'),
              isNot(contains('sk-ant-test-only')),
            ),
          ),
        ),
      );
    },
  );

  test('truncated native answers fail explicitly', () async {
    await expectLater(
      CoachEngine.chatOnce(
        config: TestConfig(),
        messages: const [],
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'content': [], 'stop_reason': 'max_tokens'}),
            200,
          ),
        ),
      ),
      throwsA(
        isA<CoachException>().having(
          (e) => e.message,
          'message',
          contains('response limit'),
        ),
      ),
    );
  });

  test('changing providers strips only local Anthropic metadata', () {
    final message = AnthropicMessages.response({
      'content': [
        {'type': 'text', 'text': 'Hello'},
      ],
    });
    final body = AnthropicMessages.openAiRequest({
      'messages': [message],
    });
    expect(
      body['messages'][0].containsKey(AnthropicMessages.nativeContentKey),
      isFalse,
    );
    expect(body['messages'][0]['content'], 'Hello');
    expect(message.containsKey(AnthropicMessages.nativeContentKey), isTrue);
  });
}
