package com.orailnoor.privateagent

import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.SpeechRecognizer

/**
 * A required-but-not-actually-exercised `RecognitionService`. Reading
 * AOSP's `VoiceInteractionServiceInfo` parser directly (the class Android
 * uses to validate a `VoiceInteractionService` before allowing it to be
 * selected as the system assistant) confirmed there is no "assist-only, no
 * recognizer" mode: a `recognitionService` component is hard-required or
 * the whole app is rejected as assistant-capable. This class exists purely
 * to satisfy that requirement -- it delegates every call to the device's
 * actual default speech recognizer (explicitly never itself, to avoid
 * recursion) rather than reimplementing STT. PrivateAgent's own voice turns
 * (mic button, wake word, and the assistant gesture handled by
 * [AssistantInteractionSession]) all go through the existing
 * `speech_to_text` Flutter plugin, not this class -- it is a passthrough
 * safety net in case anything else on the device ever targets it directly.
 */
class AssistantPassthroughRecognitionService : RecognitionService() {

    private var delegate: SpeechRecognizer? = null

    override fun onStartListening(recognizerIntent: Intent, listener: Callback) {
        val target = findDelegateComponent()
        if (target == null) {
            runCatching { listener.error(SpeechRecognizer.ERROR_RECOGNIZER_BUSY) }
            return
        }

        val recognizer = SpeechRecognizer.createSpeechRecognizer(this, target)
        delegate = recognizer
        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                runCatching { listener.readyForSpeech(params ?: Bundle()) }
            }

            override fun onBeginningOfSpeech() {
                runCatching { listener.beginningOfSpeech() }
            }

            override fun onRmsChanged(rmsdB: Float) {
                runCatching { listener.rmsChanged(rmsdB) }
            }

            override fun onBufferReceived(buffer: ByteArray?) {
                runCatching { listener.bufferReceived(buffer ?: ByteArray(0)) }
            }

            override fun onEndOfSpeech() {
                runCatching { listener.endOfSpeech() }
            }

            override fun onError(error: Int) {
                runCatching { listener.error(error) }
            }

            override fun onResults(results: Bundle?) {
                runCatching { listener.results(results ?: Bundle()) }
            }

            override fun onPartialResults(partialResults: Bundle?) {
                runCatching { listener.partialResults(partialResults ?: Bundle()) }
            }

            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        recognizer.startListening(recognizerIntent)
    }

    override fun onStopListening(listener: Callback) {
        delegate?.stopListening()
    }

    override fun onCancel(listener: Callback) {
        delegate?.cancel()
        delegate?.destroy()
        delegate = null
    }

    override fun onDestroy() {
        delegate?.destroy()
        delegate = null
        super.onDestroy()
    }

    /** Finds another app's recognition-service component -- never our own,
     * to avoid infinitely delegating to ourselves -- via the same intent
     * action AndroidManifest.xml's `<queries>` block already declares
     * visibility for (needed for `speech_to_text`'s own availability
     * check, so no new manifest entry was required here). */
    private fun findDelegateComponent(): ComponentName? {
        val intent = Intent(RecognitionService.SERVICE_INTERFACE)
        val matches = packageManager.queryIntentServices(intent, 0)
        val match = matches.firstOrNull { it.serviceInfo.packageName != packageName }
            ?: return null
        return ComponentName(match.serviceInfo.packageName, match.serviceInfo.name)
    }
}
