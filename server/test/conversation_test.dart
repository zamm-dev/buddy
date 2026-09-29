import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:buddy_server/buddy_server.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
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

var _calls = 0;

Item toolCall(String name, Map<String, Object> args) => {
  'type': 'function_call',
  'call_id': 'call_${++_calls}',
  'name': name,
  'arguments': jsonEncode(args),
};

Item setAlarm(String time, String label) =>
    toolCall('set_alarm', {'time': time, 'label': label});

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
        {'id': 1, 'at': '2026-09-30T14:00:00.000Z', 'label': 'gym'},
      ],
    });
    final toolOutput = llm.inputs[1].last;
    expect(toolOutput['type'], 'function_call_output');
    expect(
      toolOutput['output'],
      'Set alarm 1: Wednesday 2026-09-30T07:00:00-07:00 '
      '(America/Los_Angeles), "gym".',
    );
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

  group('alarms', () {
    late Conversation c;

    /// Runs one turn in which the model makes [calls], then says "ok".
    Future<Reply> turn(List<Item> calls) async {
      llm.outputs
        ..add(calls)
        ..add([say('ok')]);
      return (await c.message('do it', timezone: la))!;
    }

    String lastToolOutput() => llm.inputs.last.lastWhere(
      (i) => i['type'] == 'function_call_output',
    )['output'];

    setUp(() => c = conversation());

    test('placeholder labels are rejected so the model asks', () async {
      final reply = await turn([
        setAlarm('2026-09-30T07:00:00-07:00', 'Alarm'),
      ]);
      expect(reply.alarms, isEmpty);
      expect(lastToolOutput(), contains('Ask the user what the alarm is for'));
    });

    test('update changes time and label; the reply carries it', () async {
      await turn([setAlarm('2026-09-30T07:00:00-07:00', 'gym')]);
      final reply = await turn([
        toolCall('update_alarm', {
          'id': 1,
          'time': '2026-09-30T08:00:00-07:00',
          'label': 'gym with Sam',
        }),
      ]);
      expect(reply.toJson()['alarms'], [
        {'id': 1, 'at': '2026-09-30T15:00:00.000Z', 'label': 'gym with Sam'},
      ]);
    });

    test('update can change just the label', () async {
      await turn([setAlarm('2026-09-30T07:00:00-07:00', 'gym')]);
      final reply = await turn([
        toolCall('update_alarm', {'id': 1, 'label': 'test'}),
      ]);
      expect(reply.alarms.single.label, 'test');
      expect(reply.alarms.single.at, DateTime.utc(2026, 9, 30, 14));
    });

    test('delete drops it from the reply and history shows it', () async {
      await turn([setAlarm('2026-09-30T07:00:00-07:00', 'gym')]);
      final reply = await turn([
        toolCall('delete_alarm', {'id': 1}),
      ]);
      expect(reply.alarms, isEmpty);
      expect(c.history.alarms.all().single.statusAt(now), 'deleted');
    });

    test('past, deleted or unknown alarms cannot be changed', () async {
      await turn([setAlarm('2026-09-30T07:00:00-07:00', 'gym')]);
      await turn([
        toolCall('delete_alarm', {'id': 1}),
      ]);
      await turn([
        toolCall('update_alarm', {'id': 1, 'label': 'x'}),
      ]);
      expect(lastToolOutput(), contains('no upcoming alarm with id 1'));
      await turn([
        toolCall('delete_alarm', {'id': 42}),
      ]);
      expect(lastToolOutput(), contains('no upcoming alarm with id 42'));
    });

    test('list shows upcoming and past alarms with ids', () async {
      await turn([
        setAlarm('2026-09-30T07:00:00-07:00', 'gym'),
        setAlarm('2026-09-30T09:00:00-07:00', 'dentist'),
      ]);
      await turn([
        toolCall('delete_alarm', {'id': 2}),
      ]);
      now = now.add(const Duration(days: 1)); // The gym alarm has rung.
      await turn([toolCall('list_alarms', {})]);
      expect(
        lastToolOutput(),
        'Upcoming:\n'
        '(none)\n'
        'Recent past:\n'
        '- 2: Wednesday 2026-09-30T09:00:00-07:00 (America/Los_Angeles), '
        '"dentist" (deleted)\n'
        '- 1: Wednesday 2026-09-30T07:00:00-07:00 (America/Los_Angeles), '
        '"gym" (rang)',
      );
    });

    test('a failed alarm is marked failed and reported', () async {
      await turn([setAlarm('2026-09-30T07:00:00-07:00', 'gym')]);
      llm.outputs.add([say('Sorry, that alarm failed.')]);
      final reply = await c.alarmFailed(
        id: 1,
        error: 'permission denied',
        timezone: la,
      );
      expect(reply!.text, 'Sorry, that alarm failed.');
      expect(reply.alarms, isEmpty);
      expect(texts(llm.inputs.last).last, contains('permission denied'));
      expect(c.history.alarms.byId(1)!.status, 'failed');
    });

    test('alarms set before the alarms table existed are backfilled', () {
      // An old database: set_alarm calls in items, no alarms table.
      c.history.alarms; // Tables exist now; simulate the old layout.
      final db = sqlite3.open(dbPath)..execute('DROP TABLE alarms');
      final accepted = setAlarm('2026-09-30T07:00:00-07:00', 'gym');
      final rejected = setAlarm('2026-09-30T07:00:00', 'bad');
      for (final item in [
        accepted,
        {
          'type': 'function_call_output',
          'call_id': accepted['call_id'],
          'output': 'Alarm sent to the phone.',
        },
        rejected,
        {
          'type': 'function_call_output',
          'call_id': rejected['call_id'],
          'output': 'Error: time must be ISO 8601 with a UTC offset.',
        },
      ]) {
        db.execute('INSERT INTO items (at, item) VALUES (?, ?)', [
          '2026-09-30T04:00:00.000Z',
          jsonEncode(item),
        ]);
      }
      db.close();

      final alarms = History(dbPath).alarms.all();
      expect(alarms.single.label, 'gym');
      expect(alarms.single.at, DateTime.utc(2026, 9, 30, 14));
    });
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

    test('GET /alarms lists every alarm with its status', () async {
      llm.outputs
        ..add([setAlarm('2099-01-01T07:00:00Z', 'far future')])
        ..add([say('ok')]);
      await post('message', {'text': 'hi', 'timezone': la});
      final res = await handler(
        Request('GET', Uri.parse('http://buddy/alarms')),
      );
      expect(jsonDecode(await res.readAsString()), {
        'alarms': [
          {
            'id': 1,
            'at': '2099-01-01T07:00:00.000Z',
            'label': 'far future',
            'status': 'upcoming',
          },
        ],
      });
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
