import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import 'src/conversation.dart';

export 'src/codex_client.dart';
export 'src/conversation.dart';
export 'src/history.dart';

/// The app's only endpoint: `POST /event` with one event, answered with
/// `{"commands": [...]}`.
Handler eventHandler(Conversation conversation) => (Request request) async {
  if (request.method != 'POST' || request.url.path != 'event') {
    return Response.notFound('Not found');
  }
  final Map<String, dynamic> event;
  try {
    event = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
  } on FormatException {
    return Response.badRequest(body: 'Body must be a JSON object');
  }
  List<Command> commands;
  try {
    commands = await conversation.handle(event);
  } on BadEvent catch (e) {
    return Response.badRequest(body: e.message);
  } catch (e, stack) {
    // Tell the user out loud rather than leaving the app hanging silently.
    stderr.writeln('Error handling $event: $e\n$stack');
    commands = [
      {'type': 'say', 'text': "Sorry, I couldn't reach the AI just now."},
    ];
  }
  return Response.ok(
    jsonEncode({'commands': commands}),
    headers: {'Content-Type': 'application/json'},
  );
};
