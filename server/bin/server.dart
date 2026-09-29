import 'dart:io';

import 'package:buddy_server/buddy_server.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:timezone/data/latest.dart' as tz_data;

/// Environment:
/// - `HOST`: address to listen on. Set it to the Mac's Tailscale IP so only
///   the tailnet can reach the server (default: 127.0.0.1).
/// - `PORT` (default: 8787)
/// - `BUDDY_MODEL` (default: gpt-6-sol)
/// - `BUDDY_HISTORY` (default: ~/.buddy/history.jsonl)
/// - `CODEX_AUTH` (default: ~/.codex/auth.json, written by `codex login`)
Future<void> main() async {
  tz_data.initializeTimeZones();
  final env = Platform.environment;
  final home = env['HOME']!;
  final conversation = Conversation(
    History(File(env['BUDDY_HISTORY'] ?? '$home/.buddy/history.jsonl')),
    CodexClient(
      authFile: File(env['CODEX_AUTH'] ?? '$home/.codex/auth.json'),
      model: env['BUDDY_MODEL'] ?? 'gpt-6-sol',
    ),
  );
  final server = await shelf_io.serve(
    const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(eventHandler(conversation)),
    env['HOST'] ?? '127.0.0.1',
    int.parse(env['PORT'] ?? '8787'),
  );
  stdout.writeln(
    'buddy server on http://${server.address.host}:${server.port}',
  );
}
