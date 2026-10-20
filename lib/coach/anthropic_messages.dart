// Adapt the app's shared chat history to Anthropic's native Messages API.
// This keeps coach tools, briefings, and journal chat on one provider path.
import 'dart:convert';

class AnthropicMessages {
  static const nativeContentKey = '_anthropic_content';

  static Map<String, dynamic> request(Map<String, dynamic> body) {
    final system = <String>[];
    final messages = <Map<String, dynamic>>[];
    for (final raw in body['messages'] as List? ?? const []) {
      final message = (raw as Map).cast<String, dynamic>();
      final role = message['role'];
      if (role == 'system' || role == 'developer') {
        system.add(message['content'] as String? ?? '');
        continue;
      }
      if (role == 'tool') {
        final result = <String, dynamic>{
          'type': 'tool_result',
          'tool_use_id': message['tool_call_id'],
          'content': message['content'] ?? '',
        };
        // All parallel results belong to the same user message immediately
        // following the assistant's tool_use blocks.
        if (messages.isNotEmpty && messages.last['role'] == 'user') {
          (messages.last['content'] as List).add(result);
        } else {
          messages.add({
            'role': 'user',
            'content': [result],
          });
        }
        continue;
      }
      final content = <Map<String, dynamic>>[];
      if (role == 'assistant' && message[nativeContentKey] is List) {
        // Thinking signatures and block order must survive tool round trips.
        content.addAll(
          (message[nativeContentKey] as List).map(
            (block) => (block as Map).cast<String, dynamic>(),
          ),
        );
      } else {
        final text = message['content'] as String? ?? '';
        if (text.isNotEmpty) content.add({'type': 'text', 'text': text});
        for (final rawCall in message['tool_calls'] as List? ?? const []) {
          final call = rawCall as Map;
          final function = call['function'] as Map;
          final arguments = function['arguments'];
          final input = arguments is String
              ? jsonDecode(arguments.isEmpty ? '{}' : arguments)
              : arguments ?? <String, dynamic>{};
          if (input is! Map) {
            throw const FormatException('Tool input must be a JSON object.');
          }
          content.add({
            'type': 'tool_use',
            'id': call['id'],
            'name': function['name'],
            'input': input,
          });
        }
      }
      if (content.isNotEmpty) messages.add({'role': role, 'content': content});
    }
    final tools = <Map<String, dynamic>>[];
    for (final raw in body['tools'] as List? ?? const []) {
      final function = (raw as Map)['function'] as Map;
      tools.add({
        'name': function['name'],
        if (function['description'] != null)
          'description': function['description'],
        'input_schema': function['parameters'] ?? {'type': 'object'},
      });
    }
    final choice = body['tool_choice'];
    return {
      'model': body['model'],
      'max_tokens': body['max_tokens'] ?? body['max_completion_tokens'] ?? 8192,
      'messages': messages,
      if (system.isNotEmpty) 'system': system.join('\n\n'),
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty && choice != null)
        'tool_choice': choice is Map
            ? {'type': 'tool', 'name': choice['function']['name']}
            : {'type': choice == 'required' ? 'any' : choice},
      for (final field in ['temperature', 'top_p', 'top_k'])
        if (body[field] != null) field: body[field],
    };
  }

  static Map<String, dynamic> response(Map<String, dynamic> body) {
    final blocks = (body['content'] as List? ?? const [])
        .map((block) => (block as Map).cast<String, dynamic>())
        .toList();
    return {
      'role': 'assistant',
      'content': blocks
          .where((b) => b['type'] == 'text')
          .map((b) => b['text'] as String)
          .join('\n'),
      'tool_calls': [
        for (final block in blocks)
          if (block['type'] == 'tool_use')
            {
              'id': block['id'],
              'type': 'function',
              'function': {
                'name': block['name'],
                'arguments': jsonEncode(block['input']),
              },
            },
      ],
      nativeContentKey: blocks,
    };
  }

  static Map<String, dynamic> openAiRequest(Map<String, dynamic> body) => {
    ...body,
    // Local metadata must not leak into another provider's API schema if the
    // user changes providers while retaining a conversation.
    'messages': [
      for (final raw in body['messages'] as List? ?? const [])
        Map<String, dynamic>.from(raw as Map)..remove(nativeContentKey),
    ],
  };
}
