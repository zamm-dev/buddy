import 'dart:async';
import 'dart:convert';

import 'package:buddy/api.dart';
import 'package:buddy/voice_loop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Hands out queued transcripts, then waits forever.
class FakeEars implements Ears {
  final heard = <String>[];
  var listens = 0;

  @override
  Future<String?> listen() {
    listens++;
    if (heard.isEmpty) return Completer<String?>().future;
    return Future.value(heard.removeAt(0));
  }
}

/// Speaks until [finish] or [stop].
class FakeMouth implements Mouth {
  final spoken = <String>[];
  void Function(int end)? progress;
  Completer<void>? _speech;

  @override
  Future<void> speak(String text, void Function(int end) onProgress) {
    spoken.add(text);
    progress = onProgress;
    return (_speech = Completer()).future;
  }

  void finish() => _speech?.complete();

  @override
  Future<void> stop() async {
    if (_speech case final speech? when !speech.isCompleted) speech.complete();
  }
}

/// Records each sync; alarms whose id is in [errors] fail to set.
class FakeAlarms implements AlarmClock {
  List<BuddyAlarm> scheduled = [];
  var syncs = 0;
  final errors = <int, Object>{};

  @override
  Future<List<(BuddyAlarm, Object)>> sync(List<BuddyAlarm> upcoming) async {
    syncs++;
    scheduled = [
      for (final alarm in upcoming)
        if (!errors.containsKey(alarm.id)) alarm,
    ];
    return [
      for (final alarm in upcoming)
        if (errors[alarm.id] case final error?) (alarm, error),
    ];
  }
}

/// A fake server: records requests, answers from per-path queues.
class FakeServer {
  final requests = <(String, Map<String, dynamic>)>[];

  /// The last request as `path: body`, for readable comparisons.
  String get last => '${requests.last.$1}: ${jsonEncode(requests.last.$2)}';
  final replies = <String, List<Future<http.Response>>>{};

  void reply(String path, Object? json) => (replies[path] ??= []).add(
    Future.value(
      json == null
          ? http.Response('', 204)
          : http.Response(jsonEncode(json), 200),
    ),
  );

  Completer<http.Response> hold(String path) {
    final completer = Completer<http.Response>();
    (replies[path] ??= []).add(completer.future);
    return completer;
  }

  late final client = MockClient((request) {
    final path = request.url.path.substring(1);
    requests.add((path, jsonDecode(request.body) as Map<String, dynamic>));
    if (path == 'interrupt') return Future.value(http.Response('', 204));
    return replies[path]!.removeAt(0);
  });
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeEars ears;
  late FakeMouth mouth;
  late FakeAlarms alarms;
  late FakeServer server;
  late VoiceLoop loop;

  setUp(() {
    ears = FakeEars();
    mouth = FakeMouth();
    alarms = FakeAlarms();
    server = FakeServer();
    loop = VoiceLoop(
      api: BuddyApi(Uri.parse('http://mac:8787/'), server.client),
      ears: ears,
      mouth: mouth,
      alarms: alarms,
      timezone: () async => 'America/Los_Angeles',
    );
  });
  tearDown(() => loop.dispose());

  final gymAlarm = {'id': 7, 'at': '2026-09-30T14:00:00.000Z', 'label': 'gym'};

  test('a turn sets alarms, speaks the reply, then listens again', () async {
    ears.heard.add('gym alarm at 7');
    server.reply('message', {
      'text': 'Set for 7.',
      'alarms': [gymAlarm],
    });

    unawaited(loop.run());
    await settle();

    expect(
      server.last,
      'message: {"text":"gym alarm at 7","timezone":"America/Los_Angeles"}',
    );
    expect(alarms.scheduled.single.at, DateTime.utc(2026, 9, 30, 14));
    expect(alarms.scheduled.single.label, 'gym');
    expect(loop.state, VoiceState.speaking);
    expect(loop.subtitle, 'Set for 7.');

    mouth.finish();
    await settle();
    expect(loop.state, VoiceState.listening);
    expect(ears.listens, 2);
  });

  test('interrupting speech sends what was heard and listens again', () async {
    ears.heard.add('tell me a story');
    server.reply('message', {
      'text': 'Once upon a time, a dragon.',
      'alarms': [],
    });

    unawaited(loop.run());
    await settle();
    mouth.progress!(9); // "Once upon"
    loop.interrupt();
    await settle();

    expect(server.last, 'interrupt: {"heard":"Once upon"}');
    expect(loop.state, VoiceState.listening);
  });

  test(
    'a reply that arrives after an interrupt sets its alarms silently',
    () async {
      ears.heard.add('gym alarm at 7');
      final pending = server.hold('message');

      unawaited(loop.run());
      await settle();
      expect(loop.state, VoiceState.thinking);
      loop.interrupt();
      await settle();
      expect(server.last, 'interrupt: {"heard":""}');

      pending.complete(
        http.Response(
          jsonEncode({
            'text': 'Set for 7.',
            'alarms': [gymAlarm],
          }),
          200,
        ),
      );
      await settle();

      expect(alarms.scheduled, hasLength(1));
      expect(mouth.spoken, isEmpty);
      expect(loop.state, VoiceState.listening);
    },
  );

  test('every reply syncs the full alarm list, even an empty one', () async {
    ears.heard.addAll(['gym alarm at 7', 'actually cancel it']);
    server
      ..reply('message', {
        'text': 'Set.',
        'alarms': [gymAlarm],
      })
      ..reply('message', {'text': 'Cancelled.', 'alarms': []});

    unawaited(loop.run());
    await settle();
    expect(alarms.scheduled.single.id, 7);
    mouth.finish();
    await settle();

    expect(alarms.syncs, 2);
    expect(alarms.scheduled, isEmpty);
  });

  test('a superseded turn (204) goes back to listening', () async {
    ears.heard.add('hello');
    server.reply('message', null);

    unawaited(loop.run());
    await settle();

    expect(mouth.spoken, isEmpty);
    expect(loop.state, VoiceState.listening);
  });

  test('a failed alarm is reported and the reply spoken', () async {
    ears.heard.add('gym alarm at 7');
    alarms.errors[7] = StateError('permission denied');
    server
      ..reply('message', {
        'text': 'Set for 7.',
        'alarms': [gymAlarm],
      })
      ..reply('alarm-failed', {
        'text': "Sorry, I couldn't set it.",
        'alarms': [],
      });

    unawaited(loop.run());
    await settle();
    mouth.finish();
    await settle();

    final (path, body) = server.requests.last;
    expect(path, 'alarm-failed');
    expect(body['id'], 7);
    expect(body['error'], contains('permission denied'));
    expect(mouth.spoken.last, "Sorry, I couldn't set it.");
  });
}
