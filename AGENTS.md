# AGENTS.md

Guidance for AI agents working on this repo.

## What buddy is

An Android app (Flutter) with two features:

1. **Voice chat** with an AI, hands-free, with automatic turn-taking.
2. **Alarms set through that conversation.** The user tells the AI what the alarm is for and when. The AI sets it, and the phone rings at that time.

## Principles

- **KISS. Keep the app as thin as possible.** Use existing packages and services instead of writing our own. If a pub.dev package or an off-the-shelf tool does the job, use it.
- **The backend owns all conversation logic.** The app only reports what the user said or pressed, and does what the backend tells it: speak text, show subtitles, schedule alarms. The app never talks to the LLM, never builds prompts and never stores history.
- **Android only**, for now. Don't add iOS-specific work.

## Architecture

```
Android phone (Flutter, thin client)        Mac (always on)
┌────────────────────────────┐              ┌──────────────────────────────┐
│ speech_to_text (STT)       │   events     │ buddy server (Dart, shelf)   │
│ interrupt button           ├─────────────▶│  - conversation history      │
│                            │  Tailscale   │  - prompts + time context    │
│ flutter_tts (speak)        │◀─────────────┤  - tool calls (set_alarm)    │
│ subtitles                  │   commands   │           │                  │
│ alarm package (ring)       │              │           ▼ localhost        │
└────────────────────────────┘              │ OpenAI-compatible proxy on   │
                                            │ the ChatGPT subscription     │
                                            │ (Codex OAuth)                │
                                            └──────────────────────────────┘
```

Repo layout:
- The Flutter app is at the repo root.
- The server is a separate Dart package in `server/`.

### Protocol between app and server

- **One HTTP endpoint:** `POST /event`. The app sends one event, and the server replies with a list of commands for the app to run in order. Plain HTTP; no WebSockets.
- **Every event includes** `timezone`, the phone's IANA timezone (e.g. `America/Los_Angeles`, from `flutter_timezone`). The phone can travel, so the server doesn't assume the Mac's timezone.

| Event (app → server) | Sent when |
|---|---|
| `user_said {text}` | STT returns a final transcript |
| `interrupted` | The user presses the interrupt button |
| `alarm_failed {label, at, error}` | The app couldn't schedule an alarm it was told to set |

| Command (server → app) | App does |
|---|---|
| `say {text}` | Shows `text` as a subtitle and speaks it with TTS, then resumes listening |
| `set_alarm {at, label}` | Schedules an alarm. `at` is an ISO 8601 instant in UTC. |

The app has no logic beyond running commands and reporting events.

### Server responsibilities

- **LLM access.**
  - An **existing** proxy on the Mac logs in with Codex OAuth and exposes an OpenAI-compatible API on localhost. ChatMock is one candidate; verify it before adopting it. Don't write our own OAuth handling.
  - The server calls that proxy. The token never leaves the Mac.
  - This route covers text models only. The Realtime (voice) API doesn't accept ChatGPT subscription tokens, so STT and TTS stay on the phone.
- **Conversation history.**
  - A single ongoing conversation, persisted on the Mac so it survives app and server restarts.
  - Store it as an append-only JSON Lines file, one message per line: system, user, assistant, tool calls and tool results.
- **System prompt,** written once at the start of the conversation and never rewritten. It contains:
  - the current local date and time, UTC offset and IANA timezone,
  - an instruction to keep replies short and conversational, because they're spoken aloud,
  - instructions for using `set_alarm`, including asking when the purpose or time is unclear.
- **Time updates:** when a `user_said` event arrives **5 minutes or more** after the last message, append a system message with the current local date and time, UTC offset and IANA timezone (from the event), just before the user message. Never edit earlier messages.
- **Alarm tool.**
  - The LLM gets one tool, `set_alarm(time, label)`:
    - `time`: an ISO 8601 datetime with a UTC offset, resolved from what the user said ("7am tomorrow", "in 20 minutes").
    - `label`: what the alarm is for, taken from the user.
  - If the purpose or the time is missing or ambiguous, the AI asks before calling the tool.
  - When the LLM calls the tool, the server:
    1. converts the time to UTC,
    2. records a tool result saying the alarm was sent to the phone,
    3. lets the LLM produce its spoken confirmation,
    4. returns `set_alarm` followed by `say`.
  - If the app later sends `alarm_failed`, the server adds it to the history and has the LLM tell the user.
- **Interrupts:** on `interrupted`, cancel any in-flight LLM request, and record in the history that the user cut off the last reply.

### Network: Tailscale, not ngrok

- **Use Tailscale.**
  - The phone reaches the buddy server over a private tailnet. The server isn't on the public internet, so it needs no auth of its own.
  - The proxy binds to localhost only.
- **Not ngrok,** because it would publish a public URL to an endpoint that spends the user's subscription.
- **Trade-offs:**
  - Android allows one active VPN at a time, so Tailscale must be the one that's on.
  - The Mac must be awake and running the server and the proxy. If it isn't, chat fails but **alarms still ring**, because they're scheduled locally on the phone.

### App (Flutter): voice loop and UI

```
listen → end of speech → user_said ─▶ server ─▶ [set_alarm] say → TTS done
   ↑                                                                 │
   └─────────────────────────────────────────────────────────────────┘
```

- **STT:** use `speech_to_text`, which wraps Android `SpeechRecognizer`. The OS decides when the user stops talking, so no push-to-talk is needed.
- **TTS:** use `flutter_tts`, which uses Android's on-device TTS.
- **Subtitles:** show the text of the current `say` while it's being spoken.
- **Interrupt button:** always visible while waiting on the server or speaking. Pressing it:
  1. stops TTS locally and immediately; don't wait for the network,
  2. sends `interrupted`,
  3. returns to listening.

  This is the only way to cut the AI off. Talking over it isn't supported, because the mic would hear the phone's own speaker.
- **Alarms:**
  - Use the `alarm` package, which uses Android `AlarmManager` with a full-screen alert. The ringing alarm shows its label.
  - The manifest needs the exact-alarm and full-screen-intent permissions that the package documents. Request notification permission at runtime.
- **Known limitations** (accepted for v1):
  - The silence timeout isn't reliably tunable, so long pauses may end a turn early.
  - Some devices beep when listening starts.
  - STT quality is Android's.
- **Upgrade path, only if v1 feels bad:**
  - On the phone: Silero VAD (`vad` package) plus audio capture in voice-communication mode (OS echo cancellation).
  - On the Mac: Whisper STT and local TTS.

  Moving STT and TTS to the server would add audio events and commands but leave the architecture unchanged.

## Open questions

- Which proxy to use on the Mac. Check that it's maintained, supports tool calling, works with the current Codex OAuth flow, and accepts system messages in the middle of a conversation.
- History will eventually outgrow the model's context window. Decide how to trim it (e.g. send only the most recent N messages), or whether to summarize old messages.
- Where the server URL (the Mac's tailnet address) is configured: a settings field in the app, or a build-time constant.
