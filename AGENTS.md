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
│ speech_to_text (STT)       │  requests    │ buddy server (Dart, shelf)   │
│ interrupt button           ├─────────────▶│  - conversation history      │
│                            │  Tailscale   │  - prompts + time context    │
│ flutter_tts (speak)        │◀─────────────┤  - tool calls (set_alarm)    │
│ subtitles                  │  replies     │                              │
│ alarm package (ring)       │              └──────────────┬───────────────┘
└────────────────────────────┘                             │ HTTPS, Codex OAuth token
                                                           ▼
                                            ChatGPT backend (Codex endpoint,
                                            billed to the ChatGPT subscription)
```

Repo layout:
- The Flutter app is at the repo root.
- The server is a separate Dart package in `server/`.

### Protocol between app and server

- **Plain HTTP with specific endpoints**, each with its own response shape. No WebSockets, and no generic event/command envelope.
- **Requests that start a turn include** `timezone`, the phone's IANA timezone (e.g. `America/Los_Angeles`, from `flutter_timezone`). The phone can travel, so the server doesn't assume the Mac's timezone.

| Endpoint | Request body | Called when | Response |
|---|---|---|---|
| `POST /message` | `{text, timezone}` | STT returns a final transcript | `200 {text, alarms}`, or `204` if a newer request superseded it |
| `POST /interrupt` | `{heard}` | The user presses the interrupt button | `204` |
| `POST /alarm-failed` | `{label, at, error, timezone}` | The app couldn't schedule an alarm it was given | `200 {text, alarms}`, or `204` if superseded |
| `GET /health` | none | Checking the server is up (never touches the conversation) | `200 ok` |

- **`heard`** is the part of the current reply's `text` that was spoken before TTS stopped. The app gets it from `flutter_tts`'s progress handler and sends `""` if nothing was spoken.
- **The server holds all conversation state.** The app keeps nothing between requests; it calls `/interrupt` right away instead of saving anything for later.

- **Reply fields** (`200 {text, alarms}`):
  - `alarms` is a list of `{at, label}`, with `at` an ISO 8601 instant in UTC. The app schedules these first.
  - `text` is shown as a subtitle and spoken with TTS. Then the app resumes listening.
- **Errors:**
  - Bad input returns `400` with a plain-text reason.
  - If the model call fails, the server still returns `200`, with `text` apologizing, so the user hears about it.

The app has no logic beyond calling these endpoints and acting on their replies.

**Checking the real server:** use `GET /health` only. Never `POST` to the running server (default `~/.buddy/buddy.db`) to test or probe it. Every `POST` changes the user's real conversation: `/interrupt` trims the last reply and records an interruption, and `/message` adds a turn. For end-to-end tests, run a separate server with its own `BUDDY_DB` and `PORT`.

### Server responsibilities

- **LLM access.**
  - The server is Dart all the way down. There's no mature Dart library for the ChatGPT subscription, so it calls the Codex backend endpoint directly with `dart:io` `HttpClient`, in Responses API format.
  - **Login:** the user runs `codex login` once on the Mac. The server reads the token from `~/.codex/auth.json`, refreshes it when it expires, and writes the refreshed token back to the same file.
  - **Use the open-source Codex CLI (`openai/codex`) as the reference** for anything not listed below. Don't guess.
  - **Verified in a spike (2026-09-29):**
    - Request: `POST https://chatgpt.com/backend-api/codex/responses`.
    - Headers:
      - `Authorization: Bearer <tokens.access_token>`
      - `ChatGPT-Account-ID: <tokens.account_id>`
      - `Accept: text/event-stream`
    - Body: `model`, `instructions`, `input`, `tools`, `tool_choice: "auto"`, `parallel_tool_calls: false`, `store: false`, `stream: true`, `include: []`.
    - The endpoint keeps no state (`store: false`), so the full history goes in `input` on every call.
    - Read the SSE stream and collect the items from the `response.output_item.done` events.
    - Custom function tools work: `set_alarm` was called with correct arguments, and a `function_call_output` gave a spoken confirmation.
  - **Token refresh** (from `codex-rs/login/src/auth/manager.rs`):
    - Request: `POST https://auth.openai.com/oauth/token`.
    - JSON body: `{client_id, grant_type: "refresh_token", refresh_token}`. `client_id` is the Codex CLI's public client ID, `CLIENT_ID` in that file.
    - Persist the returned tokens back to `auth.json`.
  - The token never leaves the Mac.
  - This route covers text models only. The Realtime (voice) API doesn't accept ChatGPT subscription tokens, so STT and TTS stay on the phone.
- **Conversation history.**
  - A single ongoing conversation, persisted on the Mac so it survives app and server restarts.
  - **Stored in SQLite** (`sqlite3` package; default `~/.buddy/buddy.db`). It's the canonical history: the model is sent exactly what's in it.
    - The `conversation` table has one row, holding the system prompt and start time.
    - The `items` table has one row per Responses API item (message, function call, tool result), stored as JSON with a timestamp.
  - Rows are only appended, except when an interrupt trims the last reply. That update or delete happens in a transaction.
- **System prompt:** sent as the request's `instructions` field. It's written once at the start of the conversation and never rewritten. It contains:
  - the current local date and time, UTC offset and IANA timezone,
  - an instruction to keep replies short and conversational, because they're spoken aloud,
  - instructions for using `set_alarm`, including asking when the purpose or time is unclear.
- **Time updates:** when a `/message` request arrives **5 minutes or more** after the last message, append a message with the current local date and time, UTC offset and IANA timezone (from the request), just before the user message. Never edit earlier messages.
  - Use role **`developer`**. The endpoint rejects `system` messages in `input` with `400 System messages are not allowed`.
  - In the spike, the model used a `developer` time update correctly to answer "how long until my alarm?"
- **Alarm tool.**
  - The LLM gets one tool, `set_alarm(time, label)`:
    - `time`: an ISO 8601 datetime with a UTC offset, resolved from what the user said ("7am tomorrow", "in 20 minutes").
    - `label`: what the alarm is for, taken from the user.
  - If the purpose or the time is missing or ambiguous, the AI asks before calling the tool.
  - When the LLM calls the tool, the server:
    1. converts the time to UTC,
    2. records a tool result saying the alarm was sent to the phone,
    3. lets the LLM produce its spoken confirmation,
    4. returns the alarm in the reply's `alarms`, together with the confirmation in `text`.
  - If the app later calls `/alarm-failed`, the server adds it to the history and has the LLM tell the user.
- **Interrupts:** the model should only see what the user actually heard.
  - On `/interrupt`:
    1. Cancel any in-flight turn. Its pending request gets `204`.
    2. Trim the last turn's assistant text to `heard`, dropping everything after it. Keep tool calls, because their alarms were still scheduled.
    3. Append a `developer` message saying the user interrupted.

    The result is the canonical history, and the next `/message` continues from it.
  - Any new request also cancels a turn that's still in flight.

### Network: Tailscale, not ngrok

- **Use Tailscale.**
  - The phone reaches the buddy server over a private tailnet. The server isn't on the public internet, so it needs no auth of its own.
- **Not ngrok,** because it would publish a public URL to an endpoint that spends the user's subscription.
- **Trade-offs:**
  - Android allows one active VPN at a time, so Tailscale must be the one that's on.
  - The Mac must be awake and running the server. If it isn't, chat fails but **alarms still ring**, because they're scheduled locally on the phone.

### App (Flutter): voice loop and UI

```
listen → end of speech → POST /message ─▶ set alarms, speak text → TTS done
   ↑                                                                   │
   └───────────────────────────────────────────────────────────────────┘
```

- **Server URL:** a build-time constant, `--dart-define=BUDDY_SERVER=http://<mac-tailscale-ip>:8787/`.
- **STT:** use `speech_to_text`, which wraps Android `SpeechRecognizer`. The OS decides when the user stops talking, so no push-to-talk is needed.
- **TTS:** use `flutter_tts`, which uses Android's on-device TTS.
- **Subtitles:** show the reply's `text` while it's being spoken.
- **Interrupt button:** always visible while waiting on the server or speaking. Pressing it:
  1. stops TTS immediately,
  2. calls `POST /interrupt` with `heard`, the part of the reply that was spoken (`""` if the reply hadn't arrived yet),
  3. returns to listening.

  If a reply arrives after the button was pressed, still schedule its `alarms` (the server has recorded them as set), but don't speak its `text`.

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

  Moving STT and TTS to the server would add audio endpoints but leave the architecture unchanged.

## Open questions

- History will eventually outgrow the model's context window. Decide how to trim it (e.g. send only the most recent N messages), or whether to summarize old messages.
