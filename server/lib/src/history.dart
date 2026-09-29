import 'dart:convert';
import 'dart:io';

import 'codex_client.dart';

/// The single ongoing conversation, persisted as append-only JSON Lines.
///
/// The first line holds the system prompt (`{"at", "instructions"}`). Other
/// lines hold one Responses API item (`{"at", "item"}`), or record that the
/// user cut off the last reply after hearing only some of it
/// (`{"at", "heard"}`); that trim is re-applied on load.
class History {
  History(this.file) {
    if (!file.existsSync()) return;
    for (final line in file.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final record = jsonDecode(line) as Map<String, dynamic>;
      _instructions ??= record['instructions'] as String?;
      if (record['item'] case final Item item) _items.add(item);
      if (record['heard'] case final String heard) _trimLastReply(heard);
      _lastAt = DateTime.parse(record['at'] as String);
    }
  }

  final File file;
  String? _instructions;
  final _items = <Item>[];
  DateTime? _lastAt;

  String? get instructions => _instructions;
  List<Item> get items => List.unmodifiable(_items);

  /// When the last record was written, or null for a new conversation.
  DateTime? get lastAt => _lastAt;

  void start(String instructions, DateTime at) {
    if (_instructions != null) throw StateError('Conversation already started');
    _instructions = instructions;
    _write([
      {'at': _stamp(at), 'instructions': instructions},
    ], at);
  }

  void append(List<Item> items, DateTime at) {
    if (items.isEmpty) return;
    _items.addAll(items);
    _write([
      for (final item in items) {'at': _stamp(at), 'item': item},
    ], at);
  }

  /// Trims the assistant text of the last turn to what the user [heard]
  /// before interrupting, so the model only sees what was actually said.
  /// Tool calls in that turn are kept.
  void trimLastReply(String heard, DateTime at) {
    _trimLastReply(heard);
    _write([
      {'at': _stamp(at), 'heard': heard},
    ], at);
  }

  void _trimLastReply(String heard) {
    // The last turn is everything after the last user or developer message.
    final turnStart =
        _items.lastIndexWhere(
          (item) =>
              item['type'] == 'message' &&
              (item['role'] == 'user' || item['role'] == 'developer'),
        ) +
        1;
    // The app heard the turn's assistant messages joined with spaces.
    var remaining = heard.length;
    for (var i = turnStart; i < _items.length; i++) {
      final item = _items[i];
      if (item['type'] != 'message' || item['role'] != 'assistant') continue;
      final text = messageText(item);
      if (remaining >= text.length) {
        remaining -= text.length + 1;
      } else if (remaining > 0) {
        _items[i] = assistantMessage(text.substring(0, remaining).trimRight());
        remaining = 0;
      } else {
        _items.removeAt(i--);
      }
    }
  }

  void _write(List<Map<String, dynamic>> records, DateTime at) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      records.map((r) => '${jsonEncode(r)}\n').join(),
      mode: FileMode.append,
      flush: true,
    );
    _lastAt = at;
  }

  static String _stamp(DateTime at) => at.toUtc().toIso8601String();
}

Item assistantMessage(String text) => {
  'type': 'message',
  'role': 'assistant',
  'content': [
    {'type': 'output_text', 'text': text},
  ],
};

/// The text of a message item.
String messageText(Item message) => (message['content'] as List)
    .map((part) => (part as Map)['text'] ?? '')
    .join();
