import 'dart:async';
import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'codex_client.dart';
import 'history.dart';

/// An alarm for the app to schedule.
class Alarm {
  Alarm(this.at, this.label);
  final DateTime at;
  final String label;

  Map<String, dynamic> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'label': label,
  };
}

/// What the app should do after a turn: schedule [alarms], then show [text]
/// as a subtitle and speak it.
class Reply {
  Reply(this.text, this.alarms);
  final String text;
  final List<Alarm> alarms;

  Map<String, dynamic> toJson() => {
    'text': text,
    'alarms': [for (final alarm in alarms) alarm.toJson()],
  };
}

/// Thrown for requests the app shouldn't have sent.
class BadRequest implements Exception {
  BadRequest(this.message);
  final String message;
  @override
  String toString() => message;
}

/// All conversation logic. The app reports what the user said or pressed and
/// gets back what to say and which alarms to set; see AGENTS.md. Callers must
/// call `tz_data.initializeTimeZones()` first.
class Conversation {
  Conversation(this.history, this.llm, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// A user message this long after the previous record gets a time update.
  static const timeUpdateGap = Duration(minutes: 5);

  static const _maxToolRounds = 5;

  static const tools = <Item>[
    {
      'type': 'function',
      'name': 'set_alarm',
      'description': "Schedule an alarm on the user's phone.",
      'parameters': {
        'type': 'object',
        'properties': {
          'time': {
            'type': 'string',
            'description': 'When the alarm rings: ISO 8601 with a UTC offset.',
          },
          'label': {
            'type': 'string',
            'description': 'What the alarm is for, in the user\'s words.',
          },
        },
        'required': ['time', 'label'],
        'additionalProperties': false,
      },
      'strict': false,
    },
  ];

  final History history;
  final Llm llm;
  final DateTime Function() _clock;
  Completer<void>? _inFlight;

  /// The user said [text]. Returns null if a newer request superseded this
  /// turn.
  Future<Reply?> message(String text, {required String timezone}) {
    if (text.trim().isEmpty) throw BadRequest('text must not be empty');
    final location = _start(timezone);
    final now = _clock();
    final lastAt = history.lastAt;
    history.append([
      if (lastAt != null && now.difference(lastAt) >= timeUpdateGap)
        _message('developer', 'Time update: ${_now(location)}.'),
      _message('user', text),
    ], now);
    return _turn();
  }

  /// The user cut off the reply after hearing only [heard] of it. Cancels any
  /// in-flight turn, trims the last reply in history to what was heard, and
  /// tells the model, so history matches what the user actually heard.
  void interrupt(String heard) {
    _cancelInFlight();
    if (history.instructions == null) return;
    final now = _clock();
    history
      ..trimLastReply(heard, now)
      ..append([
        _message(
          'developer',
          heard.isEmpty
              ? 'The user interrupted you before hearing any of your reply.'
              : 'The user interrupted you; they only heard your reply up to '
                    'where it ends above.',
        ),
      ], now);
  }

  /// The phone couldn't schedule an alarm it was given. Returns null if a
  /// newer request superseded this turn.
  Future<Reply?> alarmFailed({
    required String label,
    required String at,
    required String error,
    required String timezone,
  }) {
    _start(timezone);
    history.append([
      _message(
        'developer',
        'The phone failed to set the alarm "$label" for $at: $error. '
            'Tell the user.',
      ),
    ], _clock());
    return _turn();
  }

  /// Cancels any in-flight turn and starts the conversation if needed.
  tz.Location _start(String timezone) {
    final location = _location(timezone);
    _cancelInFlight();
    if (history.instructions == null) {
      history.start(_instructions(location), _clock());
    }
    return location;
  }

  /// Runs the model until it stops calling tools. Nothing from the turn is
  /// saved unless it completes, so a cancelled turn leaves history consistent.
  Future<Reply?> _turn() async {
    final cancel = _inFlight = Completer<void>();
    final turnItems = <Item>[];
    final said = <String>[];
    final alarms = <Alarm>[];
    try {
      for (var round = 0; round < _maxToolRounds; round++) {
        final output = await llm.respond(
          instructions: history.instructions!,
          input: [...history.items, ...turnItems],
          tools: tools,
          cancelled: cancel.future,
        );
        if (cancel.isCompleted) throw Cancelled();
        var calledTool = false;
        for (final item in output) {
          switch (item['type']) {
            case 'message':
              final text = messageText(item);
              if (text.isEmpty) continue;
              turnItems.add(assistantMessage(text));
              said.add(text);
            case 'function_call':
              calledTool = true;
              turnItems
                ..add({
                  'type': 'function_call',
                  'call_id': item['call_id'],
                  'name': item['name'],
                  'arguments': item['arguments'],
                })
                ..add({
                  'type': 'function_call_output',
                  'call_id': item['call_id'],
                  'output': _runTool(item, alarms),
                });
          }
        }
        if (!calledTool) break;
      }
      history.append(turnItems, _clock());
      return Reply(said.join(' '), alarms);
    } on Cancelled {
      return null;
    } finally {
      if (identical(_inFlight, cancel)) _inFlight = null;
    }
  }

  /// Runs a tool call, collecting any alarms, and returns its output text.
  String _runTool(Item call, List<Alarm> alarms) {
    if (call['name'] != 'set_alarm') return 'Error: unknown tool.';
    final Map<String, dynamic> args;
    try {
      args = jsonDecode(call['arguments'] as String) as Map<String, dynamic>;
    } on FormatException {
      return 'Error: arguments are not valid JSON.';
    }
    final time = args['time'];
    final label = args['label'];
    if (label is! String || label.trim().isEmpty) {
      return 'Error: label is required.';
    }
    // Without an explicit offset, DateTime.parse would use the Mac's zone.
    if (time is! String || !RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(time)) {
      return 'Error: time must be ISO 8601 with a UTC offset.';
    }
    final DateTime at;
    try {
      at = DateTime.parse(time).toUtc();
    } on FormatException {
      return 'Error: time is not a valid ISO 8601 datetime.';
    }
    if (!at.isAfter(_clock())) return 'Error: that time is in the past.';
    alarms.add(Alarm(at, label));
    return 'Alarm sent to the phone.';
  }

  void _cancelInFlight() {
    final inFlight = _inFlight;
    if (inFlight != null && !inFlight.isCompleted) inFlight.complete();
    _inFlight = null;
  }

  String _instructions(tz.Location location) =>
      '''
You are buddy, a friendly voice assistant on the user's phone. Everything you
write is spoken aloud by text-to-speech and shown as subtitles, so keep replies
short and conversational: no markdown, lists, emoji or URLs.

You can set alarms on the phone with the set_alarm tool. Before calling it you
need both what the alarm is for and when it should ring; if either is missing
or ambiguous, ask. Resolve relative times ("in 20 minutes", "7 tomorrow") using
the current time, and pass the time with the user's UTC offset. After setting
an alarm, confirm the time and purpose in one short sentence.

Current time when this conversation started: ${_now(location)}. Later
developer messages starting with "Time update:" give the current time.''';

  String _now(tz.Location location) {
    final now = tz.TZDateTime.from(_clock(), location);
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hours = offset.inHours.abs().toString().padLeft(2, '0');
    final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final local = now.toIso8601String().substring(0, 19);
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return '${weekdays[now.weekday - 1]} $local$sign$hours:$minutes '
        '(${location.name})';
  }

  static tz.Location _location(String name) {
    try {
      return tz.getLocation(name);
    } on tz.LocationNotFoundException {
      throw BadRequest('Unknown timezone: $name');
    }
  }

  static Item _message(String role, String text) => {
    'type': 'message',
    'role': role,
    'content': [
      {'type': 'input_text', 'text': text},
    ],
  };
}
