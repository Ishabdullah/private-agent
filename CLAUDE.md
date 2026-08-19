# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

PrivateAgent is a Flutter Android app that automates other apps via natural-language commands. It reads the Android accessibility tree, sends the screen contents + task goal to an LLM (DeepSeek/OpenRouter/NVIDIA NIM/any OpenAI-compatible endpoint), and executes the action the LLM returns (tap, type, scroll, swipe, open app, etc.) in a loop until the task is marked complete. It also supports simple one-shot device actions (calls, SMS, alarms, volume/brightness) without the loop, voice input/output, and optional Telegram remote control.

Package name: `com.orailnoor.privateagent`. Android only (no iOS support — `ios: false` in `flutter_launcher_icons`, no `ios/` directory).

## Active initiative: Android digital-assistant / wake-word feature

There is a standing engineering plan for turning PrivateAgent into a wake-word-activated voice assistant: **`docs/ANDROID_DIGITAL_ASSISTANT_IMPLEMENTATION_PLAN.md`**. Read it before touching anything voice/wake-word/background-service related — it contains the repository audit, architecture decisions, and a 17-phase implementation order (Phase 0–16, see its "Recommended Implementation Order" section) that phases must be executed **in order**, since later phases assume earlier ones landed (e.g., the wake-word engine choice in Phase 3 is decided empirically from a spike, not assumed up front).

**Progress log**: `docs/ANDROID_DIGITAL_ASSISTANT_PROGRESS.md` tracks which phase is in progress, what's done, and exactly where work left off. Every session that works on this initiative must:
1. Read the progress log first to find the current phase and last-known state before starting anything.
2. Update the progress log before ending the session (or before running out of context) with: which phase/step is in progress, what was just completed, what the next concrete action is, and any decisions or blockers discovered along the way — so a fresh session in a new context window can resume without re-deriving state from scratch.

Do not treat the plan document as static — if implementation reveals the plan's assumptions were wrong (e.g., the background-Flutter-engine spike in Phase 5 fails), update the plan document itself, not just the progress log.

## User working preferences (durable — apply every session)

- **Handing over a build/APK**: whenever you give the user a downloadable build, always tell them explicitly what's new in it and what to actually test (the specific features/flows this build adds or changes) — not just "here's the APK." Don't make them guess from the changelog.
- **Keep `README.md` (and any other user-facing docs) up to date** as implementation progresses — this is not optional cleanup, treat it as part of finishing a unit of work whenever a change affects what's documented there (new dependencies, new features, changed commands/setup steps, etc.).
- **Durable instructions the user gives you belong in this file.** If the user tells you to remember something that should apply across sessions (a preference, a rule, a workflow), add it to `CLAUDE.md` — don't rely on chat memory alone.

## Commands

```bash
flutter pub get                 # install/resolve dependencies
flutter test                    # run all tests
flutter test test/ai_service_test.dart   # run a single test file
flutter analyze                 # lint (uses flutter_lints via analysis_options.yaml)
flutter run                     # run on a connected device/emulator
flutter build apk --release                     # universal release APK
flutter build apk --release --split-per-abi      # per-ABI release APKs (arm64-v8a, armeabi-v7a, x86_64)
```

CI (`.github/workflows/android-release.yml`) runs `flutter pub get`, `flutter test`, then builds the universal and split-per-ABI release APKs on tag pushes (`v*`) or manual dispatch. Release APKs are also checked for Android 15/16's 16 KB native-library page alignment (see README).

Minimum supported OS: Android 8.0 (API 26); API 30+ recommended for full functionality (e.g. `takeScreenshot` requires API 30+).

### No local Flutter/Android toolchain — use colab-cli

This Termux environment has no Flutter SDK, no Android SDK/Gradle, and no Java (`flutter`/`dart`/`java` are all absent from `PATH`, and the Termux package repo doesn't carry Flutter). Any command above (`flutter pub get`, `flutter test`, `flutter analyze`, `flutter build apk`, etc.) — or anything else this environment can't run directly — should be executed remotely via the **`colab-cli`** tool instead of skipped or merely eyeballed:

- Binary: `/data/data/com.termux/files/home/.venvs/colab-cli/bin/colab` (auth is already configured; default `oauth2` works — no `--auth=adc` needed here). Run `colab skill` for the full operating manual.
- Typical flow: `colab new -s <name>` (a plain **CPU** session is enough for `flutter pub get`/`test`/`analyze`/`build apk`; Flutter's Dart-VM tests and Gradle builds don't need an accelerator) → install/extract the Flutter SDK under `/content` once per session → `colab exec -s <name> -f script.py` running `subprocess` calls to drive `flutter`/`gradle` → sync this repo to `/content` (skip `build/`, `.dart_tool/`, any keystore/`key.properties`) → pull results back with `colab download`.
- **Do not request `--gpu`/`--tpu`** for this project's work (builds/tests/lint) — it's pure CPU work and accelerators burn the free compute quota for no benefit here. Only ask for one if a task genuinely needs it (there currently isn't one in this repo).
- `colab exec`'s default per-call timeout is 30s and long-running shell (`tar`, `flutter pub get`, first `flutter build apk`) will exceed it — pass `--timeout <seconds>` generously, or launch the command with `nohup ... &` inside the script and poll for completion in a follow-up `exec` call.
- **Run every `colab exec` call with the sandbox disabled** (Bash tool's `dangerouslyDisableSandbox: true`) — `colab exec` hangs indefinitely under the default sandbox (confirmed Phase 10 session: even a trivial one-line `print()` script hung past a 90s timeout with sandboxing on, then returned in under a second with it off). `colab new`/`sessions`/`upload`/`download`/`log`/`stop` all work fine sandboxed; it's specifically `exec` (likely because it opens a different connection, e.g. a websocket to the kernel) that needs this.
- **Always `colab stop -s <name>`** when the toolchain work for the session is done, so the VM doesn't sit idle burning compute units.
- If something genuinely can't be verified even via `colab-cli` (e.g. it needs a physical device/emulator, or `colab-cli` itself is unavailable/unauthenticated), say so plainly and record it as unverified in whatever log/notes the task calls for — don't silently claim it passed.

## Architecture

### The screen-automation loop (core feature)

This is the part that requires reading multiple files to understand:

1. **`lib/services/task_executor.dart`** (`TaskExecutor.executeTask`) drives the loop: read screen → ask LLM for one action → execute action natively → repeat, until the LLM returns `is_complete: true`, a hard step cap (`AiService.maxSteps`, default 15) is hit, or 5 consecutive action failures occur.
   - Before invoking the LLM at all, it checks `SkillMemoryService` for a previously-successful step sequence for a semantically similar goal and replays it directly (no LLM calls) if reliable.
   - It also has hardcoded "navigation shortcuts" (`getNavigationShortcut` in `lib/services/task_json_utils.dart`) for common goals (dark mode, wifi, bluetooth, opening well-known apps) that skip the LLM for the first step(s). That file also holds `extractTaskActionJson`, the LLM-response JSON extractor — both were pulled out of `TaskExecutor` as plain top-level functions so they're unit-testable without mocking the accessibility `MethodChannel`.
   - On action failure, `RecoveryEngine` (`lib/services/recovery_engine.dart`) diagnoses the screen and suggests a fallback (wait/scroll/press_back/press_home) before continuing the loop.
   - On success, the executed step sequence is saved back into `SkillMemoryService` for future replay.
   - The LLM's per-step system prompt (screen-reading action set: `click_text`, `click_at`, `type_text`, `press_enter`, `scroll`, `swipe`, `press_back`, `press_home`, `open_app`, `wait`, `done`) is defined inline in `TaskExecutor._taskSystemPrompt` — separate and much narrower than `AiService`'s general chat/action system prompt.

2. **`lib/services/ai_service.dart`** (`AiService`) is the HTTP client to the LLM. It's provider-agnostic (OpenAI-compatible chat completions API) — base URL, model, API key, temperature, max tokens, and max steps are all user-configurable via Settings and persisted in `SharedPreferences`. It also owns the *general* system prompt used for normal chat + single-shot device actions (distinct from the task-loop prompt above), and defines the curated NVIDIA NIM free-model allowlist.

3. **`lib/services/screen_automation_service.dart`** (`ScreenAutomationService`) is the Dart-side bridge over a `MethodChannel` (`com.privateagent/accessibility`) to the native Android accessibility service. It exposes `dumpScreen()`, `getScreenDescription()` / `getCompressedScreenDescription()`, `clickByText`/`clickAt`, `typeText`, `scroll`/`swipe`, `pressBack`/`pressHome`, `takeScreenshot`, and `logToNative` (routes Dart logs into native Logcat for on-device debugging since there's no attached debugger in production use).

4. **`android/app/src/main/kotlin/com/orailnoor/privateagent/AgentAccessibilityService.kt`** is the native `AccessibilityService` that actually walks the UI tree, computes element bounds/text, and performs gestures/clicks/typing via the Accessibility API. **`MainActivity.kt`** registers the `MethodChannel` and an `EventChannel` (`com.privateagent/accessibility_events`) that streams accessibility events back to Dart.

5. When native automation isn't available/sufficient, **`lib/services/shizuku_service.dart`** provides a Shizuku-based fallback that runs shell-level `input` commands (tap/swipe/keyevent) — used both as a fallback inside `TaskExecutor` (`_performSwipe`, `_submitKeyboardAction`) and by `RecoveryEngine`.

### Single-shot actions vs. multi-step tasks

Two distinct execution paths exist and are easy to conflate:
- **`ActionHandler`** (`lib/services/action_handler.dart`) dispatches simple one-step `AgentAction`s (open app, make call, send SMS, set alarm, set volume/brightness, read screen, etc.) returned directly by the LLM's general chat response. These don't use the step loop.
- **`TaskExecutor`** is invoked only when the goal requires the multi-step screen-reading loop (an explicit "do this multi-step thing" task, e.g. via the `execute_task` action or task history / overlay entry points). `ActionHandler` holds a reference to the current `TaskExecutor` to support cancellation.

### Other services (`lib/services/`)

- `app_launcher_service.dart` — resolves app names to packages and launches them (`installed_apps` package).
- `contacts_service.dart` / `communication_service.dart` — contact lookup, calls, SMS.
- `alarm_service.dart`, `system_control_service.dart` (volume/brightness), `notification_service.dart` — device control wrappers.
- `voice_service.dart` — speech-to-text input and TTS output.
- `telegram_service.dart` — background polling of the Telegram Bot API for remote command intake; mirrors results back to the chat.
- `chat_history_service.dart`, `task_history_logger.dart`, `skill_memory_service.dart` — all persist to local storage (`shared_preferences`/`path_provider`), not a remote backend. There is no server component to this project — everything is on-device.

### Overlay / floating chat window

`lib/overlay_main.dart` + `flutter_overlay_window` (vendored locally under `local_plugins/flutter_overlay_window` via a `dependency_overrides` path dependency, not pub.dev) implement a floating chat bubble that runs a second, minimal Flutter engine entrypoint (`overlayMain()` in `lib/main.dart`) and talks back to the main app via `FlutterOverlayWindow.overlayListener` / `onOverlayTask`. This is currently **disabled** via `FeatureFlags.floatingOverlayEnabled = false` (`lib/config/feature_flags.dart`) while the implementation is stabilized — don't assume it's reachable at runtime unless that flag is flipped.

### Local plugins

`local_plugins/` contains two Flutter plugins developed in-tree rather than pulled from pub.dev:
- `flutter_overlay_window` — floating overlay window support (see above), overridden via `dependency_overrides` in `pubspec.yaml`.
- `agent_native` — a native-channel plugin scaffold (not wired into `dependency_overrides`, check `pubspec.yaml`/imports before assuming it's active).

Each has its own `pubspec.yaml`, `analysis_options.yaml`, and test suite — treat them as independent packages when editing (their `flutter test`/`flutter analyze` should be run from within the plugin directory if working on plugin internals).

### Model layer (`lib/models/`)

- `agent_action.dart` — the `AgentAction`/`AgentActionResult` shape returned by the LLM and consumed by `ActionHandler`.
- `chat_message.dart` — chat UI message model (rendered with `flutter_markdown`).
- `saved_skill.dart` — persisted step sequence + reliability tracking used by `SkillMemoryService`/`TaskExecutor` replay.
