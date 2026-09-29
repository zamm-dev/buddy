import 'dart:async';
import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'alarms.dart';
import 'codex_client.dart';
import 'history.dart';

/// What the app should do after a turn: make its scheduled alarms match
/// [alarms] (every upcoming alarm), then show [text] as a subtitle and speak
/// it.
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

  static const _labelRules =
      "The label is what the alarm is for, in the user's words; it's shown "
      'when the alarm rings. If the user has not said what the alarm is for, '
      'ask before setting it. Never use a placeholder such as "Alarm".';

  static const _time = {
    'type': 'string',
    'description':
        "When the alarm rings: ISO 8601 with the user's UTC offset, "
        'e.g. 2026-09-30T07:00:00+07:00.',
  };

  static const tools = <Item>[
    {
      'type': 'function',
      'name': 'set_alarm',
      'description': "Set a new alarm on the user's phone. $_labelRules",
      'parameters': {
        'type': 'object',
        'properties': {
          'time': _time,
          'label': {'type': 'string'},
        },
        'required': ['time', 'label'],
        'additionalProperties': false,
      },
      'strict': false,
    },
    {
      'type': 'function',
      'name': 'update_alarm',
      'description':
          "Change an upcoming alarm's time and/or label. Use this rather than "
          'setting a new alarm when the user wants to move, rename or add a '
          'note to an existing one. $_labelRules',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'time': _time,
          'label': {'type': 'string'},
        },
        'required': ['id'],
        'additionalProperties': false,
      },
      'strict': false,
    },
    {
      'type': 'function',
      'name': 'delete_alarm',
      'description': 'Delete an upcoming alarm.',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
        },
        'required': ['id'],
        'additionalProperties': false,
      },
      'strict': false,
    },
    {
      'type': 'function',
      'name': 'list_alarms',
      'description':
          'List upcoming alarms and recent past ones (rang, deleted or '
          'failed), with their ids. Call this before updating or deleting an '
          "alarm whose id you don't know.",
      'parameters': {
        'type': 'object',
        'properties': <String, Object>{},
        'additionalProperties': false,
      },
      'strict': false,
    },
  ];

  /// Labels that say nothing about what the alarm is for.
  static const _placeholderLabels = {'alarm', 'an alarm', 'reminder', 'timer'};

  /// How many past alarms list_alarms shows.
  static const _recentAlarms = 10;

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
    return _turn(location);
  }

  /// The user cut off the reply after hearing only [heard] of it. Cancels any
  /// in-flight turn, trims the last reply in history to what was heard, and
  /// tells the model, so history matches what the user actually heard.
  void interrupt(String heard) {
    _cancelInFlight();
    if (history.instructions == null) return;
    final now = _clock();
    history
      ..trimLastReply(heard)
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

  /// The phone couldn't schedule alarm [id]. It's marked failed, so it's no
  /// longer sent to the phone. Returns null if a newer request superseded
  /// this turn.
  Future<Reply?> alarmFailed({
    required int id,
    required String error,
    required String timezone,
  }) {
    final alarm = history.alarms.byId(id);
    if (alarm == null) throw BadRequest('Unknown alarm: $id');
    final location = _start(timezone);
    history.alarms.setStatus(id, 'failed');
    history.append([
      _message(
        'developer',
        'The phone failed to set alarm $id "${alarm.label}" for '
            '${_format(alarm.at, location)}: $error. It has been marked '
            'failed. Tell the user.',
      ),
    ], _clock());
    return _turn(location);
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
  Future<Reply?> _turn(tz.Location location) async {
    final cancel = _inFlight = Completer<void>();
    final turnItems = <Item>[];
    final said = <String>[];
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
                  'output': _runTool(item, location),
                });
          }
        }
        if (!calledTool) break;
      }
      history.append(turnItems, _clock());
      return Reply(said.join(' '), history.alarms.upcoming(_clock()));
    } on Cancelled {
      return null;
    } finally {
      if (identical(_inFlight, cancel)) _inFlight = null;
    }
  }

  /// Runs a tool call and returns its output text for the model. Alarm
  /// changes reach the phone through the reply's upcoming-alarm list.
  String _runTool(Item call, tz.Location location) {
    final Map<String, dynamic> args;
    try {
      args = jsonDecode(call['arguments'] as String) as Map<String, dynamic>;
    } on FormatException {
      return 'Error: arguments are not valid JSON.';
    }
    final alarms = history.alarms;
    final now = _clock();
    try {
      switch (call['name']) {
        case 'set_alarm':
          final alarm = alarms.add(
            _parseTime(args['time']),
            _parseLabel(args['label']),
          );
          return 'Set alarm ${alarm.id}: ${_describe(alarm, location)}.';
        case 'update_alarm':
          final id = _upcomingId(args['id']);
          alarms.update(
            id,
            at: args['time'] == null ? null : _parseTime(args['time']),
            label: args['label'] == null ? null : _parseLabel(args['label']),
          );
          return 'Updated alarm $id: '
              '${_describe(alarms.byId(id)!, location)}.';
        case 'delete_alarm':
          final id = _upcomingId(args['id']);
          alarms.setStatus(id, 'deleted');
          return 'Deleted alarm $id.';
        case 'list_alarms':
          final upcoming = alarms.upcoming(now);
          final past = alarms
              .all()
              .where((alarm) => !alarm.isUpcoming(now))
              .take(_recentAlarms);
          return [
            'Upcoming:',
            if (upcoming.isEmpty) '(none)',
            for (final alarm in upcoming)
              '- ${alarm.id}: ${_describe(alarm, location)}',
            'Recent past:',
            if (past.isEmpty) '(none)',
            for (final alarm in past)
              '- ${alarm.id}: ${_describe(alarm, location)} '
                  '(${alarm.statusAt(now)})',
          ].join('\n');
        default:
          return 'Error: unknown tool.';
      }
    } on _ToolError catch (e) {
      return 'Error: ${e.message}';
    }
  }

  DateTime _parseTime(Object? time) {
    // Without an explicit offset, DateTime.parse would use the Mac's zone.
    if (time is! String || !RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(time)) {
      throw _ToolError('time must be ISO 8601 with a UTC offset.');
    }
    final DateTime at;
    try {
      at = DateTime.parse(time).toUtc();
    } on FormatException {
      throw _ToolError('time is not a valid ISO 8601 datetime.');
    }
    if (!at.isAfter(_clock())) throw _ToolError('that time is in the past.');
    return at;
  }

  static String _parseLabel(Object? label) {
    if (label is! String || label.trim().isEmpty) {
      throw _ToolError('label is required.');
    }
    if (_placeholderLabels.contains(label.trim().toLowerCase())) {
      throw _ToolError(
        '"$label" is a placeholder. Ask the user what the alarm is for.',
      );
    }
    return label.trim();
  }

  int _upcomingId(Object? id) {
    final alarm = id is int ? history.alarms.byId(id) : null;
    if (alarm == null || !alarm.isUpcoming(_clock())) {
      throw _ToolError(
        'no upcoming alarm with id $id. Call list_alarms to see them.',
      );
    }
    return alarm.id;
  }

  String _describe(Alarm alarm, tz.Location location) =>
      '${_format(alarm.at, location)}, "${alarm.label}"';

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

You can set, update, delete and list alarms on the phone with your tools.
Before setting an alarm you need both what it is for and when it should ring;
if either is missing or ambiguous, ask. Resolve relative times ("in 20
minutes", "7 tomorrow") using the current time, and pass the time with the
user's UTC offset. After changing an alarm, confirm it in one short sentence.

Current time when this conversation started: ${_now(location)}. Later
developer messages starting with "Time update:" give the current time.''';

  String _now(tz.Location location) => _format(_clock(), location);

  /// E.g. `Tuesday 2026-09-29T21:00:00-07:00 (America/Los_Angeles)`.
  static String _format(DateTime time, tz.Location location) {
    final now = tz.TZDateTime.from(time, location);
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

class _ToolError implements Exception {
  _ToolError(this.message);
  final String message;
}
