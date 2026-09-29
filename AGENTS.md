# AGENTS.md

Guidance for AI agents working on this repo.

## What buddy is

An Android app (Flutter) with two features:

1. **Voice chat** with an AI, hands-free, with automatic turn-taking.
2. **Alarms set through that conversation.** The user tells the AI what the alarm is for and when. The AI sets it, and the phone rings at that time.

## Principles

- **KISS. Keep the app as thin as possible.** Use existing packages and services instead of writing our own. If a pub.dev package or an off-the-shelf tool does the job, use it.
- **No custom backend code unless unavoidable.** The Mac side should be an existing tool that we configure, not a server we write.
- **Android only**, for now. Don't add iOS-specific work.

## Architecture

```
Android phone (Flutter)                        Mac (always on)
┌──────────────────────────────┐               ┌───────────────────────────────┐
│ speech_to_text (Android STT) │               │ OpenAI-compatible proxy that  │
│   → final transcript         │  Tailscale    │ uses the ChatGPT subscription │
│ LLM call with tools ─────────┼──────────────▶│ via Codex OAuth login         │
│   ← reply text / tool call   │               └───────────────────────────────┘
│ flutter_tts speaks the reply │
│ alarm package rings alarms   │
└──────────────────────────────┘
```

### LLM access: the ChatGPT subscription through a proxy on the Mac

- The model is billed to the user's ChatGPT subscription through the Codex OAuth login. There's no pay-per-token API key.
- On the Mac, run an **existing** proxy that logs in with Codex OAuth and exposes an OpenAI-compatible HTTP API. ChatMock is one example; verify it's maintained and supports tool calling before adopting it. Don't write our own.
- The phone calls that API directly with a standard OpenAI-compatible client. It handles the conversation history and tool calls itself.
- The token stays on the Mac. Never put it in the app.
- **Limitation:** this route covers text models only. The Realtime (voice) API does not accept ChatGPT subscription tokens, so speech is handled on the phone.

### Network: Tailscale, not ngrok

- **Use Tailscale.** The phone reaches the Mac over a private tailnet. The proxy is never on the public internet, so it needs no auth of its own, and it's reachable from home or away.
- **Not ngrok,** because ngrok would publish a public URL to an endpoint that spends the user's subscription. We'd then have to add and maintain auth in front of it.
- **Trade-offs:**
  - Android allows one active VPN at a time, so Tailscale must be the one that's on.
  - The Mac must be awake and running the proxy. If it isn't, chat fails but **alarms still ring**, because they're scheduled locally on the phone.

### Voice loop (half-duplex)

```
listen → Android detects end of speech → transcript → LLM → reply
   ↑                                                           ↓
   └──────────── TTS finishes speaking ◀──── flutter_tts ◀─────┘
```

- **STT:** use `speech_to_text`, which wraps Android `SpeechRecognizer`. The OS decides when the user stops talking, so no push-to-talk is needed.
- **TTS:** use `flutter_tts`, which uses Android's on-device TTS.
- **Interrupt button:** always visible while the AI is thinking or speaking. Pressing it:
  1. stops TTS immediately,
  2. cancels the in-flight LLM request, if there is one,
  3. returns to listening.

  This is the only way to cut the AI off. Talking over it isn't supported, because the mic would hear the phone's own speaker.
- **Known limitations** (accepted for v1):
  - The silence timeout isn't reliably tunable, so long pauses may end a turn early.
  - Some devices beep when listening starts.
  - STT quality is Android's.
- **Upgrade path, only if v1 feels bad:**
  - On the phone: Silero VAD (`vad` package) plus audio capture in voice-communication mode (OS echo cancellation), which would allow talking over the AI.
  - On the Mac: Whisper for STT and a local TTS model.

  The UI and the LLM layer shouldn't need to change for this.

### Alarms (set by the AI through tool calling)

- **Tool:** the LLM gets one tool, `set_alarm(time, label)`:
  - `time`: an ISO 8601 datetime with a UTC offset, resolved by the model from what the user said ("7am tomorrow", "in 20 minutes").
  - `label`: what the alarm is for, taken from the user.
- **Ask, don't guess:** if the purpose or the time is missing or ambiguous, the AI asks before calling the tool.
- **On a tool call:**
  - The app schedules the alarm with the `alarm` package (Android `AlarmManager` plus a full-screen alert), then returns the result to the LLM so it can confirm out loud.
  - When the alarm rings, it shows its label.
- **Permissions:**
  - The Android manifest needs the exact-alarm and full-screen-intent permissions that the `alarm` package documents.
  - Request notification permission at runtime.

### Conversation history and time context

- **The app keeps the full message history** (system, user, assistant, tool calls and results) and sends it with every request. The model has no memory of its own.
- **The system prompt is written once,** at the start of the conversation, and never rewritten. It contains:
  - the current local date and time, with UTC offset,
  - the IANA timezone name, e.g. `America/Los_Angeles`. Use `flutter_timezone`, since `DateTime.timeZoneName` only gives an abbreviation,
  - an instruction to keep replies short and conversational, because they're spoken aloud,
  - instructions for using `set_alarm`, including asking when the purpose or time is unclear.
- **Time updates:** when the user speaks after a gap of **5 minutes or more** since the last message, insert a system message with the current local date and time, UTC offset and IANA timezone, just before the new user message. Append it to the history like any other message. Don't edit earlier messages.

## Open questions

- Which proxy to use on the Mac. Check that it's maintained, supports tool calling, works with the current Codex OAuth flow, and accepts system messages in the middle of a conversation.
- Whether history persists across app restarts, or lasts only while the app is open.
- Where the proxy URL (the Mac's tailnet address) is configured: a settings field in the app, or a build-time constant.
