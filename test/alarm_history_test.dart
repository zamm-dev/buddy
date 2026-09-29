import 'dart:convert';

import 'package:buddy/alarm_history.dart';
import 'package:buddy/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const cached =
      '[{"id":1,"at":"2026-09-29T06:18:11.000Z","label":"test","status":"rang"}]';
  final serverAlarms = {
    'alarms': [
      {
        'id': 2,
        'at': '2026-09-30T00:00:00.000Z',
        'label': 'gym',
        'status': 'upcoming',
      },
      {
        'id': 1,
        'at': '2026-09-29T06:18:11.000Z',
        'label': 'test',
        'status': 'rang',
      },
    ],
  };

  late String? stored;
  late bool online;

  AlarmHistory history() => AlarmHistory(
    api: BuddyApi(
      Uri.parse('http://mac:8787/'),
      MockClient((request) async {
        if (!online) throw http.ClientException('no route to host');
        return http.Response(jsonEncode(serverAlarms), 200);
      }),
    ),
    read: () => stored,
    write: (json) async => stored = json,
  );

  setUp(() {
    stored = cached;
    online = true;
  });

  test('cached alarms are available immediately, before any request', () {
    expect(history().alarms!.single.label, 'test');
  });

  test('refresh replaces and re-caches the alarms', () async {
    final h = history();
    await h.refresh();
    expect([for (final a in h.alarms!) a.label], ['gym', 'test']);
    expect(history().alarms, hasLength(2)); // Persisted for next launch.
  });

  test('offline: keeps showing the cache and reports the error', () async {
    online = false;
    final h = history();
    await h.refresh();
    expect(h.alarms!.single.label, 'test');
    expect(h.error, isA<http.ClientException>());
  });

  test('no cache yet: alarms is null until the first fetch', () async {
    stored = null;
    final h = history();
    expect(h.alarms, isNull);
    await h.refresh();
    expect(h.alarms, hasLength(2));
  });
}
