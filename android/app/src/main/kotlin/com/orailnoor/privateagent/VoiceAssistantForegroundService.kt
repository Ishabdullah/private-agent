package com.orailnoor.privateagent

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.KeywordSpotter
import com.k2fsa.sherpa.onnx.KeywordSpotterConfig
import com.k2fsa.sherpa.onnx.OnlineModelConfig
import com.k2fsa.sherpa.onnx.OnlineStream
import com.k2fsa.sherpa.onnx.OnlineTransducerModelConfig
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * Foreground service owning the always-on wake-word listening lifecycle.
 * Phase 5a proved the service shell (start/stop/notification/survives
 * backgrounding); Phase 5b (this) adds the actual sherpa-onnx
 * KeywordSpotter audio loop and the wake -> Dart handoff.
 *
 * Only the 5 names in [KNOWN_KEYWORDS] have wake-word support — see
 * `WakeWordSettingsService.presetNames` and plan doc Section 8.3.2/Phase 5b
 * decision log for why arbitrary typed names aren't supported: sherpa-onnx
 * requires each keyword pre-tokenized into the model's BPE pieces offline,
 * there is no on-device tokenizer. Each value below was generated once via
 * `text2token` against `assets/kws/bpe.model` — see
 * docs/ANDROID_DIGITAL_ASSISTANT_PROGRESS.md to regenerate if this list
 * changes.
 */
class VoiceAssistantForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "voice_assistant_listening"
        const val NOTIFICATION_ID = 4201
        const val ACTION_START = "com.orailnoor.privateagent.action.START_VOICE_ASSISTANT"
        const val ACTION_STOP = "com.orailnoor.privateagent.action.STOP_VOICE_ASSISTANT"
        const val ACTION_WAKE_DETECTED = "com.orailnoor.privateagent.action.WAKE_WORD_DETECTED"
        const val EXTRA_ASSISTANT_NAME = "assistant_name"

        private const val ASSETS_DIR = "flutter_assets/assets/kws"
        private const val SAMPLE_RATE = 16000

        val KNOWN_KEYWORDS = mapOf(
            "AIGENTIK" to "▁HE Y ▁A IG ENT I K",
            "NOVA" to "▁HE Y ▁NO V A",
            "CODEY" to "▁HE Y ▁CO DE Y",
            "JUNO" to "▁HE Y ▁JU N O",
            "MILO" to "▁HE Y ▁MI LO",
        )

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var kws: KeywordSpotter? = null
    private var stream: OnlineStream? = null
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null

    @Volatile
    private var isSpotting: Boolean = false

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSpotting()
                stopSelf()
            }
            else -> startListening()
        }
        // Deliberately NOT START_STICKY: if this crashes or fails to start
        // (e.g. RECORD_AUDIO revoked after the toggle was enabled), letting
        // Android auto-restart it would immediately hit the same failure
        // again, forever — a crash loop that can make the whole app appear
        // to "not open." Dart explicitly calls start()/resumeListening()
        // whenever it actually wants the service running, so nothing here
        // needs OS-level restart-on-kill.
        return START_NOT_STICKY
    }

    private fun startListening() {
        if (androidx.core.content.ContextCompat.checkSelfPermission(
                this,
                android.Manifest.permission.RECORD_AUDIO,
            ) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            android.util.Log.e(
                "VoiceAssistant",
                "RECORD_AUDIO not granted, refusing to start foreground service",
            )
            stopSelf()
            return
        }

        try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            isRunning = true
            startSpotting()
        } catch (e: Throwable) {
            // Throwable, not Exception: a missing/mismatched native library
            // for this device's ABI throws UnsatisfiedLinkError (an Error,
            // not an Exception) the first time KeywordSpotter is touched —
            // must be caught here too or it crashes the whole process.
            android.util.Log.e("VoiceAssistant", "Failed to start foreground service", e)
            stopSelf()
        }
    }

    /** Looks up the configured wake phrase from Dart's `WakeWordConfig`,
     * persisted by `shared_preferences` under the `flutter.` key prefix. */
    private fun readConfiguredKeyword(): Pair<String, String>? {
        val prefs: SharedPreferences = getSharedPreferences(
            "FlutterSharedPreferences",
            MODE_PRIVATE,
        )
        val raw = prefs.getString("flutter.wake_word_config", null) ?: return null
        return try {
            val json = JSONObject(raw)
            if (!json.optBoolean("enabled", false)) return null
            val name = json.optString("assistant_name", "").uppercase()
            val tokens = KNOWN_KEYWORDS[name] ?: return null
            name to tokens
        } catch (e: Exception) {
            android.util.Log.e("VoiceAssistant", "Failed to parse wake_word_config", e)
            null
        }
    }

    private fun startSpotting() {
        if (isSpotting) return
        val (name, tokens) = readConfiguredKeyword() ?: run {
            android.util.Log.w(
                "VoiceAssistant",
                "No supported wake word configured, not starting KWS loop",
            )
            return
        }

        try {
            if (kws == null) {
                kws = loadKeywordSpotter()
            }
            val spotter = kws ?: return
            stream = spotter.createStream(tokens)
            if (stream?.ptr == 0L) {
                android.util.Log.e("VoiceAssistant", "Failed to create KWS stream for $name")
                return
            }

            val minBufferSize = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBufferSize * 2,
            )
            audioRecord?.startRecording()
            isSpotting = true

            recordingThread = thread(start = true) { processSamples(name) }
        } catch (e: Throwable) {
            android.util.Log.e("VoiceAssistant", "Failed to start KWS loop", e)
            stopSpotting()
        }
    }

    private fun loadKeywordSpotter(): KeywordSpotter {
        val config = KeywordSpotterConfig(
            featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
            modelConfig = OnlineModelConfig(
                transducer = OnlineTransducerModelConfig(
                    encoder = "$ASSETS_DIR/encoder.int8.onnx",
                    decoder = "$ASSETS_DIR/decoder.onnx",
                    joiner = "$ASSETS_DIR/joiner.int8.onnx",
                ),
                tokens = "$ASSETS_DIR/tokens.txt",
                modelType = "zipformer2",
                numThreads = 1,
            ),
            keywordsFile = "$ASSETS_DIR/keywords.txt",
        )
        return KeywordSpotter(assetManager = assets, config = config)
    }

    private fun processSamples(configuredName: String) {
        val interval = 0.1
        val bufferSize = (interval * SAMPLE_RATE).toInt()
        val buffer = ShortArray(bufferSize)
        val spotter = kws ?: return
        val activeStream = stream ?: return

        try {
            while (isSpotting) {
                val read = audioRecord?.read(buffer, 0, buffer.size) ?: -1
                if (read > 0) {
                    val samples = FloatArray(read) { buffer[it] / 32768.0f }
                    activeStream.acceptWaveform(samples, sampleRate = SAMPLE_RATE)
                    while (spotter.isReady(activeStream)) {
                        spotter.decode(activeStream)
                        val result = spotter.getResult(activeStream)
                        if (result.keyword.isNotBlank()) {
                            spotter.reset(activeStream)
                            onWakeWordDetected(configuredName)
                        }
                    }
                }
            }
        } catch (e: Throwable) {
            android.util.Log.e("VoiceAssistant", "KWS decode loop failed", e)
            isSpotting = false
        }
    }

    private fun onWakeWordDetected(name: String) {
        android.util.Log.i("VoiceAssistant", "Wake word detected for $name")
        stopSpotting()

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.apply {
            action = ACTION_WAKE_DETECTED
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            putExtra(EXTRA_ASSISTANT_NAME, name)
        }
        if (launchIntent != null) {
            startActivity(launchIntent)
        }
    }

    /** Stops the audio loop only — the foreground service/notification stays
     * up. Call [startSpotting] again (e.g. once a voice turn finishes) to
     * resume listening. Avoids two simultaneous microphone consumers when
     * the mic-button/VoiceConversationController path is active. */
    private fun stopSpotting() {
        isSpotting = false
        recordingThread?.join(500)
        recordingThread = null
        audioRecord?.let {
            try {
                it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        audioRecord = null
        stream?.release()
        stream = null
    }

    private fun buildNotification(): android.app.Notification {
        val contentIntent = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PrivateAgent is listening")
            .setContentText("Say your wake word to start a voice command.")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(contentIntent)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val existing = manager.getNotificationChannel(CHANNEL_ID)
        if (existing != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Voice assistant listening",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Ongoing indicator while PrivateAgent listens for its wake word."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    override fun onDestroy() {
        isRunning = false
        stopSpotting()
        kws?.release()
        kws = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
