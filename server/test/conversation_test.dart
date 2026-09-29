import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:buddy_server/buddy_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
// latest_all includes alias zones such as Asia/Phnom_Penh; latest doesn't.
import 'package:timezone/data/latest_all.dart' as tz_data;

/// Replies with queued outputs and records what it was sent.
class FakeLlm implements Llm {
  final outputs = <List<Item>>[];
  final inputs = <List<Item>>[];
  Completer<void>? hold;

  @override
  Future<List<Item>> respond({
    required String instructions,
    required List<Item> input,
    required List<Item> tools,
    Future<void>? cancelled,
  }) async {
    inputs.add(input);
    final output = outputs.removeAt(0);
    if (hold case final hold?) {
      await Future.any([hold.future, ?cancelled]);
      if (!hold.isCompleted) throw Cancelled();
    }
    return output;
  }
}

Item say(String text) => {
  'type': 'message',
  'role': 'assistant',
  'content': [
    {'type': 'output_text', 'text': text},
  ],
};

Item setAlarm(String time, String label) => {
  'type': 'function_call',
  'call_id': 'call_1',
  'name': 'set_alarm',
  'arguments': jsonEncode({'time': time, 'label': label}),
};

const la = 'America/Los_Angeles';

List<String> texts(List<Item> input) => [
  for (final item in input)
    if (item['type'] == 'message')
      '${item['role']}: ${(item['content'] as List).first['text']}',
];

void main() {
  setUpAll(tz_data.initializeTimeZones);

  late Directory dir;
  late String dbPath;
  late FakeLlm llm;
  late DateTime now;

  Conversation conversation() =>
      Conversation(History(dbPath), llm, clock: () => now);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('buddy_test');
    dbPath = '${dir.path}/buddy.db';
    llm = FakeLlm();
    now = DateTime.utc(2026, 9, 30, 4); // 21:00 PDT on Sep 29.
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('alarm tool call returns the alarm in UTC plus the reply', () async {
    llm.outputs
      ..add([setAlarm('2026-09-30T07:00:00-07:00', 'gym')])
      ..add([say('Alarm set for 7 for the gym.')]);

    final reply = await conversation().message('7am gym alarm', timezone: la);

    expect(reply!.toJson(), {
      'text': 'Alarm set for 7 for the gym.',
      'alarms': [
        {'at': '2026-09-30T14:00:00.000Z', 'label': 'gym'},
      ],
    });
    final toolOutput = llm.inputs[1].last;
    expect(toolOutput['type'], 'function_call_output');
    expect(toolOutput['output'], 'Alarm sent to the phone.');
  });

  test(
    'alarm time without a UTC offset is rejected back to the model',
    () async {
      llm.outputs
        ..add([setAlarm('2026-09-30T07:00:00', 'gym')])
        ..add([say('What timezone?')]);

      final reply = await conversation().message('7am gym alarm', timezone: la);

      expect(reply!.alarms, isEmpty);
      expect(reply.text, 'What timezone?');
      expect(llm.inputs[1].last['output'], contains('UTC offset'));
    },
  );

  test('instructions carry the phone-local time and timezone', () async {
    llm.outputs.add([say('Hi')]);
    final c = conversation();
    await c.message('hello', timezone: la);
    expect(
      c.history.instructions,
      contains('Tuesday 2026-09-29T21:00:00-07:00 (America/Los_Angeles)'),
    );
  });

  test('alias timezones such as Asia/Phnom_Penh are accepted', () async {
    llm.outputs.add([say('Hi')]);
    final c = conversation();
    await c.message('hello', timezone: 'Asia/Phnom_Penh');
    expect(c.history.instructions, contains('+07:00 (Asia/Phnom_Penh)'));
  });

  test('history survives a restart', () async {
    llm.outputs.add([say('Hi there')]);
    await conversation().message('hello', timezone: la);

    llm.outputs.add([say('Still here')]);
    await conversation().message('you there?', timezone: la);

    expect(texts(llm.inputs.last), [
      'user: hello',
      'assistant: Hi there',
      'user: you there?',
    ]);
  });

  test('a time update precedes a message after a 5+ minute gap', () async {
    final c = conversation();
    llm.outputs.add([say('a')]);
    await c.message('one', timezone: la);

    now = now.add(const Duration(minutes: 4));
    llm.outputs.add([say('b')]);
    await c.message('two', timezone: la);
    expect(texts(llm.inputs.last)[2], 'user: two');

    now = now.add(const Duration(minutes: 5));
    llm.outputs.add([say('c')]);
    await c.message('three', timezone: la);
    expect(texts(llm.inputs.last).sublist(4), [
      'developer: Time update: Tuesday 2026-09-29T21:09:00-07:00 '
          '(America/Los_Angeles).',
      'user: three',
    ]);
  });

  test('a newer message supersedes an in-flight turn', () async {
    final c = conversation();
    llm.hold = Completer();
    llm.outputs.add([say('a long answer')]);
    final pending = c.message('tell me a story', timezone: la);
    await Future<void>.delayed(Duration.zero);

    llm.hold = null;
    llm.outputs.add([say('Sure, a short one.')]);
    final reply = await c.message('make it short', timezone: la);

    expect(await pending, isNull);
    expect(reply!.text, 'Sure, a short one.');
    expect(texts(c.history.items), [
      'user: tell me a story',
      'user: make it short',
      'assistant: Sure, a short one.',
    ]);
  });

  group('interrupted reply', () {
    late Conversation c;

    // A turn with two spoken messages around an alarm tool call.
    setUp(() async {
      c = conversation();
      llm.outputs
        ..add([say('Okay.'), setAlarm('2026-09-30T07:00:00-07:00', 'gym')])
        ..add([say('Your gym alarm is set for 7 tomorrow.')]);
      await c.message('gym alarm at 7', timezone: la);
      llm.outputs.add([say('Sure.')]);
    });

    test('is trimmed to what was heard, and the model is told', () async {
      c.interrupt('Okay. Your gym alarm');
      await c.message('wait', timezone: la);

      expect(texts(llm.inputs.last), [
        'user: gym alarm at 7',
        'assistant: Okay.',
        'assistant: Your gym alarm',
        'developer: The user interrupted you; they only heard your reply up '
            'to where it ends above.',
        'user: wait',
      ]);
      // The alarm was still set, so its tool call stays.
      expect(
        llm.inputs.last.where((i) => i['type'] == 'function_call'),
        hasLength(1),
      );
    });

    test('heard nothing drops all of its text', () async {
      c.interrupt('');
      await c.message('wait', timezone: la);

      expect(texts(llm.inputs.last), [
        'user: gym alarm at 7',
        'developer: The user interrupted you before hearing any of your '
            'reply.',
        'user: wait',
      ]);
    });

    test('an interrupt before the reply arrives cancels the turn', () async {
      llm.hold = Completer();
      final pending = c.message('tell me a story', timezone: la);
      await Future<void>.delayed(Duration.zero);

      c.interrupt('');

      expect(await pending, isNull);
      expect(texts(c.history.items).sublist(3), [
        'user: tell me a story',
        'developer: The user interrupted you before hearing any of your '
            'reply.',
      ]);
    });

    test('trim survives a restart', () async {
      c.interrupt('Okay.');
      await c.message('wait', timezone: la);

      expect(texts(conversation().history.items).sublist(0, 2), [
        'user: gym alarm at 7',
        'assistant: Okay.',
      ]);
    });
  });

  test('alarm failure is reported to the model', () async {
    final c = conversation();
    llm.outputs.add([say('Sorry, that alarm failed.')]);
    final reply = await c.alarmFailed(
      label: 'gym',
      at: '2026-09-30T14:00:00Z',
      error: 'permission denied',
      timezone: la,
    );
    expect(reply!.text, 'Sorry, that alarm failed.');
    expect(texts(llm.inputs.last).single, contains('permission denied'));
  });

  group('HTTP API', () {
    late Handler handler;
    setUp(() => handler = api(conversation()));

    Future<Response> post(String path, [Object? body]) async => handler(
      Request(
        'POST',
        Uri.parse('http://buddy/$path'),
        body: body == null ? null : jsonEncode(body),
      ),
    );

    test('POST /message returns text and alarms', () async {
      llm.outputs.add([say('Hi')]);
      final res = await post('message', {'text': 'hello', 'timezone': la});
      expect(res.statusCode, 200);
      expect(jsonDecode(await res.readAsString()), {
        'text': 'Hi',
        'alarms': <Object>[],
      });
    });

    test('GET /health returns 200 and leaves history alone', () async {
      final res = await handler(
        Request('GET', Uri.parse('http://buddy/health')),
      );
      expect(res.statusCode, 200);
      expect(File(dbPath).existsSync() ? History(dbPath).items : [], isEmpty);
    });

    test('POST /interrupt returns 204', () async {
      expect((await post('interrupt', {'heard': ''})).statusCode, 204);
    });

    test('bad input returns 400', () async {
      expect((await post('message', {'text': 'hi'})).statusCode, 400);
      expect(
        (await post('message', {'text': 'hi', 'timezone': 'Nope'})).statusCode,
        400,
      );
      expect((await post('message', 'not an object')).statusCode, 400);
      expect((await post('interrupt')).statusCode, 400);
      expect((await post('interrupt', {'heard': 3})).statusCode, 400);
    });

    test('model failure is spoken, not silent', () async {
      // No queued output: the fake throws.
      final res = await post('message', {'text': 'hello', 'timezone': la});
      expect(res.statusCode, 200);
      expect(await res.readAsString(), contains("couldn't reach the AI"));
    });
  });
}
