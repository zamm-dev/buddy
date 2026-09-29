import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'codex_client.dart';

/// The single ongoing conversation, stored in SQLite. This is the canonical
/// history: what the model is sent is exactly what's in the `items` table.
class History {
  History(String path) : _db = _open(path);

  final Database _db;

  static Database _open(String path) {
    File(path).parent.createSync(recursive: true);
    return sqlite3.open(path)..execute('''
      CREATE TABLE IF NOT EXISTS conversation (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        instructions TEXT NOT NULL,
        started_at TEXT NOT NULL
      );
      -- One Responses API item (message, function_call, ...) per row, as JSON.
      CREATE TABLE IF NOT EXISTS items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at TEXT NOT NULL,
        item TEXT NOT NULL
      );
    ''');
  }

  /// The system prompt, or null for a new conversation.
  String? get instructions =>
      _db
              .select('SELECT instructions FROM conversation')
              .firstOrNull?['instructions']
          as String?;

  List<Item> get items => [
    for (final row in _db.select('SELECT item FROM items ORDER BY id'))
      jsonDecode(row['item'] as String) as Item,
  ];

  /// When the last item was written (or the conversation started), or null
  /// for a new conversation.
  DateTime? get lastAt {
    final row = _db.select('''
      SELECT coalesce(
        (SELECT at FROM items ORDER BY id DESC LIMIT 1),
        (SELECT started_at FROM conversation)
      ) AS at
    ''').single;
    return switch (row['at']) {
      final String at => DateTime.parse(at),
      _ => null,
    };
  }

  void start(String instructions, DateTime at) => _db.execute(
    'INSERT INTO conversation (id, instructions, started_at) VALUES (1, ?, ?)',
    [instructions, _stamp(at)],
  );

  void append(List<Item> items, DateTime at) => _transaction(() {
    for (final item in items) {
      _db.execute('INSERT INTO items (at, item) VALUES (?, ?)', [
        _stamp(at),
        jsonEncode(item),
      ]);
    }
  });

  /// Trims the assistant text of the last turn to what the user [heard]
  /// before interrupting, so the model only sees what was actually said.
  /// Tool calls in that turn are kept.
  void trimLastReply(String heard) => _transaction(() {
    // The last turn is everything after the last user or developer message.
    final turn = _db.select('''
      SELECT id, item FROM items
      WHERE id > coalesce((
        SELECT max(id) FROM items
        WHERE item ->> '\$.type' = 'message'
          AND item ->> '\$.role' IN ('user', 'developer')
      ), 0)
        AND item ->> '\$.type' = 'message'
        AND item ->> '\$.role' = 'assistant'
      ORDER BY id
    ''');
    // The app heard the turn's assistant messages joined with spaces.
    var remaining = heard.length;
    for (final row in turn) {
      final text = messageText(jsonDecode(row['item'] as String) as Item);
      if (remaining >= text.length) {
        remaining -= text.length + 1;
      } else if (remaining > 0) {
        _db.execute('UPDATE items SET item = ? WHERE id = ?', [
          jsonEncode(
            assistantMessage(text.substring(0, remaining).trimRight()),
          ),
          row['id'],
        ]);
        remaining = 0;
      } else {
        _db.execute('DELETE FROM items WHERE id = ?', [row['id']]);
      }
    }
  });

  void close() => _db.close();

  void _transaction(void Function() body) {
    _db.execute('BEGIN');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
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
