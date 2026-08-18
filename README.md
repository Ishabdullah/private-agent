# PrivateAgent

PrivateAgent is an open-source Android automation agent built with Flutter. It utilizes the DeepSeek API and native Android Accessibility Services to interpret screen layouts and execute multi-step tasks across any installed application via natural language commands.

This is a fork of [orailnoor/private-agent](https://github.com/orailnoor/private-agent) — all credit for the original app goes to that project. This fork continues active development, including a wake-word-activated voice assistant feature (in progress).

## Architecture

The system operates on a continuous feedback loop:
1. The user issues a command (via voice, text, or Telegram remote access).
2. The agent captures the current screen hierarchy, calculating the exact spatial coordinates of all interactive elements.
3. The layout data is transmitted to the AI provider alongside the current task context and the result of the previous action.
4. The AI determines the next optimal action (e.g., clicking specific coordinates, inputting text, scrolling).
5. The native Android layer executes the action.
6. The loop repeats until the task is marked as complete.

## Capabilities

- **Screen Reading:** Parses the Android UI tree to map clickable, scrollable, and editable elements.
- **Coordinate-Based Interaction:** Simulates physical screen taps based on coordinate geometry, mitigating issues with missing text labels or inaccessible icons.
- **Remote Access:** Integrates with the Telegram Bot API via background polling, allowing users to issue commands and monitor task execution progress remotely.
- **Voice Control:** Native speech-to-text/text-to-speech for hands-free operation. Tap the mic, speak your request, and the agent replies out loud — action results, task-progress checkpoints, and errors are all spoken, not just plain chat replies, and risky actions (sending an SMS, making a call) ask for a spoken yes/no confirmation first. If the agent's reply sounds like a follow-up question, the mic automatically reopens for your answer without needing another tap. Voice speed, pitch, volume, and the TTS voice itself are configurable in **Settings → Spoken Responses**.
- **Wake-Word Assistant (Beta):** Say "Hey [name]" to trigger a voice command without touching the screen — fully offline, on-device keyword detection. See [Wake-word voice assistant](#wake-word-voice-assistant-beta) below for supported names and setup.

## Security & Privacy

- Your AI provider API key and Telegram bot token are stored in Android's encrypted, Keystore-backed secure storage (`flutter_secure_storage`), not plain-text preferences.
- Screen contents and voice transcripts are sent only to the AI provider/base URL you configure in Settings — nothing else leaves the device unless you enable Telegram remote control.

## Installation

Download the latest APK directly from the [Releases Page](https://github.com/Ishabdullah/private-agent/releases).

Choose `app-universal-release.apk` when it is available. It supports ARM64,
32-bit ARM, and x86_64 devices in one package. If a release only provides split
APKs, most modern Android phones—including Snapdragon devices—must use
`app-arm64-v8a-release.apk`.

PrivateAgent supports Android 8.0 (API 26) and newer. Current release builds are
also checked for Android 15/16's 16 KB native-library alignment requirement.

## Setup Instructions (How to use for FREE)

This app requires an AI brain to operate. You can use it **100% for free** by using OpenRouter's free models.

1. Install the APK on your Android device (API 30+ recommended).
2. Walk through first-run setup: pick a name for your assistant, grant the requested permissions (Accessibility, Microphone, Notifications, and — if your device allows it — a battery-optimization exemption so background features work reliably), configure your AI provider, try the voice test, and confirm the readiness check before finishing.
3. Go to [OpenRouter.ai](https://openrouter.ai/) and create a free account.
4. Generate a free API Key.
5. During setup (or later from **Settings**), tap the **"OpenRouter"** quick-select chip under Base URL.
6. Paste your API Key.
7. Type `openai/gpt-oss-120b:free` (or any other free model) into the Model field.

### Wake-word voice assistant (Beta)

You can now say **"Hey [name]"** to trigger a voice command hands-free, without tapping the mic button, as long as you pick one of these 5 names during onboarding: **Aigentik, Nova, Codey, Juno, or Milo**. Other names still work everywhere else in the app, they just don't get wake-word detection — the fully-offline detection model needs each phrase specially prepared in advance, so only these 5 are supported for now.

To enable it: go to **Settings → Voice Assistant (Beta)** and turn on "Background listening". You'll see an ongoing notification while it's listening. This is new, hasn't been validated on a wide range of devices yet, and will use more battery than having it off — turn it off any time from the same toggle if it's not working well for you.

### “Restricted setting” when enabling Screen Control

Android may block accessibility access for apps installed from an APK. This is
an operating-system safety restriction:

1. Open **Settings → Apps → PrivateAgent**.
2. Open the three-dot menu in the top-right corner.
3. Tap **Allow restricted settings** and confirm.
4. Return to PrivateAgent and open **Accessibility Settings** again.
5. Enable **PrivateAgent Screen Control**.

PrivateAgent now shows these instructions and provides shortcuts to both App
Info and Accessibility Settings during onboarding.

## Telegram Integration

To enable remote access:
1. Acquire a bot token from BotFather on Telegram.
2. Input the token in the PrivateAgent Settings screen and enable the integration toggle.
3. The application will maintain a background polling connection to the Telegram API to receive commands.

## Credits

This project is a fork of [orailnoor/private-agent](https://github.com/orailnoor/private-agent). All credit for the original app design and implementation goes to that project's author.

## License

This project is open-source and available for modification.
