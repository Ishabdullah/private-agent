package com.orailnoor.privateagent

import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService

/** Instantiates a fresh [AssistantInteractionSession] each time the OS
 * invokes the assistant gesture (long-press home, etc). */
class AssistantInteractionSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession {
        return AssistantInteractionSession(this)
    }
}
