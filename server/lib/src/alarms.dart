import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// One alarm the server knows about. The server is the source of truth; the
/// phone mirrors the upcoming ones.
class Alarm {
  Alarm({
    required this.id,
    required this.at,
    required this.label,
    required this.status,
  });

  final int id;
  final DateTime at;
  final String label;

  /// `active`, `deleted` or `failed`. An active alarm whose time has passed
  /// has rung.
  final String status;

  bool isUpcoming(DateTime now) => status == 'active' && at.isAfter(now);

  /// `upcoming`, `rang`, `deleted` or `failed`.
  String statusAt(DateTime now) => status != 'active'
      ? status
      : isUpcoming(now)
      ? 'upcoming'
      : 'rang';

  /// For the phone to schedule.
  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.toUtc().toIso8601String(),
    'label': label,
  };
}

/// Alarms in SQLite, next to the conversation.
class Alarms {
  Alarms(this._db) {
    final isNew = _db
        .select(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'alarms'",
        )
        .isEmpty;
    _db.execute('''
      CREATE TABLE IF NOT EXISTS alarms (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at TEXT NOT NULL,
        label TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active'
          CHECK (status IN ('active', 'deleted', 'failed'))
      );
    ''');
    if (isNew) _backfill();
  }

  final Database _db;

  Alarm add(DateTime at, String label) {
    _db.execute('INSERT INTO alarms (at, label) VALUES (?, ?)', [
      _stamp(at),
      label,
    ]);
    return byId(_db.lastInsertRowId)!;
  }

  Alarm? byId(int id) {
    final row = _db.select('SELECT * FROM alarms WHERE id = ?', [id]);
    return row.isEmpty ? null : _alarm(row.single);
  }

  void update(int id, {DateTime? at, String? label}) => _db.execute(
    'UPDATE alarms SET at = coalesce(?, at), label = coalesce(?, label) '
    'WHERE id = ?',
    [if (at != null) _stamp(at) else null, label, id],
  );

  void setStatus(int id, String status) =>
      _db.execute('UPDATE alarms SET status = ? WHERE id = ?', [status, id]);

  /// Active alarms that haven't rung yet, soonest first.
  List<Alarm> upcoming(DateTime now) => [
    for (final row in _db.select(
      "SELECT * FROM alarms WHERE status = 'active' AND at > ? ORDER BY at",
      [_stamp(now)],
    ))
      _alarm(row),
  ];

  /// Every alarm, newest first.
  List<Alarm> all() => [
    for (final row in _db.select('SELECT * FROM alarms ORDER BY at DESC, id'))
      _alarm(row),
  ];

  /// Alarms set before this table existed live only as set_alarm calls in the
  /// conversation; copy them in so they show up in the alarm history.
  void _backfill() {
    // Only calls the server accepted; rejected ones got an "Error: ..." output.
    final calls = _db.select('''
      SELECT call.item ->> '\$.arguments' AS arguments
      FROM items call JOIN items result
        ON result.item ->> '\$.call_id' = call.item ->> '\$.call_id'
      WHERE call.item ->> '\$.type' = 'function_call'
        AND call.item ->> '\$.name' = 'set_alarm'
        AND result.item ->> '\$.type' = 'function_call_output'
        AND result.item ->> '\$.output' = 'Alarm sent to the phone.'
      ORDER BY call.id
    ''');
    for (final call in calls) {
      try {
        final args =
            jsonDecode(call['arguments'] as String) as Map<String, dynamic>;
        add(DateTime.parse(args['time'] as String), args['label'] as String);
      } on Object {
        // A malformed call never set an alarm; nothing to copy.
      }
    }
  }

  static Alarm _alarm(Row row) => Alarm(
    id: row['id'] as int,
    at: DateTime.parse(row['at'] as String),
    label: row['label'] as String,
    status: row['status'] as String,
  );

  static String _stamp(DateTime at) => at.toUtc().toIso8601String();
}
