import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:buddy_server/buddy_server.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest.dart' as tz_data;

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
    if (hold case final hold?) {
      await Future.any([hold.future, ?cancelled]);
      if (!hold.isCompleted) throw Cancelled();
    }
    return outputs.removeAt(0);
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

Map<String, dynamic> userSaid(String text) => {
  'type': 'user_said',
  'text': text,
  'timezone': 'America/Los_Angeles',
};

List<String> texts(List<Item> input) => [
  for (final item in input)
    if (item['type'] == 'message')
      '${item['role']}: ${(item['content'] as List).first['text']}',
];

void main() {
  setUpAll(tz_data.initializeTimeZones);

  late Directory dir;
  late File file;
  late FakeLlm llm;
  late DateTime now;

  Conversation conversation() =>
      Conversation(History(file), llm, clock: () => now);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('buddy_test');
    file = File('${dir.path}/history.jsonl');
    llm = FakeLlm();
    now = DateTime.utc(2026, 9, 30, 4); // 21:00 PDT on Sep 29.
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('alarm tool call becomes set_alarm then say, in UTC', () async {
    llm.outputs
      ..add([setAlarm('2026-09-30T07:00:00-07:00', 'gym')])
      ..add([say('Alarm set for 7 for the gym.')]);

    final commands = await conversation().handle(userSaid('7am gym alarm'));

    expect(commands, [
      {'type': 'set_alarm', 'at': '2026-09-30T14:00:00.000Z', 'label': 'gym'},
      {'type': 'say', 'text': 'Alarm set for 7 for the gym.'},
    ]);
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

      final commands = await conversation().handle(userSaid('7am gym alarm'));

      expect(commands, [
        {'type': 'say', 'text': 'What timezone?'},
      ]);
      expect(llm.inputs[1].last['output'], contains('UTC offset'));
    },
  );

  test('instructions carry the phone-local time and timezone', () async {
    llm.outputs.add([say('Hi')]);
    final c = conversation();
    await c.handle(userSaid('hello'));
    expect(
      c.history.instructions,
      contains('Tuesday 2026-09-29T21:00:00-07:00 (America/Los_Angeles)'),
    );
  });

  test('history survives a restart', () async {
    llm.outputs.add([say('Hi there')]);
    await conversation().handle(userSaid('hello'));

    llm.outputs.add([say('Still here')]);
    await conversation().handle(userSaid('you there?'));

    expect(texts(llm.inputs.last), [
      'user: hello',
      'assistant: Hi there',
      'user: you there?',
    ]);
  });

  test('a time update precedes a message after a 5+ minute gap', () async {
    final c = conversation();
    llm.outputs.add([say('a')]);
    await c.handle(userSaid('one'));

    now = now.add(const Duration(minutes: 4));
    llm.outputs.add([say('b')]);
    await c.handle(userSaid('two'));
    expect(texts(llm.inputs.last).last, 'user: two');
    expect(texts(llm.inputs.last)[2], 'user: two');

    now = now.add(const Duration(minutes: 5));
    llm.outputs.add([say('c')]);
    await c.handle(userSaid('three'));
    expect(texts(llm.inputs.last).sublist(4), [
      'developer: Time update: Tuesday 2026-09-29T21:09:00-07:00 '
          '(America/Los_Angeles).',
      'user: three',
    ]);
  });

  test('interrupt cancels the in-flight turn and is recorded', () async {
    final c = conversation();
    llm.hold = Completer();
    llm.outputs.add([say('a long answer')]);
    final pending = c.handle(userSaid('tell me a story'));
    await Future<void>.delayed(Duration.zero);

    final interruptCommands = await c.handle({
      'type': 'interrupted',
      'timezone': 'America/Los_Angeles',
    });

    expect(interruptCommands, isEmpty);
    expect(await pending, isEmpty);
    expect(texts(c.history.items), [
      'user: tell me a story',
      'developer: The user interrupted your last reply.',
    ]);
  });

  test('bad events are rejected', () async {
    final c = conversation();
    expect(
      () => c.handle({'type': 'user_said', 'text': 'hi'}),
      throwsA(isA<BadEvent>()),
    );
    expect(
      () => c.handle({'type': 'user_said', 'text': 'hi', 'timezone': 'Nope'}),
      throwsA(isA<BadEvent>()),
    );
    expect(
      () => c.handle({'type': 'dance', 'timezone': 'America/Los_Angeles'}),
      throwsA(isA<BadEvent>()),
    );
  });
}
