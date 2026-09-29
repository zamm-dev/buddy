import 'dart:convert';

import 'package:http/http.dart' as http;

/// An alarm the server wants scheduled.
class AlarmRequest {
  AlarmRequest(this.at, this.label);
  final DateTime at;
  final String label;
}

/// The server's answer to a turn: schedule [alarms], then speak [text].
class Reply {
  Reply(this.text, this.alarms);
  final String text;
  final List<AlarmRequest> alarms;
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
    required AlarmRequest alarm,
    required String error,
    required String timezone,
  }) => _turn('alarm-failed', {
    'label': alarm.label,
    'at': alarm.at.toUtc().toIso8601String(),
    'error': error,
    'timezone': timezone,
  });

  Future<Reply?> _turn(String path, Map<String, Object> body) async {
    final res = await _post(path, body);
    if (res.statusCode == 204) return null;
    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return Reply(json['text'] as String, [
      for (final alarm in json['alarms'] as List)
        AlarmRequest(
          DateTime.parse((alarm as Map)['at'] as String),
          alarm['label'] as String,
        ),
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
