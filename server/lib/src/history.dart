import 'dart:convert';
import 'dart:io';

import 'codex_client.dart';

/// The single ongoing conversation, persisted as append-only JSON Lines.
///
/// The first line holds the system prompt (`{"at", "instructions"}`); every
/// other line holds one Responses API item (`{"at", "item"}`).
class History {
  History(this.file) {
    if (!file.existsSync()) return;
    for (final line in file.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final record = jsonDecode(line) as Map<String, dynamic>;
      _instructions ??= record['instructions'] as String?;
      if (record['item'] case final Item item) _items.add(item);
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
