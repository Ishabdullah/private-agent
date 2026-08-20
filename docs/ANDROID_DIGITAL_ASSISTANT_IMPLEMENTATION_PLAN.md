# PrivateAgent → Android Digital Assistant: Implementation Plan

Status: **Planning document only. No implementation has been performed.**
Audit performed against commit `ce84a47` (`origin/main`, HEAD at time of writing) of `Ishabdullah/private-agent`.

---

## 1. Executive Summary

PrivateAgent is currently a **Flutter/Kotlin Android chat app with a manual "hold-to-talk" microphone button and a working LLM-driven screen-automation agent**. It is not, in any respect, a wake-word-activated digital assistant. There is no wake-word detection code, no background/foreground listening service, no boot handling, no `VoiceInteractionService`, and no assistant-name concept anywhere in the codebase (Dart or Kotlin). The voice pipeline that exists is: user taps mic icon → `speech_to_text` transcribes once → transcript is sent as a chat message → LLM plain-text replies are spoken via `flutter_tts`. That's it.

What **does** already exist and is genuinely solid, and must be reused rather than rebuilt:
- A working, provider-agnostic LLM client (`AiService`) supporting DeepSeek/OpenRouter-style/Groq/NVIDIA NIM/Ollama/local OpenAI-compatible endpoints, with model discovery, tuning knobs, and persisted settings.
- A working multi-step on-device automation agent (`TaskExecutor` + `AgentAccessibilityService`) that reads the accessibility tree, drives an LLM action loop, and executes taps/typing/scrolling/swipes/app-launches, with recovery and skill-memory replay.
- A working single-shot action dispatcher (`ActionHandler`) for calls, SMS, alarms, volume/brightness, app launching, contacts.
- A working (if class-scattered) `MethodChannel`/`EventChannel` bridge between Dart and a native `AccessibilityService`, plus a background-Flutter-engine re-registration path (`BackgroundEngineReceiver`) that is *declared* but whose triggering mechanism does not yet exist in the app (nothing currently broadcasts `com.orailnoor.privateagent.REGISTER_BACKGROUND_CHANNELS`).
- A first-run onboarding flow (3 pages: Welcome → Permissions → AI Setup) and a Settings screen, both built with hand-rolled Material widgets, both **completely unaware of voice, wake words, or background services**.

Building the requested experience is therefore a genuine "add a new subsystem" project, not a "wire up an existing hidden feature" project. The good news is that the parts that are hard to get right in an LLM-driven Android agent — screen reading, action execution, provider abstraction, recovery — already work and need only be *called into* from a new voice layer, not rewritten.

The single biggest technical risk in the requirements is the assumption that **arbitrary user-chosen wake words can be detected efficiently, locally, and always-on**. This is not true in general for the free/open engines available to a normal (non-system, non-OEM) Android app. Section 8–9 works through this in detail and proposes a design that keeps "assistant name" (branding, TTS persona, arbitrary user string) and "wake-word detection model" (a constrained, enrollable, or vendor-restricted phrase) as two distinct concepts connected by a mapping layer — instead of pretending the user can type any string and get an efficient offline detector for it.

The second biggest risk is Android's restrictions on background microphone access and on "assistant app" privileges (Section 10). PrivateAgent can implement a **foreground-service-based wake-word listener** (fully supported, Android 8–16 compatible) but **cannot** obtain Google Assistant-level system integration (double-home-button, "Hey Google"-style screen-off activation, `ROLE_ASSISTANT` default-handler replacement of the system assistant UI) without becoming the user's chosen default assistant app via `VoiceInteractionService`, which is a large, separate, higher-risk engineering effort with real limitations (detailed in Section 10). The plan treats `VoiceInteractionService` as an optional, later-phase, best-effort enhancement — not a prerequisite for the core "Hey [Name]" experience, which can be delivered via a foreground service + notification while the app is anywhere in the recent-apps list (not force-stopped, not battery-restricted).

---

## 2. Current Architecture

PrivateAgent (`applicationId` / package `com.orailnoor.privateagent`) is a **Flutter app with a thin native Android layer**, not a native Android app with a Flutter view. There is no iOS target (`ios: false` in `flutter_launcher_icons`, no `ios/` directory). Two Flutter engines can run concurrently: the main UI engine, and a second minimal engine (`overlayMain()`) for a floating chat-bubble window — currently disabled behind `FeatureFlags.floatingOverlayEnabled = false`.

```
┌─────────────────────────────── Flutter (Dart) ───────────────────────────────┐
│  main.dart ── runs PrivateAgentApp (MaterialApp) ── HomeScreen / Onboarding   │
│                                                                                │
│  HomeScreen (chat UI, mic button, mode switch chat/agent)                     │
│    ├─ AiService          → HTTP client to OpenAI-compatible LLM endpoint      │
│    ├─ ActionHandler      → dispatches single-shot AgentActions                │
│    │     └─ TaskExecutor → multi-step screen-automation loop                  │
│    ├─ VoiceService       → speech_to_text (push-to-talk) + flutter_tts        │
│    ├─ ScreenAutomationService → MethodChannel bridge to AccessibilityService  │
│    ├─ ChatHistoryService, TaskHistoryLogger, SkillMemoryService (local disk)  │
│    ├─ TelegramService    → background-polling remote control                 │
│    └─ NotificationService → task-complete local notifications                │
└────────────────────────────────────────────────────────────────────────────┘
                                     │ MethodChannel "com.privateagent/accessibility"
                                     │ EventChannel  "com.privateagent/accessibility_events"
┌─────────────────────────────── Android (Kotlin) ──────────────────────────────┐
│  MainActivity.kt        → registers channels, forwards calls to the service   │
│  AgentAccessibilityService.kt → AccessibilityService: dumpScreen/click/type/  │
│                                  scroll/swipe/pressBack/pressHome/screenshot   │
│  BackgroundEngineReceiver (nested in MainActivity.kt) → re-registers the      │
│                                  MethodChannel on a cached Flutter engine      │
│                                  (declared in the manifest but nothing in     │
│                                  the app currently sends this broadcast)      │
└────────────────────────────────────────────────────────────────────────────┘
```

Everything is on-device except the LLM HTTP calls and the optional Telegram long-poll. There is no backend/server component to this project.

---

## 3. Repository Audit

Verified directly against source (paths relative to repo root, cloned from `https://github.com/Ishabdullah/private-agent`):

| Property | Value | Evidence |
|---|---|---|
| Project type | Flutter application (Android-only) | `pubspec.yaml`, `flutter_launcher_icons.ios: false`, no `ios/` dir |
| Flutter SDK constraint | `^3.10.3` (Dart) | `pubspec.yaml:7` |
| Flutter tool revision pinned in repo | `66dd93f9a27ffe2a9bfc8297506ce066ff51265f`, channel `stable` | `.metadata` |
| Application ID / package | `com.orailnoor.privateagent` | `android/app/build.gradle:11,20`, `AndroidManifest.xml` |
| minSdk | 26 (Android 8.0) | `android/app/build.gradle:24` |
| targetSdk / compileSdk | `flutter.targetSdkVersion` / `flutter.compileSdkVersion` (resolved by the Flutter tool at build time — not hardcoded in this repo) | `android/app/build.gradle:9,25` |
| Kotlin/AGP | Kotlin plugin `2.2.20`, AGP `8.11.1` | `android/settings.gradle` |
| Java target | 17, core library desugaring on | `android/app/build.gradle:14-19` |
| Native Android language | Kotlin only (`AgentAccessibilityService.kt`, `MainActivity.kt`, and a stray `Test.kt` scratch file with an unused `test()` function) | `android/app/src/main/kotlin/com/orailnoor/privateagent/` |
| Signing | Release build type explicitly signs with the **debug** keystore ("TODO: Add your own signing config") | `android/app/build.gradle:33-38` |
| Dart module count | 25 files under `lib/` (screens, services, models, widgets, one config) | directory listing |
| Local/vendored Flutter plugins | `local_plugins/flutter_overlay_window` (overridden via `dependency_overrides`, actively used, feature-flagged off) and `local_plugins/agent_native` (present, has its own `pubspec.yaml`, **not referenced anywhere in `lib/` or the app's `pubspec.yaml` dependencies** — dead scaffold) | `pubspec.yaml:49-51`, grep of `lib/` |
| CI | GitHub Actions `android-release.yml`: `flutter pub get` → `flutter test` → `flutter build apk --release` (universal) → `flutter build apk --release --split-per-abi` → sha256sums, on tag push `v*` or manual dispatch | `.github/workflows/android-release.yml` |
| Test suite | One Dart unit test file (`test/ai_service_test.dart`, 3 tests, all about the NVIDIA-model helper functions); **no widget tests, no Android instrumentation tests (`androidTest/`), no integration tests** at the app level (the vendored `local_plugins/agent_native` has its own plugin-level tests, irrelevant to the app) | file listing |
| Entry points | `main()` (main UI engine) and `overlayMain()` (secondary overlay engine, `@pragma("vm:entry-point")`, disabled by feature flag) | `lib/main.dart` |

---

## 4. Existing Capabilities — Classification With Evidence

Legend: ✅ EXISTS AND WORKS · 🟡 EXISTS BUT INCOMPLETE · 🟠 EXISTS BUT NEEDS MODIFICATION · 🔶 PARTIALLY IMPLEMENTED · ❌ DOES NOT EXIST · ❓ UNKNOWN (needs on-device testing)

| Capability | Status | Evidence |
|---|---|---|
| Android native code | ✅ | `MainActivity.kt`, `AgentAccessibilityService.kt` — functional, exercised in production per README |
| Flutter/Dart app | ✅ | Full app under `lib/`, builds via CI |
| AndroidManifest configuration | 🟠 | Present and mostly correct for current features, but **missing** every permission/service the new experience needs (see Section 4a below) |
| Android services | 🟠 | Only an `AccessibilityService` exists. No `Service`/`ForegroundService` class exists at all in Kotlin. |
| Foreground services | ❌ | No `startForeground()`, no `<service>` with `foregroundServiceType`, no `FOREGROUND_SERVICE_MICROPHONE` permission anywhere in the repo (grep confirmed) |
| Accessibility services | ✅ | `AgentAccessibilityService.kt` (515 lines): screen dump, click by text/coordinates, type text, scroll, swipe, press back/home/notifications, screenshot (API 30+), current-package detection. Actively used by `TaskExecutor`. |
| Accessibility permissions | ✅ | `BIND_ACCESSIBILITY_SERVICE` declared correctly, config XML present (`accessibility_service_config.xml`), onboarding explains the "Restricted setting" Android quirk |
| Microphone/audio handling | 🟡 | `RECORD_AUDIO` permission declared; `speech_to_text` package used for one-shot, foreground, user-initiated recognition only. No continuous/background audio capture pipeline exists. |
| Speech recognition (STT) | 🟡 | `VoiceService.startListening()` wraps `speech_to_text` v7 with `ListenMode.confirmation`, `partialResults: false` — single utterance, foreground-UI-only, uses Android's on-device/cloud `RecognitionService` (device-dependent which). Not usable as-is for continuous conversation or background wake-triggered capture. |
| Text-to-speech (TTS) | ✅ (for what it does) | `VoiceService` wraps `flutter_tts` — language, rate, volume, pitch configured; called once, only for plain-text (non-action) chat responses (`home_screen.dart:210`). Never speaks task/action results, never speaks in agent mode. No voice/rate/pitch controls exposed in Settings. |
| Wake-word detection | ❌ | No wake-word library, no `porcupine`/`vosk`/similar dependency anywhere in `pubspec.yaml` or `pubspec.lock` (grep confirmed). No concept of "wake word" or "assistant name" in any Dart or Kotlin source file. |
| Background execution | ❌ | No foreground service, no `WorkManager`/`workmanager` dependency, no persistent background process. `TelegramService` polls only while the app process is alive (see 4b). App is a normal Activity-scoped Flutter app with no mechanism to keep running once backgrounded long enough for Android to freeze/kill the process. |
| Notification handling | 🟡 | `flutter_local_notifications` wired for one-shot "task complete" notifications only. No persistent/foreground-service notification channel, no ongoing "listening" indicator. |
| Boot/startup handling | ❌ | No `RECEIVE_BOOT_COMPLETED` permission, no `BOOT_COMPLETED` broadcast receiver anywhere (grep confirmed both) |
| Android assistant integration (`ROLE_ASSISTANT`/`VoiceInteractionService`) | ❌ | No `VoiceInteractionService`/`VoiceInteractionSessionService` classes, no `<meta-data name="android.voice_interaction">`, no role-request code (`RoleManager`) anywhere |
| Voice conversation state (multi-turn without repeating wake word) | ❌ | No state machine of any kind for voice; `_isListening` in `HomeScreenState` is a simple boolean UI flag, reset per single utterance |
| Conversation memory | 🔶 | In-memory rolling window of last 20 messages inside `AiService._conversationHistory` (`ai_service.dart:60,199-208`), cleared on process restart; **separately**, `ChatHistoryService` persists full chat sessions to disk for the chat UI's history list — these two are not the same store and are not unified with any voice/task memory |
| LLM provider abstraction | ✅ | `AiService` talks to any OpenAI-compatible `/chat/completions` + `/models` endpoint; base URL, model, API key, temperature, max tokens, max steps all configurable and persisted |
| OpenRouter integration | 🟠 | Not named explicitly as a preset chip (Settings/Onboarding presets are DeepSeek, Groq, NVIDIA NIM, Ollama, Local, Custom — no OpenRouter preset), but since OpenRouter exposes an OpenAI-compatible endpoint, it already works today via the generic "Custom" provider by entering `https://openrouter.ai/api/v1` manually. README explicitly documents this as the "free" path. |
| Local model support | ✅ | "Ollama" and "Local Server" presets pre-fill `http://10.0.2.2:11434/v1` / `http://10.0.2.2:1234/v1` (emulator loopback) and skip the API-key requirement | `onboarding_screen.dart:169-178`, `ai_service.dart` |
| Agent/tool execution | ✅ | `ActionHandler` (single-shot) + `TaskExecutor` (multi-step, LLM-driven, with recovery/skill-memory) — this is the core reusable asset |
| Browser/web interaction | 🔶 | No dedicated "web browsing" tool/API; the agent's *implicit* strategy is "open Chrome and use `execute_task` like any other app" (explicitly documented in `TaskExecutor._taskSystemPrompt`: "immediately open Chrome or Google to search... instead"). There is no headless fetch/search tool — everything goes through the accessibility-driven UI loop. |
| Android app launching | ✅ | `AppLauncherService` + `installed_apps`/`android_intent_plus`; also has a hardcoded shortcut table for common apps (`TaskExecutor._getNavigationShortcut`) |
| Screen reading | ✅ | `AgentAccessibilityService.dumpScreen()` / `traverseNode()` — filters own package, computes bounds, returns clickable/editable/scrollable metadata |
| UI interaction (tap/type/scroll/swipe) | ✅ | Fully implemented natively via `AccessibilityNodeInfo` actions and `dispatchGesture` |
| Permission onboarding | 🟠 | Exists for accessibility/microphone/overlay/notifications/contacts/phone/SMS with clear explanations, but has **no concept of a voice/wake-word permission flow, no battery-optimization step, no assistant-role step** |
| First-run setup | 🟠 | 3-step onboarding (Welcome/Permissions/AI Setup) exists and works, ends by validating the LLM connection and flipping `onboarding_completed` in `SharedPreferences`; has **no wake-word step at all** |
| Persistent settings | ✅ | `SharedPreferences` used throughout (`AiService`, `TelegramService`, theme, onboarding flag) — reliable pattern to extend |
| Secure storage | ❌ | API keys, Telegram bot tokens, etc. are stored in **plain `SharedPreferences`**, not `flutter_secure_storage`/Android Keystore-backed storage. No `flutter_secure_storage` dependency in `pubspec.yaml` (grep confirmed). This is a real, current gap, not just a future one. |
| API key management | 🟡 | Functional UI (obscured field, "Bearer " prefix stripping, validation ping) but stored insecurely (see above) |
| Model configuration | ✅ | Model discovery (`fetchAvailableModels`), curated NVIDIA free-model allowlist, per-provider presets |
| Error handling | 🟠 | Reasonably thorough *within* the task-execution loop (timeouts, retry-once JSON parsing, consecutive-failure detection, recovery engine) but voice/network/mic error handling is minimal (`VoiceService.init` swallows STT init errors into a boolean; no user-facing distinction between "no mic permission," "no recognizer installed," and "network STT failed") |
| Logging | 🟡 | `dart:developer log()` calls throughout (name: `'PrivateAgent'`) plus a native-log bridge (`ScreenAutomationService.logToNative`) used for hard-to-debug accessibility-channel timing issues; no structured logging, no log persistence/export, no crash reporting |
| Testing | 🟠 | One Dart unit-test file, 3 assertions, unrelated to voice/agent/automation logic; **zero** coverage of `TaskExecutor`, `AiService`'s core send/stream logic, `ActionHandler`, or any Kotlin code |
| Build configuration | ✅ | Modern AGP/Kotlin, Gradle Kotlin DSL, desugaring enabled, `minSdk 26`; release signing currently falls back to the debug keystore (must be fixed before any real release, see Section 20) |
| APK generation | ✅ (proven in CI) | CI produces both a universal APK and per-ABI split APKs (arm64-v8a, armeabi-v7a, x86_64) with checksums |

### 4a. Manifest permissions currently declared (main manifest)

`INTERNET`, `RECORD_AUDIO`, `READ_CONTACTS`, `CALL_PHONE`, `SEND_SMS`, `READ_PHONE_STATE`, `SET_ALARM`, `MODIFY_AUDIO_SETTINGS`, `WRITE_SETTINGS`, `POST_NOTIFICATIONS`, `QUERY_ALL_PACKAGES`, `FOREGROUND_SERVICE`; `SYSTEM_ALERT_WINDOW` is explicitly **removed** via `tools:node="remove"` (i.e., the floating-overlay plugin's manifest merge is intentionally suppressed while that feature is disabled). `queries` block already anticipates STT/TTS discovery (`RecognitionService`, `TTS_SERVICE` intents) plus `tel:`/`sms:`/`mailto:` view intents.

Notably **absent**, all of which the new experience needs: `FOREGROUND_SERVICE_MICROPHONE` (required on API 34+ for a foreground service that uses the mic), `RECEIVE_BOOT_COMPLETED`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (to guide the user, not to silently exempt), `BIND_VOICE_INTERACTION` (only needed if/when `VoiceInteractionService` is attempted), and `WAKE_LOCK` (only if the foreground listening service needs to keep the CPU awake during active listening — should be scoped narrowly, not held continuously).

### 4b. `TelegramService` background-polling caveat

`TelegramService`'s "background polling" is **only alive while the Dart VM / app process is alive** — it is a `Timer`/HTTP long-poll inside the Flutter engine, not a `WorkManager` job or a foreground service. Once Android freezes or kills the app process (which it will, per standard OS background limits, once the Activity is not visible and no foreground service is protecting the process), Telegram polling and any voice pipeline built the same way will also stop. This matters directly for wake-word design: **a wake-word listener built the same way `TelegramService` is built today will not survive backgrounding** — it needs an actual foreground service, which does not currently exist in this codebase in any form.

---

## 5. Missing Capabilities (Summary)

Everything required for the "Hey [Name]" experience that is not covered as ✅ above:

1. Wake-word engine integration (native, always-listening, low-power).
2. Foreground service (Kotlin `Service` + `startForeground` + persistent notification + `FOREGROUND_SERVICE_MICROPHONE` type) to host the wake-word listener and the voice pipeline while backgrounded.
3. Boot-completed receiver to optionally restart the listening service after reboot (opt-in, not silent).
4. A voice conversation state machine (idle → wake-detected → listening → transcribing → thinking → speaking → idle-or-continuing) that bridges into the existing `AiService`/`ActionHandler`/`TaskExecutor` stack.
5. Onboarding steps for: assistant-name/wake-word selection, wake-word enrollment/validation, battery-optimization guidance, background-service explanation, voice test, wake-word test.
6. Settings additions: assistant name, wake phrase, enable/disable wake word, TTS voice/rate, continuous-conversation toggle, background-listening toggle, "listen while screen is off" toggle (with its real limitations disclosed).
7. Secure storage migration for API keys/tokens (independently worth fixing; becomes more urgent once voice transcripts and always-on audio are in play).
8. TTS wiring for **all** assistant outputs (task results, action confirmations, errors) — today TTS only speaks plain chat replies, never action/task outcomes.
9. Optional, later-phase: `VoiceInteractionService`/`ROLE_ASSISTANT` integration for OS-level assistant hooks (long-press home / assistant gesture), with explicit acknowledgment of what this can and cannot achieve on Samsung/OneUI devices.
10. Unit/integration/E2E test coverage for all of the above (currently near-zero for anything beyond two static helper functions).

---

## 6. Architecture Gap Analysis

| Existing component | Gap relative to goal | Resolution approach |
|---|---|---|
| `AgentAccessibilityService` (Kotlin) | Runs fine when the Activity/app is alive but has no lifecycle tie to a foreground service; if the process is killed, `AgentAccessibilityService.instance` still exists (accessibility services are OS-managed and can outlive the Activity) but the **Flutter engine and MethodChannel are gone**, and `BackgroundEngineReceiver` exists to re-attach a *cached* engine — except nothing currently creates/caches that engine or sends the broadcast. | The new foreground service becomes the thing that keeps a cached Flutter engine (or a pure-Kotlin voice pipeline, see Section 7 tradeoffs) alive, and is responsible for firing `REGISTER_BACKGROUND_CHANNELS` (or superseding that mechanism with a cleaner single foreground-service-owned engine). |
| `VoiceService` (Dart) | One-shot, UI-triggered, no wake integration, no continuous mode, `ListenMode.confirmation` is tuned for "user taps, speaks once, done" — wrong mode for a live conversation | Needs a rewrite/extension into a proper voice-pipeline controller (still can wrap `speech_to_text` for the STT stage, but state machine and lifecycle must move to survive backgrounding) |
| `AiService` | Fully synchronous/streamed per typed message; no notion of "this turn originated from voice, so keep responses TTS-friendly (short, no markdown tables) and speak the result" | Add a `source: voice` flag or a separate voice-oriented prompt wrapper; do **not** fork the LLM client — reuse `sendMessage`/`sendMessageStream`, just post-process output for TTS and mark it in history |
| `ActionHandler` / `TaskExecutor` | Fully synchronous relative to a chat turn; already reports intermediate progress via `onProgress` callback | Voice layer subscribes to the same `onProgress` stream for spoken progress narration ("Opening Chrome…", "Done") instead of building a parallel progress system |
| Onboarding / Settings screens | No wake-word/voice-persona UI at all | Add pages/cards, not a rewrite — the existing `PageView`/`_buildSettingsCard` patterns extend cleanly |
| `SharedPreferences` usage | Works, but wrong medium for secrets and increasingly wrong medium as more sensitive voice-adjacent settings are added (e.g., "keep transcripts") | Introduce `flutter_secure_storage` for secrets only; keep `SharedPreferences` for non-sensitive settings (wake word text, toggles) — don't over-migrate |
| Notification system | One-shot only | Add a second, **ongoing** notification channel/category for the "PrivateAgent is listening" foreground-service notification, separate from the existing "Task Completions" channel |
| `local_plugins/agent_native` | Present, unused, unclear purpose (its own README/CHANGELOG exist but nothing in the app imports it) | Audit its actual native code before deciding whether to build the wake-word bridge as a new method channel inside `MainActivity`, as a new dedicated plugin, or by finally wiring up `agent_native` if its scaffold happens to fit (must be inspected in Phase 0 of implementation, not assumed) |

---

## 7. Proposed Voice Assistant Architecture

```
                     ┌─────────────────────────────────────────────┐
                     │     VoiceAssistantForegroundService (Kotlin) │
                     │  - startForeground() w/ ongoing notification │
                     │  - owns a cached FlutterEngine (background)  │
                     │  - hosts the wake-word engine (native SDK)   │
                     │  - on wake: starts capture, calls into Dart  │
                     │    via a MethodChannel/EventChannel          │
                     └───────────────┬───────────────────────────────┘
                                      │ EventChannel: wake events, partial state
                                      │ MethodChannel: start/stop listening,
                                      │                enroll/change wake word
┌─────────────────────────────────────▼─────────────────────────────────────┐
│                    VoiceConversationController (Dart, new)                 │
│   State machine: Idle → Woken → Listening → Transcribing → Thinking →      │
│                   Speaking → (ContinuingConversation | Idle)               │
│   - talks to VoiceService (STT/TTS) for the capture/speak stages           │
│   - talks to AiService.sendMessageStream(...) for the "Thinking" stage     │
│   - talks to ActionHandler for action/task execution + progress narration  │
│   - persists short "current voice session" transcript via ChatHistoryService│
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key design decision: the voice layer is a *controller/orchestrator*, not a second agent.** It never talks to the LLM, Accessibility service, or app-launcher directly — it always goes through `AiService`/`ActionHandler`/`TaskExecutor`, exactly as the chat UI does today. This satisfies the "reuse, don't rewrite" requirement and means any future improvement to the agent loop (new tools, better recovery, etc.) automatically benefits both text chat and voice.

**Key design decision: wake-word detection must run natively (Kotlin), not in Dart.** Continuous audio-frame processing at low latency/low battery cost is not something a Flutter/Dart isolate should own — every viable wake-word SDK for Android ships a native (JVM/NDK) integration. The Flutter engine only needs to be *woken up* by a native event, not run the hot loop itself. If a headless/background Flutter engine turns out to be too heavy or fragile to keep resident (see risk notes in Section 22), the fallback is to keep the whole wake→capture→STT request pipeline in Kotlin and only invoke Dart (via a cached background engine or a plain HTTP call from Kotlin to the same `AiService` logic reimplemented natively) for the "Thinking" stage.

**Update (Phase 5, 2026-08-16): this is no longer just a design preference, it's forced.** The wake-word engine is now sherpa-onnx (Section 8.3.2), consumed as a native Kotlin/JNI AAR with no Flutter plugin wrapper at all — there is nothing to call from Dart even if we wanted to. `VoiceAssistantForegroundService.kt` owns the entire audio hot loop and keyword match; Dart is only reached on wake-word detection, at which point the existing `VoiceConversationController` takes over exactly as it does for a manual mic-button tap. The remaining open question — whether reaching Dart on detection requires a resident cached background `FlutterEngine` (needed if the screen is off/app fully backgrounded) or can simply start `MainActivity` (sufficient if the screen is on) — is still unresolved and cannot be verified from Colab; it is scoped as an explicit Phase 16 real-device validation item, not guessed at here. Phase 5 builds the simple (start-Activity) path first.

**Update (Phase 5b, 2026-08-16): the simple path is implemented.** `VoiceAssistantForegroundService.onWakeWordDetected()` pauses the KWS audio loop (to avoid two simultaneous `AudioRecord` consumers) and calls `startActivity` on `MainActivity` with an `ACTION_WAKE_DETECTED` intent + the detected assistant name as an extra. `MainActivity.onCreate`/`onNewIntent` picks this up and calls `voiceAssistantChannel.invokeMethod("onWakeWordDetected", ...)` into Dart, where `home_screen.dart`'s `_onWakeWordDetected` calls `VoiceConversationController.startTurn()` — the exact same path the mic button uses. Once that turn returns to `idle`, `home_screen.dart` calls `VoiceAssistantForegroundService.resumeListening()` to restart the KWS loop. The screen-off/fully-backgrounded case (needing a resident cached `FlutterEngine` instead) remains unimplemented and is still the Phase 16 device-validation item described above — not guessed at, per the same reasoning.

---

## 8. Wake-Word Architecture

### 8.1 Terminology (must be kept distinct throughout the project)

- **Assistant name**: an arbitrary user-facing string (e.g., "Aigentik", "Nova", "Private") used in UI copy, TTS persona ("Hi, I'm Nova"), and notification text. Free-form, no technical constraint.
- **Wake phrase**: the literal phrase the user says to activate the assistant, typically `"Hey " + assistantName` or `"OK " + assistantName`. Presented to the user as configurable text.
- **Wake-word detection model**: the actual acoustic model/algorithm that decides "did the last ~1s of audio contain the wake phrase." This is the part with hard technical constraints, detailed next.

### 8.2 Reality check on arbitrary user-defined wake words

No commodity, redistributable, offline wake-word engine lets an app **generate a new, efficient acoustic detection model from a single typed string, on-device, at first-run, for free, in real time.** The realistic options, evaluated:

| Approach | Can it do "type any word, works instantly, offline, free"? | Notes |
|---|---|---|
| **Porcupine (Picovoice)** | No | Best-in-class offline wake-word engine, tiny CPU/battery footprint, Android SDK available, Flutter plugin exists (`porcupine_flutter`). Ships a **fixed catalogue of built-in keywords** (e.g., "Hey Siri"-style demo words, not full flexibility) for free; **custom wake words require generating a `.ppn` model per phrase via Picovoice Console**, which needs network access, a Picovoice account, and (for anything beyond eval/free-tier limits) a paid plan. Models can be generated ahead-of-time server-side and bundled, or generated on demand via their console API — either way it is **not instant, on-device, zero-account generation**. |
| **openWakeWord / other TFLite-based open models** | No | Open-source, MIT-licensed, on-device, but pretrained models exist only for the phrases their authors trained (e.g., "hey jarvis", "alexa"). Training a new keyword model requires a training pipeline (synthetic TTS-based data generation + fine-tuning) that is realistically a **cloud/offline batch job**, not something that runs on a phone at onboarding time. |
| **Vosk / on-device generic ASR used as a "wake word" via keyword-spotting on a short rolling buffer** | Partially | Vosk (or Android's own `SpeechRecognizer` with a hotword grammar where supported) can do generic continuous transcription and then string-match "did the transcript contain my phrase" — this *does* support arbitrary phrases entered as plain text with zero model generation. The cost is **much higher CPU/battery draw** than a purpose-built wake-word detector, because it's running a general speech-to-text model continuously instead of a tiny binary classifier. Not appropriate for true always-on listening on battery, but *is* viable as an on-demand fallback. |
| **Cloud wake-word / continuous cloud STT** | Yes, technically | Stream audio continuously to a cloud STT service and pattern-match the transcript. Defeats the "local processing, privacy, low battery" goals explicitly stated in the requirements, incurs continuous network/battery cost, and raises "audio leaves the device constantly" privacy concerns the requirements explicitly want minimized. Rejected as the default; could be offered as an explicit opt-in "cloud wake word" mode with clear disclosure. |
| **Android `SpeechRecognizer` with `EXTRA_PARTIAL_RESULTS` hotword-style polling** | No | Android has no public, cross-OEM "hotword" API for third-party apps. (Google's own "Hey Google" hotword is a system-level, privileged capability not exposed to third-party apps.) |

**Conclusion:** true "type literally any word and get an efficient always-on offline detector" is not achievable with any free, redistributable, on-device engine today. The original recommendation below (tiered Porcupine + Vosk fallback) was the honest default absent real device data. **Section 8.3.1 documents what was actually decided and why — read that first; the tiered design below is kept for historical context but is superseded.**

### 8.3 Original recommended design: a curated list + a "generate my own" path (superseded — see 8.3.1)

**Tier 1 — Curated wake words (default, zero setup, true always-on, lowest battery cost).**
Ship the app with a small set of **pre-built wake-word models** (e.g., "Hey Nova," "Hey Aigentik," "Hey Private," plus 2-3 more), each a small `.ppn`/`.tflite` file bundled in `assets/`. At onboarding, the user picks one of these from a list — this is presented as "choose your assistant's name," and the choice **is** the wake phrase, because the model was already trained/generated for that exact phrase offline before the app was published (using Picovoice Console once, at development time, or an open training pipeline — a one-time developer-side cost, not a runtime cost). This tier requires **no network at onboarding**, no account, no per-user model generation, and gives the true "Hey [Name]" always-on experience the requirements describe. This is the tier that should be the default path in the UI flow described in Section 6.

**Tier 2 — Custom phrase, generated on demand (opt-in, requires network + a wake-word vendor account/API at build- or run-time).**
If the user types a name not in the curated list, the app can:
- (a) Call the Picovoice Console API to generate a custom `.ppn` model for that phrase (requires the developer to hold a Picovoice account/API key server-side or ask the user to supply their own free Picovoice AccessKey — Picovoice's free tier supports a generous number of always-on devices for personal/hobby use, which fits this project's profile), then download and cache the model on-device; from then on detection is local and free-recurring the same as Tier 1. This needs network **once**, at enrollment time, not continuously.
- (b) Fall back to Vosk-based keyword spotting over a rolling audio buffer for the exact typed phrase — works fully offline, no account, but at meaningfully higher battery/CPU cost, and should be clearly labeled in the UI as "Custom phrase (higher battery use)."

**Tier 3 — Enrollment-based (not recommended for v1, documented for completeness).**
Some engines support "record yourself saying the phrase 3 times, we build a personalized template" (speaker-dependent keyword spotting). This avoids needing a cloud model-generation step but has worse accuracy/robustness than a professionally trained model and adds onboarding friction (multiple recordings, environment-sensitive). Not recommended as the primary path; could be a future power-user option.

**What this means concretely for the onboarding flow (Section 11):** the wording must never promise "type literally anything and it will work exactly like Hey Google." It should say: *"Pick a name for your assistant. Choose from our ready-to-go wake words for instant, fully offline detection — or type your own and we'll generate a custom detector for it (requires a one-time internet connection; slightly higher battery use for custom names)."*

### 8.3.1 Decision actually made in Phase 3 (2026-08-16): Vosk-only, no Porcupine, no spike

Phase 3's plan (Section 24) called for empirically prototyping Porcupine vs. Vosk on real hardware before choosing. In practice, Porcupine requires a free Picovoice Console account + AccessKey even to use its built-in free keywords — the user was asked whether to obtain one, and **explicitly chose to skip the spike/comparison entirely and commit to Vosk-based keyword spotting as the sole, final wake-word engine**, accepting its higher CPU/battery cost as a known, deliberate tradeoff rather than something to be measured and possibly avoided.

**This is a product decision, not an implementation-discovered fact** — recorded here per this document's own instruction to update itself (not just the progress log) when a decision resolves something Section 8 left open.

**Consequences that ripple through the rest of this document:**
- **The Tier 1/Tier 2/Tier 3 split above no longer applies.** Vosk does keyword spotting over generic transcription, so it accepts *any* typed phrase with zero per-phrase model generation, zero account, zero network at enrollment — there is no "curated = instant/cheap" vs. "custom = needs setup/costs more" distinction anymore, because every wake word now goes through the same engine with the same cost profile. The curated name list (Section 9's tiles) can still exist as **suggested presets for UX convenience** (nice defaults to tap instead of typing), but it carries no technical meaning — picking a preset vs. typing a custom name behaves identically under the hood.
- **`WakeWordConfig.tier`** (Section 8.4) collapses to always being `customKeywordSpotting` in practice; `engine` is always `vosk` (or `none` before setup). The `curated`/`customGenerated` enum values are kept in the model for forward-compatibility (a future session could reintroduce Porcupine as an option without a data-model migration) but are currently unused by any code path.
- **No `.ppn` model files, no bundled per-phrase assets, no Picovoice Console integration, no AccessKey handling anywhere in this project.**
- **Onboarding copy (Section 9/11) must not claim "instant, fully offline detection" as a differentiator of curated names** — instead it should set uniform expectations: "Pick a name for your assistant — type anything you like. Wake-word detection runs fully offline, but uses more battery than a dedicated wake-word chip/engine would; you can always fall back to the mic button."
- **Section 17 (Performance/Battery)'s "default to Tier 1 curated wake words for the vast majority of users" recommendation no longer applies** — there is only one tier now, and its battery cost (previously described as "meaningfully higher... than a binary classifier") is what every user gets. Real on-device battery/CPU measurement (Section 17's existing recommendation to measure rather than trust marketing) becomes even more important precisely *because* there was no comparative spike — this should be prioritized early in Phase 5/13, not deferred.
- **Section 22 risk register should add**: shipping only the heavier engine means there is no cheap fallback if Vosk's always-on battery cost proves unacceptable in real-world testing; the mitigation is the existing "background listening is an explicit, reversible, opt-out toggle" design (Section 17), not a second engine.

### 8.3.2 Decision actually made in Phase 5 (2026-08-16): Vosk abandoned, sherpa-onnx open-vocabulary KWS is the engine

While starting Phase 5 (native background service), the Vosk-only decision from 8.3.1 was found to rest on a dead ecosystem: `com.alphacephei:vosk-android` has not published a release since March 2023, and — more importantly — the `vosk_flutter` plugin caps its SDK constraint at Dart `<3.0.0`, so it cannot even be added to this project's `pubspec.yaml` (this project is on Dart 3.13). That path is not merely stale, it is closed. The user was asked whether to proceed with Vosk anyway (the underlying AAR, as a precompiled JNI binary, likely still runs) or pause and look for a better-maintained alternative, and **chose to pause and research alternatives** rather than build on a dead dependency.

Research turned up **[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)** (k2-fsa, Apache 2.0, actively maintained, large multi-platform project covering Android/iOS/embedded/desktop). It supports **open-vocabulary keyword spotting** — a KWS model that accepts *any* typed keyword/phrase at runtime without per-phrase training, which is exactly what this project's already-shipped onboarding flow needs: `onboarding_screen.dart`'s `_buildAssistantIdentityPage` lets the user type an arbitrary assistant name and immediately tap "Test it" (`_saveWakeWordChoice` → `_runWakeWordTest`). This rules out openWakeWord as an alternative too — its models are trained per wake phrase (a cloud/offline batch job), which cannot satisfy "type a name, test it immediately, fully offline" the way open-vocabulary KWS can.

**Decision: sherpa-onnx replaces Vosk as the wake-word engine, effective Phase 5.** Consequences:
- **8.3.1's "Vosk-only" conclusion is superseded.** Everything 8.3.1 said about there being a single engine/tier with uniform cost still holds structurally — swap "Vosk" for "sherpa-onnx" throughout. The `WakeWordEngine` enum (Section 8.4) needs a `sherpaOnnx` value; `vosk` can be kept unused for now or removed once no code references it.
- **Integration is native Kotlin only, no Flutter plugin.** sherpa-onnx ships as a Kotlin/JNI AAR (`com.k2fsa.sherpa.onnx:sherpa-onnx` via JitPack is the official coordinate; `com.bihe0832.android:lib-sherpa-onnx` on Maven Central is a third-party republish, usable as a fallback if JitPack fails to resolve from the Colab build). There is no Dart-side plugin dependency at all, which sidesteps the exact "plugin's Dart SDK constraint is stale" failure mode that killed `vosk_flutter` — reinforcing (not just permitting) the Section 7 architecture where the wake-word hot loop lives entirely in `VoiceAssistantForegroundService.kt` and Dart is only invoked on detection.
- **Before writing any audio-loop code**, Phase 5 must first prove the AAR dependency actually resolves inside the existing Colab build pipeline (trivial `dependencies {}` addition + `flutter build apk --debug`) — a failed dependency resolution kills the whole approach regardless of code quality, per the operational lesson already logged in Section 21/the progress log about verifying build-affecting changes early.
- **Model assets**: open-vocabulary KWS needs bundled encoder/decoder/joiner ONNX model files + a tokens file (not a keywords file per phrase — keywords are supplied as plain text at runtime). Asset bundle size lands in the APK and should be reported at the next build handoff, since users are installing these builds over mobile data.
- **Section 22 risk register**: replace the "no cheap fallback if Vosk's battery cost proves unacceptable" entry with the same concern under sherpa-onnx's name; the mitigation (background listening as an explicit, reversible, opt-out toggle) is unchanged.

**Correction (Phase 5b, 2026-08-16): "open-vocabulary" does not mean "type any word at runtime."** The paragraph above was wrong on this point and is corrected here rather than silently edited, per this doc's own "don't leave stale reasoning" rule. Reading sherpa-onnx's C++ source directly (`sherpa-onnx/csrc/utils.cc`'s `EncodeBase`, called from `KeywordSpotter::CreateStream`) confirmed that keyword strings passed to the spotter must already be split into the model's BPE sub-word pieces (e.g. `▁HE Y ▁N O V A`) — each token is looked up literally against `tokens.txt`; raw words like "hey nova" fail per-token as out-of-vocabulary. This tokenization normally runs offline via `text2token.py` against the model's `bpe.model` (a SentencePiece model); there is no on-device/runtime tokenizer exposed anywhere in the Kotlin/JNI API, and the two ways around that (a custom JNI binding to sherpa-onnx's own C++ tokenizer, or pulling in a JVM SentencePiece binding) both carry the same class of Android-ARM-native-dependency risk that killed Vosk. "Open-vocabulary" actually means: the keyword list isn't baked into the model weights at training time (unlike openWakeWord) — you can swap which pre-tokenized phrases are active per `KeywordSpotter.createStream()` call — but each phrase still needs one offline tokenization pass before it can ever be recognized.

**Decision (Phase 5b, user, 2026-08-16): ship a fixed 5-name list instead of free-text wake words.** Given the tokenization constraint, the user chose 5 supported assistant names — Aigentik, Nova, Codey, Juno, Milo — over either building a large pre-tokenized name table or reintroducing per-user cloud tokenization. Each was tokenized once at development time (`text2token` against the gigaspeech KWS model's `bpe.model`, all 5 encoded with zero out-of-vocabulary tokens) and the resulting BPE-piece strings are hardcoded in `VoiceAssistantForegroundService.KNOWN_KEYWORDS`. Consequences:
- `WakeWordSettingsService.presetNames` is now the complete, exhaustive list of names with real wake-word support — not just "suggested tiles," as 8.3.1/8.3.2 originally framed presets. `onboarding_screen.dart`'s Assistant Identity page had its free-text "or type your own" field removed for this reason; typing a non-preset name is no longer offered as a wake-word path anywhere in the app.
- `tierForName()` now always returns `WakeWordTier.curated` (accurate again — every supported name really is a pre-generated, bundled, zero-runtime-cost model, which is what "curated" was defined to mean in Section 8.4 before 8.3.1 temporarily collapsed the tier distinction).
- Model assets actually bundled: `sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01-mobile` (k2-fsa, Apache 2.0, GigaSpeech-trained), int8-quantized encoder (4.0 MB) + decoder (1.06 MB) + int8 joiner (0.16 MB) + `tokens.txt` (5 KB) + a 5-line `keywords.txt` ≈ **5.3 MB total**, bundled in `assets/kws/` — small enough that "bundle everything, stay offline" was clearly the right call over any download-on-demand scheme. Adding a 6th name later means re-running `text2token` against `assets/kws/bpe.model` (kept in the repo... actually not bundled in the shipped assets, see note below) for the new phrase and adding it to both `assets/kws/keywords.txt` and `KNOWN_KEYWORDS`.
- **Note**: `bpe.model` itself (245 KB, needed only to tokenize *new* names, never at runtime) was deliberately *not* copied into `assets/kws/` — the app never calls the tokenizer at runtime, so shipping it would be dead weight. It's cached in this session's scratchpad; a future session adding a 6th name should re-download the model bundle from `https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01-mobile.tar.bz2` rather than assume `bpe.model` is still sitting somewhere local.

### 8.4 Data model

```
WakeWordConfig {
  assistantName: String            // "Nova" — display/persona/TTS-intro
  wakePhrase: String                // "Hey Nova" — what the user actually says
  tier: enum { curated, customGenerated, customKeywordSpotting }
  modelAssetPathOrFileUri: String?  // bundled asset path (Tier 1) or cached
                                     // downloaded/generated model file (Tier 2a)
  engine: enum { porcupine, vosk, none }
  enabled: bool
  sensitivity: double               // 0.0–1.0, exposed in Settings, trades
                                     // false-accepts vs false-rejects
  createdAt / lastVerifiedAt: DateTime
}
```

Persisted via `SharedPreferences` (non-secret metadata) with the model binary itself in app-private storage (`path_provider`'s app-support directory), never in `SharedPreferences` itself.

### 8.5 Lifecycle: collect → validate → store → load → detect → change → enable/disable

1. **Collect** (Onboarding "Assistant Identity" step, Section 11): user picks from curated tiles or types a custom name; UI immediately shows which tier that choice falls into and what it implies (instant vs. "needs setup").
2. **Validate**: for curated, validation is just "does the bundled model asset exist" (a packaging sanity check, effectively always true in a correctly built release). For custom, validation means either a successful model-generation API round-trip (Tier 2a) or a successful "say your phrase 3 times, we detect consistent energy/phoneme patterns" micro-check (Tier 2b/3) before allowing Finish.
3. **Store**: `WakeWordConfig` written to `SharedPreferences` (metadata) + app-private file storage (model binary), inside a `WakeWordSettingsService` (new, mirrors `AiService`'s persistence pattern).
4. **Load**: `VoiceAssistantForegroundService` (Kotlin) reads the active config via a `MethodChannel` call at service start (or the Dart side pushes it down whenever it changes, whichever proves more reliable in Phase 3 prototyping) and initializes the chosen native engine (Porcupine SDK instance keyed to the model file, or a Vosk grammar/keyword list).
5. **Use by the detector**: the foreground service's native audio callback runs the chosen engine per audio frame; on a positive detection it (a) plays/vibrates a short acknowledgment cue, (b) transitions the state machine to `Listening`, (c) starts the STT capture window.
6. **Change later from Settings**: a "Wake Word" settings card (mirrors existing `_buildSettingsCard` pattern) lets the user re-run the same picker; changing it tears down and re-initializes the native engine in the running foreground service without requiring an app restart (`MethodChannel` "reloadWakeWord" call).
7. **Disable/enable**: a single Settings switch; disabling stops the foreground service's wake-word engine (and, if no other background feature needs it — e.g., Telegram polling — can stop the foreground service entirely) without deleting the stored `WakeWordConfig`, so re-enabling doesn't require re-onboarding.

---

## 9. User-Selected Wake Word Design (UI/UX Specification)

Onboarding "Assistant Identity" step (new, inserted between Welcome and Permissions — see Section 11):

- Header: "What should I call myself?"
- A horizontally scrollable set of curated tiles (name + tiny waveform icon), e.g. Nova / Aigentik / Private / Jarvis-style alternatives (final names to be chosen w/ legal/trademark review — avoid "Jarvis," "Alexa," "Siri," "Google" literally, as those risk trademark/brand confusion; propose neutral original names).
- Below the tiles: "Or type your own" text field. Typing a name **not** in the curated set immediately shows an inline badge: "Custom name — requires one-time setup, slightly higher battery use" with a "Learn why" info icon linking to a short explainer sheet reusing the content of Section 8.3 in plain language.
- "Test it" button: available once a curated name is picked (instantly) or once custom generation/enrollment completes; runs a 10-second live mic test where the user says the phrase and gets visual pass/fail feedback before Finish is enabled — this satisfies the "Wake-word test" onboarding requirement (Section 11 item 10).
- Persisted immediately on selection (not just at the very end of onboarding), so a user who backgrounds the app mid-onboarding doesn't lose the choice.

Settings → "Wake Word" card (new):
- Current assistant name + wake phrase, editable via the same picker flow.
- Enable/disable toggle.
- Sensitivity slider (false-accept vs. false-reject trade-off), only meaningful for Tier 1/2a (Porcupine); hidden or relabeled for Tier 2b (Vosk) where the notion is different.
- "Re-test wake word" button (same 10-second test UI as onboarding).
- Tier/engine indicator (small text: "Offline detector" vs. "Custom (higher battery use)") so the user always understands the trade-off they picked.

---

## 10. Android Digital Assistant Integration

### 10.1 What Android officially supports for third-party apps

- **`VoiceInteractionService` + `VoiceInteractionSessionService`**: the real, documented mechanism for becoming a selectable "Assistant app" (Settings → Apps → Default apps → Digital assistant app, or the OEM equivalent). A properly implemented pair of these services lets the OS route the long-press-home / assistant-swipe gesture to the app and show a `VoiceInteractionSession` UI (can be a bottom sheet or full-screen). This is genuinely available to third-party apps — no special Google partnership is required to *implement* it.
  - **Correction (Phase 9, 2026-08-18)**: this pair is not actually sufficient on its own. Reading AOSP's `VoiceInteractionServiceInfo.java` parser directly confirmed a third, mandatory component: a working `android.speech.RecognitionService`, declared via the same `voice-interaction-service` XML metadata's `recognitionService` attribute. If it's missing, the parser sets a parse error and the OS refuses to register the app as assistant-capable at all — there is no "assist-only, no recognizer" mode, contrary to what this section originally implied. The implementation built for Phase 9 (`AssistantPassthroughRecognitionService`) satisfies this by delegating every call to the device's actual default recognizer rather than reimplementing STT — see `docs/ANDROID_DIGITAL_ASSISTANT_PROGRESS.md`'s Phase 9 session entry for the full reasoning.
- **`RoleManager` / `ROLE_ASSISTANT`**: on Android 10+ (API 29+), an app can call `RoleManager.createRequestRoleIntent(ROLE_ASSISTANT)` to prompt the user to make it the system default assistant. Whether this actually takes effect and how the OS surfaces "long-press home" to the app **still varies by OEM launcher** (see Samsung note below).
- **Foreground services with `FOREGROUND_SERVICE_MICROPHONE`** (required on API 34+/Android 14): fully supported way to keep a microphone-owning process alive while showing a mandatory ongoing notification. This is the correct, supported mechanism for "the assistant can remain available in the background" — not a hack.
- **`RECEIVE_BOOT_COMPLETED`**: fully supported, standard way to optionally restart a foreground service after reboot, gated by explicit user opt-in (Android increasingly restricts what a freshly-booted, not-yet-opened app can do; a boot receiver should only *offer* to resume listening, or silently restart the same foreground-service state that was active before reboot — not silently escalate permissions the user hasn't granted).
- **Notification channels with `IMPORTANCE_LOW`/ongoing flag**: correct way to show the "listening" indicator without being obnoxious.

### 10.2 What Android restricts, deprecates, or makes unreliable

- **Android 12+ (API 31+) mic/camera indicator**: any time the mic is actively recording — including from a background foreground service — the OS shows a green mic dot in the status bar. This is not avoidable and should be treated as expected, disclosed behavior, not a bug.
- **Android 13+ notification permission (`POST_NOTIFICATIONS`)**: already handled in this app for one-shot notifications; the ongoing foreground-service notification requires the same runtime permission, and if denied, **the foreground service can still technically start** but the OS will demote it, which on some Android versions can prevent the mic-owning foreground service from running reliably at all — the onboarding must treat notification permission as effectively mandatory for the voice feature, not optional (contradicts today's onboarding, which lists Notifications as "OPTIONAL" — this must change once voice ships, see Section 6).
- **Android 14 (API 34) foreground service types**: a foreground service that accesses the microphone must declare `android:foregroundServiceType="microphone"` and hold `FOREGROUND_SERVICE_MICROPHONE`; starting such a service **from the background without an existing user-visible trigger is restricted** — practically, the safest supported pattern is: user explicitly enables "background listening" from inside the app (a foreground Activity context) and the service is started/kept alive from that point on, not silently auto-started at boot without ever having been foregrounded first in the current session (a boot-triggered restart is allowed if it was previously running before the reboot — this is documented Android behavior around "user-initiated" foreground services, not a project-specific guess, but the exact rules should be re-verified against the Android version matrix actually targeted, since this area of policy has changed release to release).
- **Battery optimization / Doze / App Standby Buckets**: even a correctly implemented foreground service can be paused or have its wake locks ignored under Doze on some OEM skins unless the user grants "Unrestricted" battery usage. The app can request this via `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, but Google Play policy restricts *what kinds* of apps may request this outright (it is intended for apps with a legitimate ongoing background purpose — a voice assistant plausibly qualifies, but the flow must explain *why* rather than requesting it unprompted at first launch).
- **Samsung/OneUI specifics**: Samsung's device-care "Sleeping apps"/"Deep sleep" battery management is historically more aggressive than stock Android at killing background processes and foreground services that the user hasn't explicitly whitelisted, *even when the app correctly uses the foreground-service APIs*. Samsung also has its own Bixby-related assistant-role plumbing that can interact unpredictably with `ROLE_ASSISTANT` requests (some OneUI versions restrict the assistant-app picker or route the "long press power/home" gesture partly to Bixby regardless of the OS-level default-assistant setting). The plan must budget explicit onboarding UI that walks Samsung users to Settings → Apps → PrivateAgent → Battery → "Unrestricted," similar to the existing "Restricted setting" accessibility walkthrough already in this app's onboarding (a good precedent to extend, not replace).
- **Lock-screen behavior**: a foreground service can keep listening while the screen is locked (subject to all of the above), but showing any *UI* in response (beyond the persistent notification) generally requires either a full-screen intent notification (heavier, used sparingly, historically for calls/alarms) or waiting until the device is unlocked to show a session UI. "Voice works, screen stays off, response is TTS-only" is realistic; "a rich visual assistant overlay pops up over the lock screen" is not something to promise for v1.

### 10.3 Clear separation of what's achievable

| Capability | Achievable how |
|---|---|
| "Hey [Name]" wakes the app while it's backgrounded (not force-stopped, not battery-restricted) and it listens/responds via TTS | **Normal app + foreground service.** No assistant-role needed. This is the core requested experience and is fully achievable with supported APIs. |
| Long-press home button / OS assistant gesture routes to PrivateAgent | **Requires becoming the user's chosen default assistant** via `VoiceInteractionService` + `ROLE_ASSISTANT` request flow, and the user must actively pick it in system settings. Should be built as an **additive, optional Phase 9 feature**, not a dependency of the core wake-word flow. |
| App survives an explicit Force Stop from Android system settings | **Not achievable, by design of the OS.** Force Stop kills the process and disables all its receivers/services (including the accessibility service and boot receiver) until the user manually reopens the app. This is documented Android behavior, not a bug to work around — the plan must state this plainly in the Definition of Done and testing plan rather than promise otherwise. |
| "Hey [Name]" works with the screen fully off and the app not recently used, indefinitely, with zero battery-optimization configuration by the user | **Not reliably achievable on stock behavior**, especially on Samsung, without the user granting battery-optimization exemption (which the app can request but not force). This must be disclosed, and the onboarding battery-optimization step exists precisely to close this gap as much as Android allows. |
| Fully Google-Assistant-equivalent behavior (works before first unlock, screen-off ambient wake with zero setup, system-wide "Hey Google"-style privilege) | **Not achievable by a third-party app under any current public API**, full stop — this level of privilege is reserved for the OS-designated system assistant / OEM-privileged processes. |

---

## 11. First-Run Setup (Revised Onboarding Flow)

Current onboarding is 3 steps (Welcome → Permissions → AI Setup). Proposed revision to 6 steps, preserving all existing logic/widgets and inserting new ones:

1. **Welcome** *(existing, unchanged)*.
2. **Assistant Identity** *(new)* — wake-word/name selection per Section 9. Ends with the wake-word "Test it" pass/fail check.
3. **Permissions** *(existing, extended)* — add: Microphone is already mandatory here; **promote Notifications from OPTIONAL to MANDATORY** (rationale in Section 10.2) with updated copy explaining it's required for the ongoing "listening" indicator, not just task-complete alerts; add a new mandatory-for-voice card for **Battery Optimization** ("Allow PrivateAgent to run in the background so it can hear your wake word") that opens the system battery-exemption prompt, with the same "why this is needed" explanatory pattern already used for Accessibility's "Restricted setting" dialog.
4. **AI Setup** *(existing, unchanged)* — provider/model/API key configuration.
5. **Voice Test** *(new)* — a short "say something and I'll say it back" round-trip that exercises STT → (skip LLM) → TTS, confirming the whole non-wake-word voice path works end-to-end before the user ever needs the wake word.
6. **Assistant Readiness Check** *(new)* — a summary screen listing each subsystem with a green/red status (Accessibility ✅, Microphone ✅, Notifications ✅, Battery unrestricted ✅/⚠️, Wake word configured ✅, AI configured ✅) and a single "Finish Setup" action, replacing today's implicit "Finish Setup" button on the AI Setup page. If any mandatory item is red, Finish is disabled with an inline explanation — mirrors the existing `_canProceedToModel` gating pattern already used between Permissions and AI Setup.

An explicit **"Default Assistant (optional)"** step should NOT be part of the mandatory first-run flow — offer it later, from Settings, as an opt-in "Make PrivateAgent your Android assistant" action that triggers the `RoleManager` request intent, once `VoiceInteractionService` support ships (Phase 9). Forcing this during first-run onboarding adds friction and a system dialog most users will decline; it should be discoverable, not mandatory.

---

## 12. Voice Pipeline

```
[Foreground service, native]      [Dart controller]                [Existing agent stack]
Wake-word engine (Porcupine/Vosk) 
        │ positive detection
        ▼
Audio capture window opens  ──►  VoiceConversationController
(short pre-roll + live audio)     .onWakeDetected()
                                          │
                                          ▼
                                   VoiceService.startListening()
                                   (speech_to_text, ListenMode tuned
                                   for continuous/dictation instead
                                   of today's "confirmation" mode)
                                          │ final transcript
                                          ▼
                                   AiService.sendMessageStream(transcript,
                                     isAgentMode: true)
                                          │ text / action JSON
                                          ▼
                     ┌────────────────────┴─────────────────────┐
                     ▼                                            ▼
        Plain text response                          Action/execute_task
                     │                                            │
                     ▼                                            ▼
        VoiceService.speak(response)         ActionHandler/TaskExecutor run,
                                              onProgress narrated via TTS at
                                              sensible checkpoints (not every
                                              step — avoid speaking 15 steps
                                              of "clicked X" verbatim), then
                                              final result spoken
                                          │
                                          ▼
                     VoiceConversationController decides:
                     - if a natural follow-up is likely (e.g. assistant asked
                       a clarifying question) → re-open the mic WITHOUT
                       requiring the wake word again, for a bounded window
                       (e.g. 8–10s of silence-timeout)
                     - otherwise → return to Idle, re-arm wake-word engine
```

**Component responsibilities:**
- **Wake-word engine (native/Kotlin)**: only job is "did I hear the phrase." Runs continuously at very low duty cycle. Never sees full sentences, never calls the LLM.
- **`VoiceService` (Dart, extended)**: owns `speech_to_text`/`flutter_tts` calls; gains a "continuous/dictation" listen mode alongside the existing "confirmation" (push-to-talk) mode already used by the chat UI, so the existing manual mic button behavior is not disturbed.
- **`VoiceConversationController` (Dart, new)**: the state machine; the only new "brain" component, and it deliberately contains **no LLM/tool logic of its own** — it is glue, not a second agent.
- **`AiService`**: unchanged in its core contract; voice calls the exact same `sendMessageStream`. Consider adding a lightweight `responseStyle: voice` hint appended to the outgoing prompt context so responses stay concise and TTS-friendly (short sentences, no markdown tables/code blocks) — implemented as an additional system-prompt fragment, not a new client.
- **`ActionHandler`/`TaskExecutor`**: unchanged. Voice narration hooks into the existing `onProgress` callback parameter that `TaskExecutor` already exposes (`task_executor.dart:28,39`) — this parameter already exists and is already used by the chat UI to show step text; voice simply adds a second subscriber that speaks selected checkpoints instead of only rendering text.

**Local-first stance:** wake-word detection is local (Tier 1/2a/2b, Section 8) by construction. STT can be local-on-device where the OEM's `RecognitionService` supports offline recognition (device-dependent, must be detected at runtime — `speech_to_text` exposes `locales`/`onDevice` capability flags that should be surfaced, not assumed) or cloud-based where it isn't; this should be surfaced to the user ("On-device speech recognition available" vs. "Using cloud speech recognition") rather than silently assumed. The LLM call is inherently remote unless the user has configured a local/Ollama provider (already supported) — this is unavoidable and already true of every text interaction in the app today.

---

## 13. Agent Integration

No new agent is created. `VoiceConversationController` is a client of the existing agent surface exactly the way `HomeScreen` is today:

- Text turns: `AiService.sendMessageStream(text, isAgentMode: true)` → same parsing (`AiService.parseAction`) → same `ActionHandler.execute(...)` dispatch already used in `home_screen.dart` (~line 149 onward).
- Multi-step turns: identical `execute_task` action path into `TaskExecutor`, unchanged.
- Conversation history: voice turns should be appended to the same `AiService._conversationHistory` rolling window used by text chat (so a user can start a request by voice and finish it by typing, or vice versa, within one logical session) — this requires no new storage, only calling the same `addHistoryMessage`-adjacent code paths already present.
- Session persistence: voice sessions should save through the existing `ChatHistoryService.saveSession` mechanism just like text chat sessions do today (`home_screen.dart:_saveSession`), tagged distinguishably (e.g. a `source: 'voice'` field on the session or message) purely for later UI/analytics purposes — not a new storage system.

---

## 14. Accessibility Integration

No changes required to `AgentAccessibilityService.kt` itself — it is already the execution backend for both `ActionHandler` and `TaskExecutor`, and the voice layer reaches it exclusively through those two, never directly. The one integration risk worth flagging: today, `ScreenAutomationService`'s `MethodChannel` is registered by `MainActivity.configureFlutterEngine`, tied to the Activity's Flutter engine. Once a **second**, service-owned Flutter engine exists for background voice (if that architecture is chosen — see Section 7's native-first fallback), that engine will need its *own* registration of the same channel name pointed at the same `AgentAccessibilityService.instance` singleton, which is exactly what the currently-dormant `BackgroundEngineReceiver` was seemingly built to support — this existing-but-unused code path should be investigated and likely completed/repurposed in Phase 5 rather than reinvented from scratch.

---

## 15. Memory/Conversation Design

Two existing, separate memory stores must be reconciled, not replaced:
- `AiService._conversationHistory` — short-lived, in-process, last-20-messages rolling window, used to give the LLM short-term context within a live session. Cleared on process death.
- `ChatHistoryService` — disk-persisted full session transcripts for the chat UI's history list.

**Proposed addition, not replacement:** a `VoiceSessionState` held by `VoiceConversationController` that tracks only what's needed for the "continue without repeating the wake word" behavior (Section 12's bounded follow-up window) — this is ephemeral, in-memory, and explicitly time-boxed (a hard timeout, e.g. 10–15 seconds of silence after the assistant finishes speaking, returns to Idle and re-arms the wake word). No new long-term memory system should be introduced; "the agent can use its existing tools... and memory/context" is satisfied by reusing `AiService`'s existing rolling history plus `SkillMemoryService`'s existing learned-skill replay (`TaskExecutor` already does this for any goal, voice-originated or not).

---

## 16. Privacy/Security

### 16.1 What is currently captured and where it goes

**Correction (Phase 11, 2026-08-20)**: the table below originally described the pre-voice-work codebase and is now stale on one point — API keys/tokens moved to `flutter_secure_storage` in Phase 1, not plaintext `SharedPreferences` as first audited. Updated to reflect current reality; see `docs/ANDROID_DIGITAL_ASSISTANT_PROGRESS.md`'s Phase 11 session entry for the rest of the Phase 11 audit (logging of full prompts/screen dumps/action params, now gated to debug builds only; `logToNative`'s task-goal logging, now truncated).

| Data | Captured how | Leaves device? |
|---|---|---|
| Chat/task text | Typed or (push-to-talk) transcribed | Yes — sent to whatever LLM `baseUrl` is configured (DeepSeek/Groq/NVIDIA/OpenRouter/custom cloud, or stays local if Ollama/local server is configured) |
| Screen accessibility dumps | `AgentAccessibilityService.dumpScreen()` | Yes — the text dump (not a screenshot, no bitmap by default) is included directly in the LLM prompt during `execute_task` runs; a JPEG screenshot capability exists (`takeScreenshot`) but is **not currently invoked by `TaskExecutor`'s main loop** (it exists as an exposed method but grep of `TaskExecutor` shows the text-dump path is what's actually used step-by-step) — this should be re-verified in Phase 0 of implementation since it directly affects what "screen contents" leaves the device |
| API keys / Telegram bot token | User-entered | Stored **locally only**, in Android Keystore-backed `flutter_secure_storage` (migrated Phase 1) — not a current risk in the way plaintext storage would be |
| Task/chat history | Local disk (`ChatHistoryService`, `TaskHistoryLogger`) | No — local only, never uploaded, but also never encrypted at rest |
| Telegram integration | Bot token + relayed commands | Yes, inherently — by design, once enabled, Telegram's servers see command text (this is an explicit, opt-in feature already disclosed in the README) |

### 16.2 What voice adds, and the privacy posture to build toward

- **Wake-word audio**: must never leave the device, under any tier (Section 8). Tier 1/2b are local-only by construction; Tier 2a's model *generation* step sends short **enrollment/training audio or text**, not ongoing listening audio, to the wake-word vendor once, at setup time — this must be disclosed explicitly in the "Custom name" explainer (Section 9).
- **Post-wake audio (the actual command)**: goes through `speech_to_text`, which — depending on the OEM's `RecognitionService` and whether on-device recognition is available for the user's locale — may send audio to a cloud STT backend (this is already true of today's push-to-talk feature; voice mode doesn't newly introduce this, it just makes it happen automatically instead of on tap). The app should surface which mode is active (Section 12) so this isn't invisible.
- **Full transcript**: goes to the LLM provider, exactly as typed chat does today; no new exposure category, just a new trigger mechanism.
- **Continuous-listening design should be "wake word only, always"** — i.e., the foreground service's native audio callback should run *only* the tiny wake-word classifier by default; it must not run full transcription continuously in the background "just in case," both for battery and for privacy (this is the correct default and should be a hard architectural rule, not a toggle defaulting to the expensive/invasive option).
- **Recommendation**: migrate API keys/tokens to `flutter_secure_storage` (Android Keystore-backed) as part of this project (Phase 1 or 11) — this is a pre-existing gap, not a new one introduced by voice, but voice work is a natural forcing function to fix it since it touches Settings persistence broadly anyway.
- **Recommendation**: add an explicit, visible "Privacy" settings card summarizing exactly what's captured and where it goes (mirroring the tone of this section) — the requirements explicitly call for this to be documented; making it user-visible, not just documented here, closes the loop.

---

## 17. Performance/Battery

- **Wake-word engine (Tier 1/2a, Porcupine-class)**: designed for always-on use; published vendor figures are typically low-single-digit-percent CPU on a modern SoC and negligible measured battery drain over a full day — but this project should **measure on an actual target device** (see Testing Strategy) rather than trust vendor marketing, since the actual number depends on device, Android version, and how the foreground service's audio session is configured (sample rate, buffer size, whether the mic is shared/exclusive).
- **Vosk-based custom-phrase fallback (Tier 2b)**: meaningfully heavier — a small continuous ASR model instead of a binary classifier. Should default to a **duty-cycled** approach (e.g., only actively spot-checking short windows rather than fully continuous decoding) if adopted, and the UI must set the expectation ("higher battery use") set in Section 8.3/9.
- **STT (post-wake)**: only runs for the few seconds of an actual command, not continuously — cost is bounded and already proven acceptable today via the push-to-talk feature.
- **TTS**: negligible CPU, runs briefly per response; no special concern.
- **LLM network calls**: unchanged from today's chat behavior; still subject to whatever provider/model the user picked, same cost profile as text chat.
- **Local LLM (Ollama/local server)**: entirely dependent on what's running on the LAN/host the phone points at — out of this app's control, already true today.
- **RAM**: keeping a second (background) Flutter engine resident, if that architectural path is chosen, has a real memory cost (tens of MB) worth weighing against the alternative of doing more of the wake→capture→forward pipeline in pure Kotlin and only spinning up Dart when there's an actual command to process — this trade-off should be prototyped and measured in Phase 5, not decided from first principles alone.
- **Thermal**: not expected to be a concern given the bounded, event-driven nature of the pipeline (idle wake-word listening is designed to be cheap; the expensive parts — STT, LLM, screen automation — are all short-lived and already exist today without reported thermal issues).
- **Recommendation for a modern Samsung phone**: default to Tier 1 curated wake words for the vast majority of users (cheapest, most reliable), keep Tier 2 clearly labeled as a trade-off, and make "background listening" itself an explicit, reversible toggle (not silently always-on) so users on older/lower-end devices can opt out of the battery cost entirely and fall back to push-to-talk (which already works today).

---

## 18. Testing Strategy

### 18.1 Unit tests (Dart, `flutter test`)
- `WakeWordSettingsService`: persistence round-trip (save/load `WakeWordConfig`), tier-selection logic, "custom name not in curated list" detection.
- `VoiceConversationController`: full state-machine transition table (Idle→Woken→Listening→Transcribing→Thinking→Speaking→Idle, and the ContinuingConversation branch with its timeout), including forced-error transitions (mic denied mid-flow, STT error, LLM error, action-execution failure) — this is the highest-value new test surface and currently has **zero** analogous coverage anywhere in the repo, so patterns will need to be established from scratch (likely via a fake/mock `AiService`/`ActionHandler` injected into the controller, following the constructor-injection pattern `TaskExecutor` already uses).
- `AiService` voice-mode prompt wrapping (if a `responseStyle: voice` hint is added): confirm it doesn't corrupt action-JSON parsing for `execute_task`/single-shot actions.
- Regression coverage for the existing `TaskExecutor`/`ActionHandler` logic that voice will now depend on more heavily (currently **also** untested — recommend backfilling at least action-dispatch and JSON-extraction unit tests here as a shared dependency, since a voice regression could as easily originate from an untested pre-existing code path as from new code).

### 18.2 Android/instrumentation tests (`androidTest/`, new — none currently exist)
- Permission flow: request → grant/deny → correct state reflected in Settings/Onboarding (`espresso`/`UiAutomator`-based).
- Foreground service: start/stop lifecycle, correct notification channel/importance, `foregroundServiceType="microphone"` present, survives Activity destruction.
- Accessibility service interaction from a background-service-owned engine (validates the `BackgroundEngineReceiver` re-registration path actually works, since it appears untested/unused today).
- TTS/STT smoke tests via the platform channels, on a real device/emulator with a `RecognitionService`/`TTS_SERVICE` present (CI emulators often lack these — flag as a known CI limitation, requiring either a device farm or manual verification step, not something to silently skip).

### 18.3 End-to-end tests (manual + scripted where feasible)
Primary scenario: `"Hey [name]"` → wake detected → `"Open Chrome"` → Chrome opens → assistant confirms verbally.
Additional required scenarios, each with explicit pass/fail criteria to define upfront:
- Web search by voice ("search for nearby coffee shops").
- App launching by voice (several different target apps).
- Screen interaction / multi-step command by voice ("open settings and turn on wifi").
- Failed command (ambiguous/impossible request) → assistant states it couldn't do it, doesn't hang.
- Network failure mid-request → graceful spoken error, returns to Idle (not stuck in Thinking forever).
- LLM failure (bad API key / provider outage) → graceful spoken error.
- Microphone failure (permission revoked mid-session, hardware busy from another app) → graceful spoken/notification error, not a silent hang.
- Wake-word false positive rate over an extended idle period (e.g., leave the phone idle with TV/conversation noise nearby for N hours, count false wakes) — needs a defined acceptable threshold before ship.
- Wake-word false negative rate (say the phrase N times in varied environments/distances, measure detection rate).
- Changing the wake word from Settings → old phrase no longer triggers, new phrase does, without app restart.
- Reboot the phone → (only if boot-restart is enabled by the user) confirm the service resumes appropriately, or confirm it correctly does **not** resume if the user hasn't opted in.
- Force-stop the app from Android system settings, then reopen → confirm the app clearly communicates that background listening needs to be re-enabled (does not silently claim to still be listening) — ties directly to the Section 10.3 limitation.
- Battery optimization: with the app *not* exempted, measure how quickly/whether the OS kills the background listener, to validate the onboarding step's necessity empirically rather than by assumption.
- Lock-screen behavior: confirm wake→listen→respond works with the screen off/locked where the OS/OEM allows it, and confirm the app's UI/docs don't overclaim where it doesn't.

### 18.4 Devices to test against
At minimum: one recent Samsung/OneUI device (explicitly called out in the requirements as a special case) and one close-to-stock Android device (e.g., Pixel), across at least two Android versions spanning the API 26 minimum and a current API level, to catch the version-dependent foreground-service/notification-permission behavior discussed in Section 10.2.

---

## 19. Security

Building on the audit in Sections 4 and 16:

- **API keys/tokens in plaintext `SharedPreferences`** is the most concrete existing security gap; recommend migrating to `flutter_secure_storage` as part of this project (touches the same Settings/persistence code the voice work is already extending).
- **Arbitrary tool execution surface**: `TaskExecutor`/`ActionHandler` already grant the LLM considerable device control (clicking, typing, launching apps, sending SMS, making calls) gated only by the user's own configured API key/model — this is an existing, accepted risk model for this project (an LLM-driven automation agent inherently trusts its configured model's outputs within the action vocabulary it defines), not something voice changes in kind, only in *trigger convenience* (a wake word makes it easier to accidentally invoke than a deliberate typed message or a deliberate mic-button tap). Recommend a lightweight "confirm before destructive actions" guard specifically for the highest-risk actions (`send_sms`, `make_call`) when triggered via voice, since voice transcription errors are a more likely source of an unintended destructive action than typed text. This is a UX/safety addition worth scoping in Phase 7, not a structural rewrite.
- **Shizuku/shell integration** (`ShizukuService`, `input` shell commands): already an optional, explicitly-opt-in power-user feature requiring a separate app (Shizuku) and explicit permission grant; no change needed for voice, but worth noting it's part of the same "how much device control does this app have" picture when reasoning about voice-triggered risk.
- **Accessibility permission scope**: `BIND_ACCESSIBILITY_SERVICE` combined with `canRetrieveWindowContent`/`canPerformGestures` is inherently broad (this is required for the app's core feature, not a voice-specific concern) — worth reiterating in user-facing privacy copy (Section 16.2's recommended Privacy settings card) since it's the single most powerful permission this app holds.
- **Logs**: current logging goes through `dart:developer log()` (visible in `adb logcat`/Flutter DevTools during development, not persisted or exported by the app itself) — recommend explicitly **not** logging full transcripts or API keys at `info` level once voice ships (a quick grep-based check before release: confirm no `log('...${apiKey}...')`-style statements exist).
- **Remote model providers**: unchanged risk profile from today — whatever provider/base URL the user configures receives the request content; this is inherent to the "bring your own provider" design and already disclosed via the onboarding's provider-selection UI.

---

## 20. Build and Release Strategy

Current state (verified): release build type signs with the **debug keystore** (`android/app/build.gradle:33-38`, explicit `// TODO: Add your own signing config`), `versionCode`/`versionName` come from `pubspec.yaml`'s `version: 1.0.2+2021` via Flutter's Gradle plugin (`flutter.versionCode`/`flutter.versionName`), and CI already proves both `flutter build apk --release` and `--split-per-abi` succeed today.

Before any real release build for this feature set, the following must be true (this becomes the first half of the Phase 14 checklist):
1. A real upload/release keystore generated and wired into `android/app/build.gradle`'s `signingConfigs`/`buildTypes.release`, with the keystore itself **not** committed to the repo (standard `key.properties`-outside-VCS pattern) — currently absent entirely.
2. `pubspec.yaml`'s `version` bumped appropriately for this feature (a minor/major bump given the scope, per whatever versioning convention the maintainers already use — `1.0.2` → e.g. `1.1.0` for a major feature addition, at maintainer discretion).
3. All new permissions (Section 4a) added to the manifest with the correct `foregroundServiceType`/`minSdk`-gated declarations.
4. `flutter analyze` clean (extends today's `flutter_lints` baseline to all new code).
5. `flutter test` green, including the new unit tests from Section 18.1.
6. Android instrumentation tests (Section 18.2) run at least once against a real/emulated device before tagging a release, even if not wired into the existing GitHub Actions workflow (which currently has no `androidTest` step — extending CI to run instrumentation tests is a reasonable Phase 14 task but is not a hard prerequisite for a first internal test build).
7. Manual E2E pass of the primary scenario (Section 18.3) on at least the Samsung + near-stock device pair.

---

## 21. Colab/colab-cli APK Build Plan

This section documents **what must be true and what the eventual build sequence looks like**, per the task's explicit instruction not to implement the build system yet. Commands below are derived from what already exists in this repository (the CI workflow, `pubspec.yaml`, Gradle files) — no commands are invented that aren't already implied by the existing build configuration.

**Preconditions before a Colab build can be attempted:**
- The repository, including all new voice-feature source and the (documented, not-yet-generated) release-signing configuration, must be committed and pushed (or otherwise transferable) to whatever the Colab environment will clone/pull from.
- `local.properties` (which contains the local `flutter.sdk` path, referenced by `android/settings.gradle`) is **not** committed (correctly gitignored) and must be regenerated inside the Colab environment, not copied from Termux — this is a real, environment-specific step, not boilerplate.
- Any native wake-word SDK dependency (e.g., a Porcupine Android AAR/Maven artifact) chosen in Phase 3 must be resolvable from within the Colab environment's network access (Maven Central/Google's repository already covered by `android/build.gradle`'s `repositories { google(); mavenCentral() }`; a vendor-specific Maven repo, if required, would need to be added at that time).

**Documented sequence (to be executed only when implementation begins, not now):**
1. Local repository validation in Termux: `git status` clean, all planned changes committed.
2. Static analysis: `flutter analyze` (as already used in this project's toolchain; no separate linter is configured).
3. Unit tests: `flutter test` (extends the existing single-file suite).
4. Android instrumentation tests where feasible: `flutter test integration_test/` or `./gradlew connectedAndroidTest` from `android/` — **note**: neither an `integration_test/` directory nor any `androidTest/` sources exist yet in this repo; these must be authored as part of Phase 12 before this step has anything to run.
5. Flutter tests (covered by step 3 — no separate "Flutter test" step distinct from unit tests exists in this Flutter-only project).
6. Release configuration finalized per Section 20 (signing config present, not debug-signed).
7. Version bump committed in `pubspec.yaml`.
8. Signing configuration verified present and **not** accidentally pointing at the debug keystore (a straightforward grep/gradle-task check: `./gradlew :app:signingReport` from `android/`, confirming the `release` variant's signature is the intended upload key, not `debug`).
9. Colab environment preparation: a Colab notebook/session with Flutter SDK matching (or compatible with) the pinned revision in `.metadata` (`66dd93f9a27ffe2a9bfc8297506ce066ff51265f`, channel `stable`) installed, plus Android SDK/NDK components matching what AGP 8.11.1/Kotlin 2.2.20 require (this repo does not pin an exact `compileSdk`/`targetSdk` number — it defers to whatever Flutter tool version resolves `flutter.compileSdkVersion`/`flutter.targetSdkVersion` to, so the Colab Flutter install should match the pinned revision closely to get equivalent SDK resolution to local builds).
10. Installing required dependencies through `colab-cli`: the exact `colab-cli` commands are outside this repository's knowledge (that tool's interface isn't part of this codebase) — this step must be filled in by whoever operates `colab-cli`, using it to provision the Flutter/Android toolchain described in step 9 inside the remote Colab runtime.
11. Uploading/syncing the project to the Colab environment: via `colab-cli`'s sync/upload mechanism (again, exact command outside this repo's scope) — should sync the full working tree except `build/`, `.dart_tool/`, and any local keystore/`key.properties` files, which should instead be provisioned securely inside the Colab session itself, never synced as plaintext repo content.
12. Building the Android APK using the appropriate Gradle/Flutter commands — these **are** determinable from this repo today, and match exactly what CI already runs:
    ```
    flutter pub get
    flutter build apk --release
    flutter build apk --release --split-per-abi
    ```
    executed from the repository root (matching `.github/workflows/android-release.yml` exactly), producing `build/app/outputs/flutter-apk/app-release.apk` (universal) and the per-ABI variants.
13. Retrieving the APK back into Termux: via whatever `colab-cli` download/sync command mirrors its upload mechanism (outside this repo's scope to specify further).
14. Installing the APK on the Android device: `adb install -r <path-to-apk>` (standard, assuming `adb` and device access are available from wherever the final install step is performed — Termux's `adb` access depends on the user's existing setup, e.g. wireless debugging or a USB-OTG connection to the phone; not something this repository's build config affects).
15. Performing final real-device tests: execute the E2E scenarios from Section 18.3 against the freshly installed release build specifically (not just debug builds used during development), since release builds can behave differently (R8/ProGuard minification if enabled, signing-dependent behavior, no debugger attached) — this is a meaningful, distinct verification pass, not a formality.

---

## 22. Risks and Technical Limitations

1. **No fully free, instant, on-device custom wake-word generation exists.** Addressed architecturally in Section 8 via the curated/custom tiering — but this is a hard external constraint, not a solvable engineering problem, and must be communicated to the user, not hidden.
2. **Background Flutter engine viability is unproven in this codebase.** The `BackgroundEngineReceiver` code exists but appears unused/untested (`REGISTER_BACKGROUND_CHANNELS` broadcast is declared as a manifest intent-filter target but nothing in the current app sends it) — Phase 5 must include a spike to determine whether a cached background Flutter engine reliably survives long enough to be useful, or whether the pure-Kotlin-first-then-invoke-Dart-only-when-needed architecture is more robust. Do not assume either answer going in.
3. **Samsung/OneUI aggressive battery management** can defeat even correctly implemented foreground services; mitigations are UI guidance (Section 10.2), not code fixes, and their effectiveness depends on the user actually following them.
4. **`VoiceInteractionService`/`ROLE_ASSISTANT` is a genuinely separate, larger, higher-risk project** with OEM-dependent reliability (Section 10.2 Samsung note) — scoped explicitly as optional/Phase 9, not a blocker for the core deliverable.
5. **`speech_to_text`'s on-device-vs-cloud behavior is device/locale-dependent and outside this app's control** — the app can detect and surface it (Section 12) but cannot guarantee fully local STT on every device.
6. **CI currently cannot exercise Android instrumentation tests or real voice/wake-word hardware behavior** (no `androidTest` step exists, and GitHub Actions' `ubuntu-latest` runner has no real microphone/audio hardware) — meaning wake-word accuracy, foreground-service survival, and battery-optimization interactions can only be validated via manual/device-lab testing (Section 18), not automated CI. This must be an accepted, ongoing manual QA cost, not something the plan can automate away.
7. **API-key insecurity is a pre-existing issue this project should fix but did not create** — flagging it here so it isn't mistaken for a regression introduced by the voice work.
8. **Force-stop and pre-first-unlock scenarios are permanently out of reach** for a third-party app under current Android policy (Section 10.3) — the Definition of Done and all user-facing copy must reflect this honestly rather than promise Google-Assistant-equivalent behavior.
9. **`local_plugins/agent_native`'s actual purpose is unverified** — it exists in the repo, has its own scaffold/tests, but is not imported anywhere; Phase 0 of implementation must determine whether it's a false start worth deleting, a partially-built voice/native bridge worth completing, or unrelated, before any new native-channel work duplicates or conflicts with it.

---

## 23. Definition of Done

- [ ] Android release APK builds successfully via the Colab/`colab-cli` pipeline described in Section 21, signed with a real (non-debug) release key.
- [ ] APK installs successfully on a physical Samsung device and a near-stock Android device.
- [ ] First-run setup (6-step revised flow, Section 11) completes successfully, including the new Assistant Identity, Voice Test, and Readiness Check steps.
- [ ] User can choose an assistant name/wake phrase from the curated list (Tier 1) with zero setup latency, and can alternatively type a custom name and see accurate, honest UI messaging about the trade-off (Section 8.3/9).
- [ ] Wake-word detection works reliably within its documented technical limitations (measured false-accept/false-reject rates recorded against the thresholds defined in Phase 12 testing, not just "it seems to work").
- [ ] Voice input (post-wake) is transcribed correctly for representative test phrases across the E2E scenarios in Section 18.3.
- [ ] The existing LLM agent (`AiService`/`ActionHandler`/`TaskExecutor`) receives and correctly processes voice-originated commands with no duplicated/forked agent logic.
- [ ] All existing PrivateAgent tools (calls, SMS, alarms, volume/brightness, app launching, contacts, multi-step screen automation) remain fully functional from both text and voice entry points.
- [ ] Accessibility-based screen reading/interaction remains functional and unmodified in its core behavior.
- [ ] The assistant speaks results/errors/confirmations via TTS for voice-originated interactions (not just plain chat replies, as today) — Section 6/12 gap closed.
- [ ] Background operation (wake-word listening while backgrounded) works within Android's permitted behavior: survives normal backgrounding and, where the user has granted battery-optimization exemption, survives extended idle periods; does **not** claim to survive a manual Force Stop (documented limitation, Section 10.3).
- [ ] If `VoiceInteractionService`/assistant-role integration is included in the shipped scope (optional, Phase 9), it works as an additive enhancement without being required for the core wake-word flow to function.
- [ ] All new settings (assistant name, wake phrase, enable/disable, sensitivity, voice/rate, continuous-conversation window, background-listening toggle) persist correctly across app restarts and device reboots.
- [ ] Changing the wake word from Settings takes effect without requiring an app reinstall or full restart.
- [ ] Errors at every pipeline stage (mic denied, STT failure, network failure, LLM failure, action failure) are handled gracefully with a spoken and/or visible message — never a silent hang.
- [ ] No API keys, tokens, or other secrets are present in source control or logs; secrets are migrated to `flutter_secure_storage`.
- [ ] `flutter analyze` and `flutter test` pass; new unit tests (Section 18.1) and, where feasible, instrumentation tests (Section 18.2) exist and pass.
- [ ] A release APK can be produced from Termux using `colab-cli` following the documented Section 21 sequence.
- [ ] The produced APK is installed and manually tested end-to-end on a physical Android device per Section 18.3/18.4.

---

## 24. Recommended Implementation Order

Revised from the task's suggested 17-phase skeleton to reflect what the audit actually found (in particular: architecture spikes before UI work, and secure storage folded in early since Settings persistence is touched broadly anyway).

- **Phase 0 — Repository audit** *(this document; also resolve the open `local_plugins/agent_native` question before Phase 5)*.
- **Phase 1 — Foundational hardening**: migrate secrets to `flutter_secure_storage`; add the `WakeWordSettingsService`/`WakeWordConfig` data model and persistence (no UI yet); backfill unit tests for existing `ActionHandler`/`TaskExecutor`/`AiService` core logic to create a safety net before extending them.
- **Phase 2 — Voice state machine**: build `VoiceConversationController` and its state machine against the *existing* push-to-talk `VoiceService` first (no wake word yet), proving the "voice turn → existing agent stack → TTS result" loop end-to-end using the mic button as the trigger. This de-risks the agent-integration piece independently of the much harder wake-word/background piece.
- **Phase 3 — Wake-word engine spike**: prototype Tier 1 (curated, Porcupine-or-equivalent) detection in a minimal Kotlin harness, measure real battery/CPU on target hardware, and only then decide the final engine/tiering choice from Section 8 with data instead of assumptions.
- **Phase 4 — First-run onboarding**: build the Assistant Identity, Voice Test, and Readiness Check steps (Section 11), wired to the (by-now-proven) wake-word config and voice controller.
- **Phase 5 — Android background service**: build the actual foreground service, resolve the background-Flutter-engine-vs-native-first architecture question (Section 22, risk 2), wire wake detection into `VoiceConversationController`.
- **Phase 6 — Speech-to-text integration for continuous/dictation mode**: extend `VoiceService` beyond today's single-shot `ListenMode.confirmation`.
- **Phase 7 — Agent integration hardening**: voice-originated response-style hints, progress narration via `TaskExecutor.onProgress`, destructive-action confirmation guard (Section 19) for SMS/calls triggered by voice.
- **Phase 8 — Text-to-speech completion**: ensure all response paths (not just plain chat) are spoken; voice/rate/pitch settings UI.
- **Phase 9 — Android assistant integration (optional/additive)**: `VoiceInteractionService`/`ROLE_ASSISTANT`, explicitly scoped as non-blocking for core Definition of Done.
- **Phase 10 — Settings**: full Settings UI for everything landed in Phases 1–9 (Section 9's Settings card, plus voice/battery/privacy cards).
- **Phase 11 — Privacy/security pass**: user-visible Privacy settings card (Section 16.2), audit logging for transcript/secret leakage, review destructive-action guardrails end-to-end.
- **Phase 12 — Testing**: fill in the unit/instrumentation/E2E suites from Section 18 comprehensively (some tests will have already been written incrementally in earlier phases per their own risk-driven needs — this phase closes remaining gaps and runs the full E2E matrix).
- **Phase 13 — Performance optimization**: battery/CPU tuning informed by Phase 3's spike data plus full-system measurements now that everything is integrated.
- **Phase 14 — Release configuration**: real signing config, version bump, manifest/permission final review (Section 20).
- **Phase 15 — Colab/colab-cli APK build**: execute the Section 21 sequence for real.
- **Phase 16 — Real-device validation**: full manual E2E pass (Section 18.3/18.4) against the actual signed release APK before considering the project done.
