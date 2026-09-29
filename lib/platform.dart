import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'api.dart';
import 'voice_loop.dart';

/// Android speech recognition via `speech_to_text`. The OS decides when the
/// user has stopped talking.
class SttEars implements Ears {
  final _stt = SpeechToText();
  Completer<String?>? _utterance;

  /// Returns false if speech recognition is unavailable or the microphone
  /// permission was denied.
  Future<bool> init() => _stt.initialize(
    onStatus: (status) {
      debugPrint('stt status: $status');
      if (status == SpeechToText.doneStatus) _finish(null);
    },
    onError: (error) {
      debugPrint(
        'stt error: ${error.errorMsg} (permanent: ${error.permanent})',
      );
      _finish(null);
    },
  );

  @override
  Future<String?> listen() async {
    // Android ignores a new session until the previous one has fully ended
    // ("capacity is full"), and reports it as an error.
    while (_stt.isListening) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final utterance = _utterance = Completer<String?>();
    await _stt.listen(
      onResult: (result) {
        if (result.finalResult) _finish(result.recognizedWords);
      },
      listenOptions: SpeechListenOptions(
        partialResults: false,
        listenMode: ListenMode.dictation,
        cancelOnError: true,
        listenFor: const Duration(minutes: 1),
      ),
    );
    return utterance.future;
  }

  void _finish(String? text) {
    final utterance = _utterance;
    if (utterance != null && !utterance.isCompleted) utterance.complete(text);
  }
}

/// Android text-to-speech via `flutter_tts`.
class TtsMouth implements Mouth {
  TtsMouth() {
    unawaited(_tts.awaitSpeakCompletion(true));
    _tts.setProgressHandler((text, start, end, word) => _onProgress?.call(end));
  }

  final _tts = FlutterTts();
  void Function(int end)? _onProgress;

  @override
  Future<void> speak(String text, void Function(int end) onProgress) async {
    _onProgress = onProgress;
    try {
      // With awaitSpeakCompletion, this completes when speech ends or stops.
      await _tts.speak(text);
    } finally {
      _onProgress = null;
    }
  }

  @override
  Future<void> stop() => _tts.stop();
}

/// Real alarms via the `alarm` package (AlarmManager + full-screen alert).
class PhoneAlarmClock implements AlarmClock {
  @override
  Future<void> schedule(AlarmRequest alarm) async {
    final ok = await Alarm.set(
      alarmSettings: AlarmSettings(
        // Stable per alarm, never 0 or -1.
        id: Object.hash(alarm.at, alarm.label) & 0x7fffffff | 1,
        dateTime: alarm.at.toLocal(),
        // null = the device's default alarm sound.
        assetAudioPath: null,
        warningNotificationOnKill: false,
        volumeSettings: const VolumeSettings.fixed(),
        notificationSettings: NotificationSettings(
          title: 'buddy',
          body: alarm.label,
          stopButton: 'Stop',
        ),
      ),
    );
    if (!ok) throw StateError('The alarm plugin refused to set the alarm');
  }
}
