import 'dart:convert';

import 'package:http/http.dart' as http;

/// An alarm as the server knows it.
class BuddyAlarm {
  BuddyAlarm(this.id, this.at, this.label, {this.status = 'upcoming'});

  BuddyAlarm.fromJson(Map<String, dynamic> json)
    : this(
        json['id'] as int,
        DateTime.parse(json['at'] as String),
        json['label'] as String,
        status: json['status'] as String? ?? 'upcoming',
      );

  final int id;
  final DateTime at;
  final String label;

  /// `upcoming`, `rang`, `deleted` or `failed`.
  final String status;

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.toUtc().toIso8601String(),
    'label': label,
    'status': status,
  };
}

/// The server's answer to a turn: make the phone's alarms match [alarms]
/// (every upcoming alarm), then speak [text].
class Reply {
  Reply(this.text, this.alarms);
  final String text;
  final List<BuddyAlarm> alarms;
}

/// Client for the buddy server. See AGENTS.md for the protocol.
class BuddyApi {
  BuddyApi(this.baseUrl, [http.Client? client])
    : _client = client ?? http.Client();

  final Uri baseUrl;
  final http.Client _client;

  /// Returns null if the turn was superseded (e.g. by an interrupt).
  Future<Reply?> message(String text, {required String timezone}) =>
      _turn('message', {'text': text, 'timezone': timezone});

  /// Tells the server the user cut off the reply after hearing [heard].
  Future<void> interrupt(String heard) async {
    await _post('interrupt', {'heard': heard});
  }

  /// Returns null if the turn was superseded.
  Future<Reply?> alarmFailed({
    required BuddyAlarm alarm,
    required String error,
    required String timezone,
  }) => _turn('alarm-failed', {
    'id': alarm.id,
    'error': error,
    'timezone': timezone,
  });

  /// Every alarm, newest first, with its status.
  Future<List<BuddyAlarm>> alarms() async {
    final res = await _client.get(baseUrl.resolve('alarms'));
    if (res.statusCode != 200) {
      throw http.ClientException('HTTP ${res.statusCode}: ${res.body}');
    }
    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return [
      for (final alarm in json['alarms'] as List)
        BuddyAlarm.fromJson(alarm as Map<String, dynamic>),
    ];
  }

  Future<Reply?> _turn(String path, Map<String, Object> body) async {
    final res = await _post(path, body);
    if (res.statusCode == 204) return null;
    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return Reply(json['text'] as String, [
      for (final alarm in json['alarms'] as List)
        BuddyAlarm.fromJson(alarm as Map<String, dynamic>),
    ]);
  }

  Future<http.Response> _post(String path, Map<String, Object> body) async {
    final res = await _client.post(
      baseUrl.resolve(path),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (res.statusCode != 200 && res.statusCode != 204) {
      throw http.ClientException(
        'HTTP ${res.statusCode}: ${res.body}',
        res.request?.url,
      );
    }
    return res;
  }
}
