import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'api.dart';

/// Every alarm the server knows about, newest first, cached on the phone so
/// it shows immediately and offline. [refresh] fetches the latest.
class AlarmHistory extends ChangeNotifier {
  /// [read] and [write] persist the cached JSON (e.g. shared preferences).
  AlarmHistory({
    required this.api,
    required String? Function() read,
    required this.write,
  }) {
    try {
      final cached = read();
      if (cached != null) {
        alarms = [
          for (final alarm in jsonDecode(cached) as List)
            BuddyAlarm.fromJson(alarm as Map<String, dynamic>),
        ];
      }
    } on Object catch (e) {
      debugPrint('ignoring bad alarm cache: $e');
    }
  }

  final BuddyApi api;
  final Future<void> Function(String json) write;

  /// The last known alarms; null until the first successful fetch.
  List<BuddyAlarm>? alarms;

  /// Why the last refresh failed, or null if it succeeded.
  Object? error;

  Future<void>? _refreshing;

  /// Fetches the latest alarms and caches them. Concurrent calls share one
  /// request.
  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    try {
      final latest = await api.alarms();
      alarms = latest;
      error = null;
      await write(jsonEncode([for (final alarm in latest) alarm.toJson()]));
    } on Object catch (e) {
      error = e;
    }
    notifyListeners();
  }
}

/// Shows the cached alarm history at once and refreshes it in the background.
class AlarmHistoryPage extends StatefulWidget {
  const AlarmHistoryPage({super.key, required this.history});
  final AlarmHistory history;

  @override
  State<AlarmHistoryPage> createState() => _AlarmHistoryPageState();
}

class _AlarmHistoryPageState extends State<AlarmHistoryPage> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.history.refresh());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Alarm history')),
    body: ListenableBuilder(
      listenable: widget.history,
      builder: (context, _) {
        final alarms = widget.history.alarms;
        final error = widget.history.error;
        if (alarms == null) {
          return error == null
              ? const Center(child: CircularProgressIndicator())
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      "Couldn't load alarms: $error",
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
        }
        return RefreshIndicator(
          onRefresh: widget.history.refresh,
          child: ListView(
            children: [
              if (error != null)
                ListTile(
                  leading: const Icon(Icons.cloud_off),
                  title: const Text('Offline: showing saved alarms'),
                  subtitle: Text('$error', maxLines: 2),
                ),
              if (alarms.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No alarms yet', textAlign: TextAlign.center),
                ),
              for (final alarm in alarms) _AlarmTile(alarm),
            ],
          ),
        );
      },
    ),
  );
}

class _AlarmTile extends StatelessWidget {
  const _AlarmTile(this.alarm);
  final BuddyAlarm alarm;

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final at = alarm.at.toLocal();
    final (icon, color) = switch (alarm.status) {
      'upcoming' => (Icons.alarm, colors.primary),
      'rang' => (Icons.alarm_on, colors.onSurfaceVariant),
      'failed' => (Icons.error_outline, colors.error),
      _ => (Icons.alarm_off, colors.onSurfaceVariant), // deleted
    };
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(alarm.label),
      subtitle: Text(
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(at))}'
        ' · ${localizations.formatMediumDate(at)}',
      ),
      trailing: Text(alarm.status, style: TextStyle(color: color)),
    );
  }
}
