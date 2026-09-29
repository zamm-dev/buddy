import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';

/// Speech-to-text: one utterance at a time.
abstract interface class Ears {
  /// Listens until the user stops talking. Returns the final transcript, or
  /// null if nothing was recognized (silence, no match, error).
  Future<String?> listen();
}

/// Text-to-speech.
abstract interface class Mouth {
  /// Speaks [text], reporting the end offset of each word as it's spoken.
  /// Completes when speech finishes or is stopped.
  Future<void> speak(String text, void Function(int end) onProgress);
  Future<void> stop();
}

/// The phone's alarms.
abstract interface class AlarmClock {
  /// Makes the phone's upcoming alarms exactly [upcoming]: sets new or changed
  /// ones and cancels the rest. Returns the alarms that couldn't be set.
  Future<List<(BuddyAlarm, Object)>> sync(List<BuddyAlarm> upcoming);
}

enum VoiceState { listening, thinking, speaking }

/// The hands-free loop: listen → send → set alarms → speak → listen.
///
/// Holds no conversation state; the server owns that. See AGENTS.md.
class VoiceLoop extends ChangeNotifier {
  VoiceLoop({
    required this.api,
    required this.ears,
    required this.mouth,
    required this.alarms,
    required this.timezone,
    this.onAlarmsSynced,
  });

  final BuddyApi api;
  final Ears ears;
  final Mouth mouth;
  final AlarmClock alarms;
  final Future<String> Function() timezone;

  /// Called after each reply's alarms are synced, e.g. to refresh caches.
  final void Function()? onAlarmsSynced;

  VoiceState state = VoiceState.listening;

  /// What the user last said.
  String userText = '';

  /// What buddy is saying (or an error to show).
  String subtitle = '';

  var _running = false;
  var _interrupted = false;
  String? _speaking;
  var _spokenUpTo = 0;
  Future<void>? _interruptSent;

  /// Runs until [dispose].
  Future<void> run() async {
    _running = true;
    while (_running) {
      _set(VoiceState.listening);
      final started = DateTime.now();
      final text = await ears.listen();
      if (!_running) return;
      if (text == null || text.trim().isEmpty) {
        // Normal silence takes seconds. Returning instantly means the
        // recognizer is failing; back off instead of spinning on it.
        if (DateTime.now().difference(started) < const Duration(seconds: 1)) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        continue;
      }
      userText = text;
      subtitle = '';
      await _turn(() async => api.message(text, timezone: await timezone()));
    }
  }

  /// The interrupt button: stop talking now and tell the server how much of
  /// the reply the user heard.
  void interrupt() {
    if (state == VoiceState.listening || _interrupted) return;
    _interrupted = true;
    final heard = _speaking?.substring(0, _spokenUpTo).trimRight() ?? '';
    unawaited(mouth.stop());
    _interruptSent = api.interrupt(heard).catchError((Object e) {
      debugPrint('interrupt failed: $e');
    });
  }

  Future<void> _turn(Future<Reply?> Function() request) async {
    _interrupted = false;
    _set(VoiceState.thinking);
    Reply? reply;
    try {
      reply = await request();
    } catch (e) {
      subtitle = 'Problem talking to the buddy server: $e';
      notifyListeners();
      // Don't spin if the server is down; STT would re-trigger immediately.
      await Future<void>.delayed(const Duration(seconds: 2));
      return;
    } finally {
      await _flushInterrupt();
    }
    if (reply == null) return;

    // Alarms are synced even if the user interrupted: the server has already
    // recorded the changes.
    final failures = await alarms.sync(reply.alarms);
    onAlarmsSynced?.call();

    if (!_interrupted && reply.text.isNotEmpty) {
      subtitle = reply.text;
      _speaking = reply.text;
      _spokenUpTo = 0;
      _set(VoiceState.speaking);
      await mouth.speak(reply.text, (end) => _spokenUpTo = end);
      _speaking = null;
      await _flushInterrupt();
    }

    for (final (alarm, error) in failures) {
      await _turn(
        () async => api.alarmFailed(
          alarm: alarm,
          error: '$error',
          timezone: await timezone(),
        ),
      );
    }
  }

  /// Makes sure the server has the interrupt before the next request.
  Future<void> _flushInterrupt() async {
    final sent = _interruptSent;
    _interruptSent = null;
    await sent;
  }

  void _set(VoiceState next) {
    state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _running = false;
    super.dispose();
  }
}
