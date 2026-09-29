import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'src/conversation.dart';

export 'src/alarms.dart';
export 'src/codex_client.dart';
export 'src/conversation.dart';
export 'src/history.dart';

/// The app's API. See AGENTS.md.
Handler api(Conversation conversation) =>
    (Router()
          // For checking the server is up without touching the conversation.
          ..get('/health', (Request request) => Response.ok('ok'))
          // Every alarm, newest first, for the app's alarm history.
          ..get('/alarms', (Request request) {
            final now = DateTime.now();
            return Response.ok(
              jsonEncode({
                'alarms': [
                  for (final alarm in conversation.history.alarms.all())
                    {...alarm.toJson(), 'status': alarm.statusAt(now)},
                ],
              }),
              headers: {'Content-Type': 'application/json'},
            );
          })
          ..post(
            '/message',
            (Request request) => _reply(
              request,
              (body) => conversation.message(
                _string(body, 'text'),
                timezone: _string(body, 'timezone'),
              ),
            ),
          )
          ..post('/interrupt', (Request request) async {
            try {
              conversation.interrupt(_string(await _json(request), 'heard'));
            } on BadRequest catch (e) {
              return Response.badRequest(body: e.message);
            }
            return Response(HttpStatus.noContent);
          })
          ..post(
            '/alarm-failed',
            (Request request) => _reply(
              request,
              (body) => conversation.alarmFailed(
                id: switch (body['id']) {
                  final int id => id,
                  _ => throw BadRequest('Missing int field: id'),
                },
                error: _string(body, 'error'),
                timezone: _string(body, 'timezone'),
              ),
            ),
          ))
        .call;

/// 200 with the reply, 204 if a newer request superseded the turn, 400 for
/// bad input.
Future<Response> _reply(
  Request request,
  Future<Reply?> Function(Map<String, dynamic> body) turn,
) async {
  Reply? reply;
  try {
    reply = await turn(await _json(request));
  } on BadRequest catch (e) {
    return Response.badRequest(body: e.message);
  } catch (e, stack) {
    // Tell the user out loud rather than leaving the app hanging silently.
    stderr.writeln('Turn failed: $e\n$stack');
    reply = Reply("Sorry, I couldn't reach the AI just now.", []);
  }
  if (reply == null) return Response(HttpStatus.noContent);
  return Response.ok(
    jsonEncode(reply),
    headers: {'Content-Type': 'application/json'},
  );
}

Future<Map<String, dynamic>> _json(Request request) async {
  try {
    return jsonDecode(await request.readAsString()) as Map<String, dynamic>;
  } on Object {
    throw BadRequest('Body must be a JSON object');
  }
}

String _string(Map<String, dynamic> body, String key) => switch (body[key]) {
  final String value => value,
  _ => throw BadRequest('Missing string field: $key'),
};
