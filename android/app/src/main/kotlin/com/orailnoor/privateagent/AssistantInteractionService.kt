package com.orailnoor.privateagent

import android.service.voice.VoiceInteractionService

/**
 * The always-resident top-level voice interaction service Android requires
 * to make this app selectable as the system's Digital Assistant app
 * (Settings -> Apps -> Default apps -> Digital assistant app). Kept
 * deliberately empty per the platform's own guidance in
 * `VoiceInteractionService`'s docs -- it is "kept always running by the
 * system" so should stay lightweight; the actual work only happens once the
 * assistant gesture is invoked, in [AssistantInteractionSessionService] /
 * [AssistantInteractionSession]. See
 * `AssistantPassthroughRecognitionService` for the required (but not
 * exercised by this app's own voice pipeline) RecognitionService companion
 * Android's `VoiceInteractionServiceInfo` parser mandates.
 */
class AssistantInteractionService : VoiceInteractionService()
