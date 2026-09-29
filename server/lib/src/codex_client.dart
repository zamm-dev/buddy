import 'dart:convert';
import 'dart:io';

/// A Responses API item (message, function_call, function_call_output, ...).
typedef Item = Map<String, dynamic>;

/// Thrown when a request is cancelled through its `cancelled` future.
class Cancelled implements Exception {}

/// Something that turns a conversation into the model's next output items.
abstract interface class Llm {
  Future<List<Item>> respond({
    required String instructions,
    required List<Item> input,
    required List<Item> tools,
    Future<void>? cancelled,
  });
}

/// Calls the Codex backend with the ChatGPT subscription login that
/// `codex login` stores in `auth.json`. Endpoint, headers and refresh flow
/// mirror openai/codex (codex-rs); see AGENTS.md.
class CodexClient implements Llm {
  CodexClient({required this.authFile, required this.model});

  static final _endpoint = Uri.parse(
    'https://chatgpt.com/backend-api/codex/responses',
  );
  static final _refreshEndpoint = Uri.parse(
    'https://auth.openai.com/oauth/token',
  );
  // The Codex CLI's public OAuth client ID (codex-rs/login/src/auth/manager.rs).
  static const _clientId = 'app_EMoamEEZ73f0CkXaXp7hrann';

  final File authFile;
  final String model;

  @override
  Future<List<Item>> respond({
    required String instructions,
    required List<Item> input,
    required List<Item> tools,
    Future<void>? cancelled,
  }) async {
    final body = jsonEncode({
      'model': model,
      'instructions': instructions,
      'input': input,
      'tools': tools,
      'tool_choice': 'auto',
      'parallel_tool_calls': false,
      'store': false,
      'stream': true,
      'include': <String>[],
    });
    try {
      return await _post(body, cancelled);
    } on _Unauthorized {
      await _refresh();
      return _post(body, cancelled);
    }
  }

  Future<List<Item>> _post(String body, Future<void>? cancelled) async {
    // Re-read every time so refreshes done by the Codex CLI are picked up.
    final tokens = _readAuth()['tokens'] as Map<String, dynamic>;
    final client = HttpClient();
    var wasCancelled = false;
    cancelled?.then((_) {
      wasCancelled = true;
      client.close(force: true);
    });
    try {
      final req = await client.postUrl(_endpoint);
      req.headers
        ..set('Authorization', 'Bearer ${tokens['access_token']}')
        ..set('ChatGPT-Account-ID', tokens['account_id'] as String)
        ..set('Content-Type', 'application/json')
        ..set('Accept', 'text/event-stream');
      // Not req.write: HttpClient encodes strings as Latin-1 by default.
      req.add(utf8.encode(body));
      final res = await req.close();
      final lines = res.transform(utf8.decoder).transform(const LineSplitter());
      if (res.statusCode == HttpStatus.unauthorized) throw _Unauthorized();
      if (res.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Codex HTTP ${res.statusCode}: ${(await lines.toList()).join()}',
        );
      }
      final items = <Item>[];
      await for (final line in lines) {
        if (!line.startsWith('data: ')) continue;
        final event = jsonDecode(line.substring(6)) as Map<String, dynamic>;
        switch (event['type']) {
          case 'response.output_item.done':
            items.add(event['item'] as Item);
          case 'response.failed':
            throw HttpException('Codex response failed: ${jsonEncode(event)}');
        }
      }
      return items;
    } catch (_) {
      if (wasCancelled) throw Cancelled();
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> _refresh() async {
    final auth = _readAuth();
    final tokens = auth['tokens'] as Map<String, dynamic>;
    final client = HttpClient();
    try {
      final req = await client.postUrl(_refreshEndpoint);
      req.headers.contentType = ContentType.json;
      req.add(
        utf8.encode(
          jsonEncode({
            'client_id': _clientId,
            'grant_type': 'refresh_token',
            'refresh_token': tokens['refresh_token'],
          }),
        ),
      );
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Token refresh failed (HTTP ${res.statusCode}): $text. '
          'Run `codex login` on the Mac.',
        );
      }
      final refreshed = jsonDecode(text) as Map<String, dynamic>;
      for (final key in ['id_token', 'access_token', 'refresh_token']) {
        if (refreshed[key] != null) tokens[key] = refreshed[key];
      }
      auth['last_refresh'] = DateTime.now().toUtc().toIso8601String();
      authFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(auth),
      );
    } finally {
      client.close();
    }
  }

  Map<String, dynamic> _readAuth() =>
      jsonDecode(authFile.readAsStringSync()) as Map<String, dynamic>;
}

class _Unauthorized implements Exception {}
