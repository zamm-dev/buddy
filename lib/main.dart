import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:alarm/utils/alarm_set.dart';
import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:permission_handler/permission_handler.dart';

import 'api.dart';
import 'platform.dart';
import 'voice_loop.dart';

/// The Mac's buddy server, e.g. `http://100.101.102.103:8787/`.
/// Build with `--dart-define=BUDDY_SERVER=<url>`.
const serverUrl = String.fromEnvironment('BUDDY_SERVER');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alarm.init();
  runApp(const BuddyApp());
}

class BuddyApp extends StatelessWidget {
  const BuddyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'buddy',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  VoiceLoop? _loop;
  String? _setupError;
  AlarmSettings? _ringing;
  StreamSubscription<AlarmSet>? _ringingSub;

  @override
  void initState() {
    super.initState();
    _ringingSub = Alarm.ringing.listen(
      (set) => setState(() => _ringing = set.alarms.firstOrNull),
    );
    unawaited(_start());
  }

  Future<void> _start() async {
    if (serverUrl.isEmpty) {
      return setState(
        () => _setupError =
            'No server configured. Build with '
            '--dart-define=BUDDY_SERVER=http://<mac-tailscale-ip>:8787/',
      );
    }
    await Permission.notification.request();
    await Permission.scheduleExactAlarm.request();
    final ears = SttEars();
    if (!await ears.init()) {
      return setState(
        () => _setupError =
            'Speech recognition is unavailable or the microphone '
            'permission was denied.',
      );
    }
    final loop = VoiceLoop(
      api: BuddyApi(Uri.parse(serverUrl)),
      ears: ears,
      mouth: TtsMouth(),
      alarms: PhoneAlarmClock(),
      timezone: () async =>
          (await FlutterTimezone.getLocalTimezone()).identifier,
    );
    setState(() => _loop = loop);
    unawaited(loop.run());
  }

  @override
  void dispose() {
    unawaited(_ringingSub?.cancel());
    _loop?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ringing = _ringing;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ringing != null
              ? _Ringing(ringing)
              : _setupError != null
              ? Center(child: Text(_setupError!, textAlign: TextAlign.center))
              : _loop == null
              ? const Center(child: CircularProgressIndicator())
              : ListenableBuilder(
                  listenable: _loop!,
                  builder: (context, _) => _Conversation(_loop!),
                ),
        ),
      ),
    );
  }
}

class _Conversation extends StatelessWidget {
  const _Conversation(this.loop);
  final VoiceLoop loop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(switch (loop.state) {
          VoiceState.listening => 'Listening…',
          VoiceState.thinking => 'Thinking…',
          VoiceState.speaking => 'Speaking',
        }, style: theme.textTheme.labelLarge),
        const SizedBox(height: 16),
        Text(
          loop.userText,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: Text(
                loop.subtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
            ),
          ),
        ),
        if (loop.state != VoiceState.listening)
          FilledButton.icon(
            onPressed: loop.interrupt,
            icon: const Icon(Icons.stop),
            label: const Text('Interrupt'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(72),
              textStyle: theme.textTheme.titleLarge,
            ),
          ),
      ],
    );
  }
}

class _Ringing extends StatelessWidget {
  const _Ringing(this.alarm);
  final AlarmSettings alarm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        const Icon(Icons.alarm, size: 96),
        const SizedBox(height: 24),
        Text(
          alarm.notificationSettings.body,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium,
        ),
        const Spacer(),
        FilledButton(
          onPressed: () => Alarm.stop(alarm.id),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(72),
            textStyle: theme.textTheme.titleLarge,
          ),
          child: const Text('Stop'),
        ),
      ],
    );
  }
}
