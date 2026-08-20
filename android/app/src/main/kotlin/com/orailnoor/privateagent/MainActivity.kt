package com.orailnoor.privateagent

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import android.graphics.PixelFormat
import android.graphics.Color
import android.view.Gravity
import android.view.WindowManager
import android.view.View
import android.widget.Button
import android.net.Uri

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.privateagent/accessibility"
    private val EVENT_CHANNEL = "com.privateagent/accessibility_events"
    private val VOICE_ASSISTANT_CHANNEL = "com.privateagent/voice_assistant"
    private var eventSink: EventChannel.EventSink? = null
    private var overlayView: View? = null
    private var voiceAssistantChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        handleWakeWordIntent(intent)
        handleAssistantInteractionIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleWakeWordIntent(intent)
        handleAssistantInteractionIntent(intent)
    }

    private fun handleWakeWordIntent(intent: Intent?) {
        if (intent?.action != VoiceAssistantForegroundService.ACTION_WAKE_DETECTED) return
        val name = intent.getStringExtra(VoiceAssistantForegroundService.EXTRA_ASSISTANT_NAME)
        // Posted so it runs after configureFlutterEngine has registered the
        // channel (which happens during super.onCreate() above, but the
        // engine's Dart side may not have attached its own handler yet on a
        // cold start).
        window.decorView.post {
            voiceAssistantChannel?.invokeMethod(
                "onWakeWordDetected",
                mapOf("assistantName" to name),
            )
        }
    }

    /** Phase 9: the OS invoked PrivateAgent as the system assistant (long
     * -press home / assistant gesture) via [AssistantInteractionSession].
     * Dart's `_onWakeWordDetected` handler is reused for this exact same
     * "start a voice turn" behavior -- see
     * `VoiceAssistantForegroundService.onAssistantGestureInvoked`. */
    private fun handleAssistantInteractionIntent(intent: Intent?) {
        if (intent?.action != AssistantInteractionSession.ACTION_ASSISTANT_INTERACTION) return
        val name = intent.getStringExtra(AssistantInteractionSession.EXTRA_ASSISTANT_NAME)
        window.decorView.post {
            voiceAssistantChannel?.invokeMethod(
                "onAssistantGestureInvoked",
                mapOf("assistantName" to name),
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    AgentAccessibilityService.eventListener = { eventMap ->
                        runOnUiThread {
                            eventSink?.success(eventMap)
                        }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    AgentAccessibilityService.eventListener = null
                }
            }
        )

        registerAccessibilityChannel(flutterEngine, this)
        registerVoiceAssistantChannel(flutterEngine, this)
    }

    private fun registerVoiceAssistantChannel(flutterEngine: FlutterEngine, activity: MainActivity) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOICE_ASSISTANT_CHANNEL)
        voiceAssistantChannel = channel
        channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startListening" -> {
                        val intent = Intent(activity, VoiceAssistantForegroundService::class.java)
                            .setAction(VoiceAssistantForegroundService.ACTION_START)
                        androidx.core.content.ContextCompat.startForegroundService(activity, intent)
                        result.success(true)
                    }

                    "stopListening" -> {
                        val intent = Intent(activity, VoiceAssistantForegroundService::class.java)
                            .setAction(VoiceAssistantForegroundService.ACTION_STOP)
                        activity.startService(intent)
                        result.success(true)
                    }

                    "isListening" -> result.success(VoiceAssistantForegroundService.isRunning)

                    "resumeListening" -> {
                        val intent = Intent(activity, VoiceAssistantForegroundService::class.java)
                            .setAction(VoiceAssistantForegroundService.ACTION_START)
                        androidx.core.content.ContextCompat.startForegroundService(activity, intent)
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        fun registerAccessibilityChannel(flutterEngine: FlutterEngine, context: android.content.Context) {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.privateagent/accessibility")
                .setMethodCallHandler { call, result ->
                    android.util.Log.d("PrivateAgentKotlin", "Received method call: ${call.method}")
                    when (call.method) {
                        "ping" -> result.success(true)

                        "logToNative" -> {
                            val msg = call.argument<String>("message") ?: ""
                            android.util.Log.d("PrivateAgentDart", msg)
                            result.success(true)
                        }

                        "isServiceRunning" -> {
                            result.success(AgentAccessibilityService.isRunning())
                        }

                        // TaskExecutor checks this before starting a
                        // multi-step task: the accessibility service can't
                        // meaningfully read or interact with a locked
                        // screen, and previously just failed silently/
                        // confusingly instead of telling the user to
                        // unlock (device-reported gap, 2026-08-20).
                        "isScreenLocked" -> {
                            val keyguardManager = context.getSystemService(
                                android.app.KeyguardManager::class.java,
                            )
                            result.success(keyguardManager?.isKeyguardLocked ?: false)
                        }

                        "checkOverlayPermission" -> {
                            result.success(Settings.canDrawOverlays(context))
                        }

                        "requestOverlayPermission" -> {
                            val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}"))
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            context.startActivity(intent)
                            result.success(true)
                        }

                        "showMacroOverlay" -> {
                            // Macro overlay requires an Activity context, so we just ignore or return error if called from background
                            result.error("NOT_SUPPORTED", "Macro overlay not supported from background", null)
                        }

                        "hideMacroOverlay" -> {
                            result.success(true)
                        }

                        "openAccessibilitySettings" -> {
                            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            context.startActivity(intent)
                            result.success(true)
                        }

                        "dumpScreen" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                val nodes = service.dumpScreen()
                                result.success(nodes)
                            }
                        }

                        "takeScreenshot" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                                    service.takeScreenshot { base64 ->
                                        if (base64 != null) {
                                            result.success(base64)
                                        } else {
                                            result.error("SCREENSHOT_FAILED", "Failed to capture screenshot", null)
                                        }
                                    }
                                } else {
                                    result.error("UNSUPPORTED_VERSION", "Screenshot requires Android 11 (API 30) or higher", null)
                                }
                            }
                        }

                        "clickByText" -> {
                            val text = call.argument<String>("text") ?: ""
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.clickByText(text))
                            }
                        }

                        "clickAt" -> {
                            val x = call.argument<Double>("x")?.toFloat() ?: 0f
                            val y = call.argument<Double>("y")?.toFloat() ?: 0f
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.clickAtCoordinates(x, y))
                            }
                        }

                        "typeText" -> {
                            val text = call.argument<String>("text") ?: ""
                            val hint = call.argument<String>("fieldHint")
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.typeText(text, hint))
                            }
                        }

                        "pressEnter" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.pressEnter())
                            }
                        }

                        "scroll" -> {
                            val direction = call.argument<String>("direction") ?: "down"
                            val target = call.argument<String>("target")
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.scroll(direction, target))
                            }
                        }

                        "showToast" -> {
                            val message = call.argument<String>("message") ?: ""
                            android.widget.Toast.makeText(context, message, android.widget.Toast.LENGTH_SHORT).show()
                            result.success(true)
                        }

                        "swipe" -> {
                            val startX = call.argument<Double>("startX")?.toFloat() ?: 0f
                            val startY = call.argument<Double>("startY")?.toFloat() ?: 0f
                            val endX = call.argument<Double>("endX")?.toFloat() ?: 0f
                            val endY = call.argument<Double>("endY")?.toFloat() ?: 0f
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.swipe(startX, startY, endX, endY))
                            }
                        }

                        "pressBack" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.pressBack())
                            }
                        }

                        "pressHome" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.pressHome())
                            }
                        }

                        "openNotifications" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.openNotifications())
                            }
                        }

                        "getCurrentPackage" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.getCurrentPackage())
                            }
                        }

                        // Phase 9 (optional/additive): whether this device
                        // even exposes ROLE_ASSISTANT at all (API 29+ and
                        // not blocked by the OEM) -- lets Settings hide the
                        // "Make PrivateAgent your Assistant" card entirely
                        // rather than showing a button that would silently
                        // no-op.
                        "isAssistantRoleAvailable" -> {
                            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                                val roleManager = context.getSystemService(
                                    android.app.role.RoleManager::class.java,
                                )
                                result.success(
                                    roleManager?.isRoleAvailable(
                                        android.app.role.RoleManager.ROLE_ASSISTANT,
                                    ) ?: false,
                                )
                            } else {
                                result.success(false)
                            }
                        }

                        // Phase 9 (optional/additive): whether PrivateAgent
                        // is currently the OS-selected Digital Assistant
                        // app. RoleManager only exists on API 29+.
                        "isDefaultAssistant" -> {
                            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                                val roleManager = context.getSystemService(
                                    android.app.role.RoleManager::class.java,
                                )
                                result.success(
                                    roleManager?.isRoleHeld(
                                        android.app.role.RoleManager.ROLE_ASSISTANT,
                                    ) ?: false,
                                )
                            } else {
                                result.success(false)
                            }
                        }

                        // Opens the system's "pick your assistant app"
                        // flow. Fire-and-forget by design (mirrors
                        // requestOverlayPermission above) -- Dart re-checks
                        // via isDefaultAssistant when Settings resumes,
                        // same pattern used for every other permission in
                        // this app.
                        "requestAssistantRole" -> {
                            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                                val roleManager = context.getSystemService(
                                    android.app.role.RoleManager::class.java,
                                )
                                if (roleManager != null &&
                                    roleManager.isRoleAvailable(
                                        android.app.role.RoleManager.ROLE_ASSISTANT,
                                    )
                                ) {
                                    val intent = roleManager.createRequestRoleIntent(
                                        android.app.role.RoleManager.ROLE_ASSISTANT,
                                    )
                                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    context.startActivity(intent)
                                    result.success(true)
                                } else {
                                    result.success(false)
                                }
                            } else {
                                result.success(false)
                            }
                        }

                        else -> result.notImplemented()
                    }
                }
        }
    }
}

class BackgroundEngineReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: android.content.Context, intent: android.content.Intent) {
        val engine = io.flutter.embedding.engine.FlutterEngineCache
            .getInstance()
            .get("myCachedEngine")
        if (engine == null) {
            android.util.Log.e("PrivateAgent", "Background engine myCachedEngine was not found")
            return
        }

        android.util.Log.d(
            "PrivateAgent",
            "Registering accessibility channel on myCachedEngine " +
                "(engine=${System.identityHashCode(engine)}, " +
                "dartExecuting=${engine.dartExecutor.isExecutingDart})"
        )
        MainActivity.registerAccessibilityChannel(engine, context.applicationContext)
    }
}
