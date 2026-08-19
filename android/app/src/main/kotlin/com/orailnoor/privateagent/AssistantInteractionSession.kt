package com.orailnoor.privateagent

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.view.View
import android.widget.TextView
import org.json.JSONObject

/**
 * Handles the OS invoking PrivateAgent as the system assistant (long-press
 * home / assistant gesture), once the user has selected it via the
 * `RoleManager.ROLE_ASSISTANT` request flow in Settings. Shows a brief
 * "active" status view (this is deliberately what other assistant apps
 * show too -- the `VoiceInteractionSession`'s own content view, not their
 * regular app screen), then hands off to [MainActivity] via
 * [startVoiceActivity] (the API this base class provides specifically for
 * launching an activity tied to the session's lifecycle -- it adds
 * `FLAG_ACTIVITY_NEW_TASK` and `CATEGORY_VOICE` for us) with
 * [ACTION_ASSISTANT_INTERACTION]. This mirrors the wake-word handoff
 * `VoiceAssistantForegroundService`/`MainActivity` already established:
 * `home_screen.dart`'s existing wake-word handler drives the resulting
 * voice turn, so the assistant gesture is a second trigger for the same
 * pipeline, not a new one (plan doc Section 7's "reuse, don't rewrite"
 * decision).
 *
 * IMPORTANT (revision history, kept for context since this took two real
 * device-testing rounds to get right):
 *
 * v1 called [hide] immediately after [startVoiceActivity] in [onShow].
 * [startVoiceActivity] is asynchronous -- it requests the activity start
 * from the system server but does not block until it actually appears --
 * so this raced and tore the session down before the launched activity
 * ever got a chance to display. Device symptom: selecting PrivateAgent as
 * the assistant did nothing when invoked.
 *
 * v2 moved the [hide] call to [onTaskStarted] (a real lifecycle callback
 * documented as firing once the launched task has actually started) with a
 * 4-second timer-based fallback [hide] in case `onTaskStarted` never fired
 * on some OEM. Device symptom, confirmed via `adb logcat` on the user's
 * physical Samsung device: `onTaskStarted` never fired within the 4-second
 * window on this device, so the fallback fired instead -- and calling
 * `hide()` on the session while its launched task was still the active
 * "IS_VOICE_INTERACTION" task closed the **entire launched task**, not
 * just the session's own small overlay. The app had already launched
 * successfully and started listening (confirmed in logcat: Flutter fully
 * drawn, `speech_to_text` had started an STT session) when it was abruptly
 * closed a few seconds in -- this read as "the app crashed" from the
 * outside, though there was no exception anywhere in the log.
 *
 * v3 (current): don't call [hide] proactively at all, from any timer or
 * callback. [VoiceInteractionSession]'s own base-class default
 * `onTaskFinished` implementation already calls `hide()` automatically --
 * but only when the *user* finishes the last activity of the launched
 * task (i.e. actually closes/backs out of PrivateAgent), which is the
 * correct trigger. Nothing in this class needs to guess when that should
 * happen.
 */
class AssistantInteractionSession(context: Context) : VoiceInteractionSession(context) {

    companion object {
        const val ACTION_ASSISTANT_INTERACTION =
            "com.orailnoor.privateagent.action.ASSISTANT_INTERACTION"
        const val EXTRA_ASSISTANT_NAME = "assistant_name"
    }

    override fun onCreateContentView(): View {
        val view = TextView(context)
        view.text = "PrivateAgent is listening..."
        view.textSize = 16f
        view.setPadding(64, 96, 64, 96)
        return view
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        val intent = Intent(context, MainActivity::class.java)
            .setAction(ACTION_ASSISTANT_INTERACTION)
            .putExtra(EXTRA_ASSISTANT_NAME, readConfiguredAssistantName())
        startVoiceActivity(intent)
    }

    /** Same `flutter.wake_word_config` prefs blob
     * `VoiceAssistantForegroundService.readConfiguredKeyword()` already
     * reads -- kept independent rather than shared to avoid coupling this
     * session (no audio loop of its own) to that service's lifecycle. */
    private fun readConfiguredAssistantName(): String? {
        val prefs: SharedPreferences = context.getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE,
        )
        val raw = prefs.getString("flutter.wake_word_config", null) ?: return null
        return try {
            val name = JSONObject(raw).optString("assistant_name", "")
            name.ifBlank { null }
        } catch (e: Exception) {
            null
        }
    }
}
