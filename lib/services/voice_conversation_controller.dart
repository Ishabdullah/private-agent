import 'dart:async';

import '../models/agent_action.dart';
import 'action_handler.dart';
import 'ai_service.dart';
import 'voice_service.dart';

enum VoiceConversationState {
  idle,
  woken,
  listening,
  transcribing,
  thinking,
  speaking,
  continuingConversation,
  confirming,
}

/// Orchestrates a voice turn: capture speech → send to the existing agent
/// stack (`AiService`/`ActionHandler`, unchanged) → speak the result.
///
/// This is glue, not a second agent — it never talks to the LLM, the
/// accessibility service, or app launching directly. Phase 2 wires this up
/// against the existing push-to-talk `VoiceService` (no wake word yet); a
/// wake-word engine (Phase 3+) will call [startTurn] the same way a manual
/// mic-button tap does today.
class VoiceConversationController {
  final AiService aiService;
  final ActionHandler actionHandler;
  final VoiceService voiceService;

  /// Called whenever the state machine transitions, for UI/observability.
  final void Function(VoiceConversationState state)? onStateChanged;

  /// Called with the user's recognized transcript as soon as it's final,
  /// before the request is sent to the LLM — lets a caller render it as a
  /// chat bubble immediately instead of waiting for the whole turn.
  final void Function(String transcript)? onTranscript;

  /// Called with interim (non-final) transcript text while the user is still
  /// speaking, in [VoiceListenMode.dictation] turns only — lets a caller show
  /// live transcription. Never called for [VoiceListenMode.confirmation].
  final void Function(String partialTranscript)? onPartialTranscript;

  /// Called with the final spoken response text of a turn (after any action
  /// has run), so a caller can also render it as text if desired.
  final void Function(String response, {required bool success})? onResponse;

  /// Called with every `TaskExecutor`/`ActionHandler` progress message, for
  /// UI text rendering — same unfiltered stream the chat UI already shows.
  /// A separate, throttled subset of these is also spoken aloud via TTS at
  /// sensible checkpoints (see `_maybeNarrateProgress`), not verbatim.
  final void Function(String message)? onProgress;

  /// How long to wait for a transcript before giving up and returning to
  /// Idle. `VoiceService` doesn't surface mic-permission/init failures as an
  /// error callback, so this is the safety net that prevents a silent hang.
  final Duration initialListenTimeout;

  /// Bounded window for a follow-up turn (no wake word required) after the
  /// assistant asks what looks like a clarifying question.
  final Duration followUpListenTimeout;

  VoiceConversationController({
    required this.aiService,
    required this.actionHandler,
    required this.voiceService,
    this.onStateChanged,
    this.onTranscript,
    this.onPartialTranscript,
    this.onResponse,
    this.onProgress,
    this.initialListenTimeout = const Duration(seconds: 20),
    this.followUpListenTimeout = const Duration(seconds: 10),
  });

  /// Actions considered risky enough to confirm before running when
  /// triggered by voice — a misheard/mistranscribed word is a more likely
  /// source of an unintended send/call than a deliberate typed message or
  /// mic-button tap (plan Section 19).
  static const Set<String> _destructiveVoiceActions = {'send_sms', 'make_call'};

  VoiceConversationState _state = VoiceConversationState.idle;
  VoiceConversationState get state => _state;

  bool _cancelled = false;
  VoiceListenMode _activeMode = VoiceListenMode.confirmation;

  // Progress-narration throttling state for the current turn — reset in
  // startTurn(). See _maybeNarrateProgress for the "sensible checkpoints,
  // not every step" policy (plan Section 12).
  bool _progressStartAnnounced = false;
  int _progressStepsSeen = 0;
  static const int _narrateEveryNSteps = 4;

  void _setState(VoiceConversationState next) {
    _state = next;
    onStateChanged?.call(next);
  }

  /// Starts a voice turn. No-op if a turn is already in progress.
  ///
  /// [mode] defaults to [VoiceListenMode.confirmation] (the existing
  /// push-to-talk behavior). Wake-word-triggered turns should pass
  /// [VoiceListenMode.dictation] for longer, conversational captures with
  /// live partial transcription via [onPartialTranscript].
  Future<void> startTurn({VoiceListenMode mode = VoiceListenMode.confirmation}) async {
    if (_state != VoiceConversationState.idle &&
        _state != VoiceConversationState.continuingConversation) {
      return;
    }
    _cancelled = false;
    _activeMode = mode;
    _progressStartAnnounced = false;
    _progressStepsSeen = 0;
    _setState(VoiceConversationState.woken);
    await _listenAndRespond(timeout: initialListenTimeout);
  }

  /// Cancels the current turn and returns to Idle.
  void cancel() {
    _cancelled = true;
    voiceService.stopListening();
    voiceService.stopSpeaking();
    _setState(VoiceConversationState.idle);
  }

  Future<void> _listenAndRespond({required Duration timeout}) async {
    _setState(VoiceConversationState.listening);
    final transcript = await _captureTranscript(timeout: timeout);
    if (_cancelled) return;

    if (transcript == null || transcript.trim().isEmpty) {
      _setState(VoiceConversationState.idle);
      return;
    }

    _setState(VoiceConversationState.transcribing);
    onTranscript?.call(transcript.trim());
    _setState(VoiceConversationState.thinking);

    String spokenResponse;
    bool success = true;
    bool followUpLikely = false;

    try {
      final accumulated = StringBuffer();
      await for (final chunk in aiService.sendMessageStream(
        transcript,
        isAgentMode: true,
        voiceResponseStyle: true,
      )) {
        accumulated.write(chunk);
      }
      final text = accumulated.toString();

      final AgentAction? action = aiService.parseAction(text);
      if (action != null) {
        bool proceed = true;
        if (_destructiveVoiceActions.contains(action.action)) {
          proceed = await _confirmDestructiveAction(action);
          if (_cancelled) return;
          _setState(VoiceConversationState.thinking);
        }

        if (!proceed) {
          success = true;
          spokenResponse = "Okay, I won't do that.";
        } else {
          final result = await actionHandler.execute(
            action,
            aiService: aiService,
            onProgress: _handleProgress,
          );
          success = result.success;
          spokenResponse = action.response.isNotEmpty
              ? action.response
              : (result.details ?? (success ? 'Done.' : 'Something went wrong.'));
          if (!success && result.details != null && action.response.isNotEmpty) {
            spokenResponse = '${action.response}. ${result.details}';
          }
        }
      } else {
        spokenResponse = text.trim().isEmpty
            ? "Sorry, I didn't get a response."
            : text.trim();
        followUpLikely = spokenResponse.endsWith('?');
      }
    } catch (e) {
      success = false;
      spokenResponse = 'Sorry, I ran into a problem: ${_describeError(e)}';
    }

    if (_cancelled) return;

    onResponse?.call(spokenResponse, success: success);
    _setState(VoiceConversationState.speaking);
    await voiceService.speak(spokenResponse);
    if (_cancelled) return;

    if (followUpLikely) {
      _setState(VoiceConversationState.continuingConversation);
      await _listenAndRespond(timeout: followUpListenTimeout);
    } else {
      _setState(VoiceConversationState.idle);
    }
  }

  /// Speaks a confirmation prompt for a risky action and listens for a
  /// yes/no reply. Returns `false` (safe default) on timeout, cancellation,
  /// or anything that doesn't read as an affirmative.
  Future<bool> _confirmDestructiveAction(AgentAction action) async {
    _setState(VoiceConversationState.confirming);
    final description = action.response.trim();
    final prompt = description.isNotEmpty
        ? '$description. Say yes to confirm, or no to cancel.'
        : 'Are you sure? Say yes to confirm, or no to cancel.';
    await voiceService.speak(prompt);
    if (_cancelled) return false;

    final reply = await _captureTranscript(
      timeout: followUpListenTimeout,
      mode: VoiceListenMode.confirmation,
    );
    if (_cancelled) return false;
    return _isAffirmative(reply);
  }

  static const List<String> _affirmativeWords = [
    'yes', 'yeah', 'yep', 'yup', 'confirm', 'confirmed', 'sure', 'go ahead', 'do it', 'ok', 'okay',
  ];

  bool _isAffirmative(String? text) {
    if (text == null || text.trim().isEmpty) return false;
    final normalized = ' ${text.toLowerCase().trim()} ';
    return _affirmativeWords.any((word) => normalized.contains(' $word '));
  }

  /// Forwards every progress message to [onProgress] (unfiltered, for UI
  /// text rendering) and separately decides whether this particular message
  /// is worth speaking aloud.
  void _handleProgress(String message) {
    onProgress?.call(message);
    _maybeNarrateProgress(message);
  }

  /// Speaks a small number of "still working" checkpoints during a
  /// multi-step task instead of every `onProgress` message — narrating all
  /// of `TaskExecutor`'s per-step output (clicks, retries, recovery
  /// attempts) verbatim would be unusable over TTS (plan Section 12).
  /// Terminal messages (complete/cancelled/stuck) are skipped here since the
  /// turn's own final result is already spoken separately.
  void _maybeNarrateProgress(String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    final lower = trimmed.toLowerCase();

    if (lower.startsWith('task complete') ||
        lower.startsWith('task cancelled') ||
        lower.contains('reached maximum steps') ||
        lower.contains('stuck')) {
      return;
    }

    if (!_progressStartAnnounced && lower.startsWith('starting task')) {
      _progressStartAnnounced = true;
      unawaited(voiceService.speak('On it.'));
      return;
    }

    if (!RegExp(r'^step \d+:', caseSensitive: false).hasMatch(trimmed)) {
      return; // only step checkpoints are candidates — skip retry/recovery noise
    }
    _progressStepsSeen++;
    if (_progressStepsSeen % _narrateEveryNSteps == 0) {
      unawaited(voiceService.speak('Still working, step $_progressStepsSeen.'));
    }
  }

  Future<String?> _captureTranscript({
    required Duration timeout,
    VoiceListenMode? mode,
  }) async {
    final completer = Completer<String?>();
    String latestPartial = '';

    try {
      await voiceService.startListening(
        mode: mode ?? _activeMode,
        onResult: (text) {
          if (!completer.isCompleted) completer.complete(text);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(null);
        },
        onPartialResult: (text) {
          latestPartial = text;
          onPartialTranscript?.call(text);
        },
      );
    } catch (_) {
      if (!completer.isCompleted) completer.complete(null);
    }

    return completer.future.timeout(
      timeout,
      onTimeout: () async {
        await voiceService.stopListening();
        // Dictation mode may not have emitted a `finalResult` by the
        // timeout (e.g. the user kept talking past pauseFor without ever
        // going fully silent) — fall back to the latest partial rather than
        // discarding a perfectly good transcript.
        return latestPartial.trim().isNotEmpty ? latestPartial : null;
      },
    );
  }

  String _describeError(Object e) {
    final msg = e.toString().replaceFirst('Exception: ', '');
    return msg.length > 160 ? '${msg.substring(0, 160)}...' : msg;
  }
}
