package com.orailnoor.privateagent

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Phase 5a shell: owns the always-on-listening lifecycle as a foreground
 * service (required so Android doesn't kill wake-word listening the moment
 * the app backgrounds). Does not yet run any audio/wake-word engine — that
 * lands in Phase 5b once this shell is confirmed to start/stop/survive
 * backgrounding on a real device. See plan doc Section 7/8.3.2.
 */
class VoiceAssistantForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "voice_assistant_listening"
        const val NOTIFICATION_ID = 4201
        const val ACTION_START = "com.orailnoor.privateagent.action.START_VOICE_ASSISTANT"
        const val ACTION_STOP = "com.orailnoor.privateagent.action.STOP_VOICE_ASSISTANT"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            else -> startListening()
        }
        return START_STICKY
    }

    private fun startListening() {
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
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
