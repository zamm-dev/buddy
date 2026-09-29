// Spike: does the Codex backend (ChatGPT subscription) accept a custom
// function tool and a system message in the middle of the conversation?
// Endpoint/headers taken from openai/codex (codex-rs). No token refresh:
// if we get a 401, run any `codex` command to refresh ~/.codex/auth.json.
// Run: dart run tool/codex_spike.dart (MID_ROLE=system reproduces the 400).
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

const endpoint = 'https://chatgpt.com/backend-api/codex/responses';
final model = Platform.environment['MODEL'] ?? 'gpt-6-sol';
final midRole = Platform.environment['MID_ROLE'] ?? 'developer';

const tools = [
  {
    'type': 'function',
    'name': 'set_alarm',
    'description': 'Schedule an alarm on the user\'s phone.',
    'parameters': {
      'type': 'object',
      'properties': {
        'time': {
          'type': 'string',
          'description': 'ISO 8601 datetime with UTC offset.',
        },
        'label': {'type': 'string', 'description': 'What the alarm is for.'},
      },
      'required': ['time', 'label'],
      'additionalProperties': false,
    },
    'strict': false,
  },
];

Map<String, dynamic> msg(String role, String text) => {
  'type': 'message',
  'role': role,
  'content': [
    {'type': role == 'assistant' ? 'output_text' : 'input_text', 'text': text},
  ],
};

Future<List<Map<String, dynamic>>> call(
  Map<String, dynamic> auth,
  List<Map<String, dynamic>> input,
) async {
  final tokens = auth['tokens'] as Map<String, dynamic>;
  final client = HttpClient();
  final req = await client.postUrl(Uri.parse(endpoint));
  req.headers
    ..set('Authorization', 'Bearer ${tokens['access_token']}')
    ..set('ChatGPT-Account-ID', tokens['account_id'] as String)
    ..set('Content-Type', 'application/json')
    ..set('Accept', 'text/event-stream');
  req.write(
    jsonEncode({
      'model': model,
      'instructions':
          'You are buddy, a voice assistant. Replies are spoken aloud, so '
          'keep them short. Use set_alarm when the user wants an alarm; ask '
          'if the time or purpose is unclear. Current local time: '
          '2026-09-29T21:00:00-07:00 (America/Los_Angeles).',
      'input': input,
      'tools': tools,
      'tool_choice': 'auto',
      'parallel_tool_calls': false,
      'store': false,
      'stream': true,
      'include': <String>[],
    }),
  );
  final res = await req.close();
  final body = res.transform(utf8.decoder).transform(const LineSplitter());
  if (res.statusCode != 200) {
    stderr.writeln('HTTP ${res.statusCode}: ${(await body.toList()).join()}');
    exit(1);
  }
  final items = <Map<String, dynamic>>[];
  await for (final line in body) {
    if (!line.startsWith('data: ')) continue;
    final event = jsonDecode(line.substring(6)) as Map<String, dynamic>;
    if (event['type'] == 'response.output_item.done') {
      items.add(event['item'] as Map<String, dynamic>);
    } else if (event['type'] == 'response.failed') {
      stderr.writeln('response.failed: ${jsonEncode(event['response'])}');
      exit(1);
    }
  }
  client.close();
  return items;
}

void show(String title, List<Map<String, dynamic>> items) {
  print('== $title');
  for (final item in items) {
    switch (item['type']) {
      case 'function_call':
        print('  function_call ${item['name']}(${item['arguments']})');
      case 'message':
        final text = (item['content'] as List)
            .map((c) => (c as Map)['text'])
            .join();
        print('  message: $text');
      default:
        print('  ${item['type']}');
    }
  }
}

Future<void> main() async {
  final home = Platform.environment['HOME']!;
  final auth = jsonDecode(
    File('$home/.codex/auth.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  // Turn 1: custom tool call.
  final history = <Map<String, dynamic>>[
    msg('user', 'Wake me up at 7 tomorrow morning for the gym.'),
  ];
  final turn1 = await call(auth, history);
  show('turn 1 (expect set_alarm call)', turn1);
  final fc = turn1.firstWhere(
    (i) => i['type'] == 'function_call',
    orElse: () => throw StateError('no function_call returned'),
  );

  // Turn 2: tool result -> spoken confirmation.
  history
    ..add({
      'type': 'function_call',
      'call_id': fc['call_id'],
      'name': fc['name'],
      'arguments': fc['arguments'],
    })
    ..add({
      'type': 'function_call_output',
      'call_id': fc['call_id'],
      'output': 'Alarm sent to the phone.',
    });
  final turn2 = await call(auth, history);
  show('turn 2 (expect confirmation)', turn2);
  history.addAll(
    turn2
        .where((i) => i['type'] == 'message')
        .map(
          (i) => msg(
            'assistant',
            (i['content'] as List).map((c) => (c as Map)['text']).join(),
          ),
        ),
  );

  // Turn 3: mid-conversation time update, then a question that depends on it.
  history
    ..add(
      msg(
        midRole,
        'Current local time: 2026-09-30T06:40:00-07:00 (America/Los_Angeles).',
      ),
    )
    ..add(msg('user', 'How long until my alarm goes off?'));
  final turn3 = await call(auth, history);
  show('turn 3 (mid-conversation $midRole message; expect ~20 minutes)', turn3);
}
