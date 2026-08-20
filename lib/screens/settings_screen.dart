import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../services/ai_service.dart';
import '../services/shizuku_service.dart';
import '../services/screen_automation_service.dart';
import '../services/telegram_service.dart';
import '../services/voice_assistant_foreground_service.dart';
import '../services/voice_service.dart';
import '../services/tts_settings_service.dart';
import '../services/wake_word_settings_service.dart';
import '../models/tts_settings.dart';
import '../models/wake_word_config.dart';
import 'task_history_screen.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import '../config/feature_flags.dart';

class SettingsScreen extends StatefulWidget {
  final AiService aiService;
  final ShizukuService shizukuService;
  final ScreenAutomationService screenAutomationService;
  final TelegramService telegramService;
  final VoiceService voiceService;

  const SettingsScreen({
    super.key,
    required this.aiService,
    required this.shizukuService,
    required this.screenAutomationService,
    required this.telegramService,
    required this.voiceService,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late TextEditingController _apiKeyController;
  late TextEditingController _baseUrlController;
  late TextEditingController _modelController;
  late TextEditingController _telegramTokenController;
  bool _obscureKey = true;
  bool _telegramEnabled = false;
  double _maxSteps = 15;
  bool _disableMaxSteps = false;
  late TextEditingController _maxTokensController;
  double _temperature = 1.0;
  bool _useScreenCompression = true;
  bool _useSystemPrompt = true;
  bool _floatingIconEnabled = false;
  bool _isOverlayPermissionGranted = false;
  bool _voiceAssistantListening = false;

  final TtsSettingsService _ttsSettingsService = TtsSettingsService();
  TtsSettings _ttsSettings = const TtsSettings();
  List<Map<String, String>> _availableVoices = [];
  bool _voicesLoaded = false;

  final WakeWordSettingsService _wakeWordSettingsService =
      WakeWordSettingsService();
  WakeWordConfig? _wakeWordConfig;
  bool _isTestingWakeWord = false;
  bool? _wakeWordTestPassed;
  String? _wakeWordTestHeard;

  bool _assistantRoleAvailable = false;
  bool _isDefaultAssistant = false;

  final Map<String, PermissionStatus> _permissions = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _apiKeyController = TextEditingController(text: widget.aiService.apiKey);
    _baseUrlController = TextEditingController(text: widget.aiService.baseUrl);
    _modelController = TextEditingController(text: widget.aiService.model);
    _telegramTokenController = TextEditingController(
      text: widget.telegramService.botToken,
    );
    _telegramEnabled = widget.telegramService.isEnabled;
    _maxSteps = widget.aiService.rawMaxSteps.toDouble();
    _disableMaxSteps = widget.aiService.disableMaxSteps;
    _temperature = widget.aiService.temperature;
    _maxTokensController = TextEditingController(
      text: widget.aiService.maxTokens.toString(),
    );
    _useScreenCompression = widget.aiService.useScreenCompression;
    _useSystemPrompt = widget.aiService.useSystemPrompt;

    // Auto-save listeners
    _apiKeyController.addListener(_autoSave);
    _baseUrlController.addListener(_autoSave);
    _modelController.addListener(_autoSave);
    _telegramTokenController.addListener(_autoSave);
    _maxTokensController.addListener(_autoSave);

    _checkPermissions();
    if (FeatureFlags.floatingOverlayEnabled) {
      _checkOverlayStatus();
    }
    _checkVoiceAssistantStatus();
    _loadTtsSettings();
    _loadWakeWordConfig();
    _checkAssistantRoleStatus();
  }

  /// Phase 9 (optional/additive): re-checked on resume too (see
  /// [didChangeAppLifecycleState]) since granting/revoking the assistant
  /// role happens in a system Settings screen this app doesn't control.
  Future<void> _checkAssistantRoleStatus() async {
    final available = await widget.screenAutomationService
        .isAssistantRoleAvailable();
    final isDefault = await widget.screenAutomationService
        .isDefaultAssistant();
    if (mounted) {
      setState(() {
        _assistantRoleAvailable = available;
        _isDefaultAssistant = isDefault;
      });
    }
  }

  Future<void> _loadWakeWordConfig() async {
    final config = await _wakeWordSettingsService.loadConfig();
    if (mounted) setState(() => _wakeWordConfig = config);
  }

  /// Persists a changed [WakeWordConfig] and, if background listening is
  /// currently on, restarts the foreground service so the change (a new
  /// name or sensitivity) takes effect immediately instead of silently
  /// waiting for the next manual toggle — `VoiceAssistantForegroundService`
  /// only re-reads config when a fresh service instance is created.
  Future<void> _saveWakeWordConfig(WakeWordConfig config) async {
    setState(() => _wakeWordConfig = config);
    await _wakeWordSettingsService.saveConfig(config);
    if (_voiceAssistantListening) {
      await VoiceAssistantForegroundService.stop();
      await VoiceAssistantForegroundService.start();
    }
  }

  Future<void> _runWakeWordRetest() async {
    final config = _wakeWordConfig;
    if (config == null) return;
    setState(() {
      _isTestingWakeWord = true;
      _wakeWordTestPassed = null;
      _wakeWordTestHeard = null;
    });

    final completer = Completer<String?>();
    try {
      await widget.voiceService.startListening(
        onResult: (text) {
          if (!completer.isCompleted) completer.complete(text);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(null);
        },
      );
    } catch (_) {
      if (!completer.isCompleted) completer.complete(null);
    }
    final heard = await completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () async {
        await widget.voiceService.stopListening();
        return null;
      },
    );

    if (!mounted) return;
    final passed =
        heard != null &&
        heard.toLowerCase().contains(config.assistantName.toLowerCase());
    setState(() {
      _isTestingWakeWord = false;
      _wakeWordTestHeard = heard;
      _wakeWordTestPassed = passed;
    });
  }

  Future<void> _loadTtsSettings() async {
    final settings = await _ttsSettingsService.loadSettings();
    await widget.voiceService.applyTtsSettings(settings);
    final voices = await widget.voiceService.getVoices();
    if (mounted) {
      setState(() {
        _ttsSettings = settings;
        _availableVoices = voices;
        _voicesLoaded = true;
      });
    }
  }

  Future<void> _saveTtsSettings(TtsSettings settings) async {
    setState(() => _ttsSettings = settings);
    await _ttsSettingsService.saveSettings(settings);
    await widget.voiceService.applyTtsSettings(settings);
  }

  Future<void> _checkVoiceAssistantStatus() async {
    final isListening = await VoiceAssistantForegroundService.isListening();
    if (mounted) {
      setState(() => _voiceAssistantListening = isListening);
    }
  }

  Future<void> _checkOverlayStatus() async {
    bool isActive = await FlutterOverlayWindow.isActive();
    bool isGranted = await FlutterOverlayWindow.isPermissionGranted();
    if (mounted) {
      setState(() {
        _floatingIconEnabled = isActive;
        _isOverlayPermissionGranted = isGranted;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _apiKeyController.removeListener(_autoSave);
    _baseUrlController.removeListener(_autoSave);
    _modelController.removeListener(_autoSave);
    _telegramTokenController.removeListener(_autoSave);
    _maxTokensController.removeListener(_autoSave);
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    _telegramTokenController.dispose();
    _maxTokensController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
      if (FeatureFlags.floatingOverlayEnabled) {
        _checkOverlayStatus();
      }
      _checkAssistantRoleStatus();
    }
  }

  Future<void> _checkPermissions() async {
    final perms = {
      'Microphone': Permission.microphone,
      'Contacts': Permission.contacts,
      'Phone': Permission.phone,
      'SMS': Permission.sms,
      'Notifications': Permission.notification,
      'Battery Optimization': Permission.ignoreBatteryOptimizations,
    };

    for (final entry in perms.entries) {
      _permissions[entry.key] = await entry.value.status;
    }
    final overlayGranted = FeatureFlags.floatingOverlayEnabled
        ? await FlutterOverlayWindow.isPermissionGranted()
        : false;
    if (mounted) {
      setState(() {
        _isOverlayPermissionGranted = overlayGranted;
      });
    }
  }

  Future<void> _requestPermission(String name, Permission permission) async {
    final status = await permission.request();
    setState(() => _permissions[name] = status);
  }

  void _autoSave() {
    widget.aiService.saveSettings(
      apiKey: _apiKeyController.text.trim(),
      baseUrl: _baseUrlController.text.trim(),
      model: _modelController.text.trim(),
    );

    widget.telegramService.saveSettings(
      botToken: _telegramTokenController.text.trim(),
      isEnabled: _telegramEnabled,
    );

    widget.aiService.saveMaxSteps(_maxSteps.toInt());
    widget.aiService.saveDisableMaxSteps(_disableMaxSteps);
    widget.aiService.saveAdvancedSettings(
      temperature: _temperature,
      maxTokens: int.tryParse(_maxTokensController.text) ?? 1024,
      useScreenCompression: _useScreenCompression,
      useSystemPrompt: _useSystemPrompt,
    );
  }

  Future<void> _fetchModels() async {
    final baseUrl = _baseUrlController.text.trim();
    final apiKey = _apiKeyController.text.trim();

    if (baseUrl.isEmpty || apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter Base URL and API Key first.'),
        ),
      );
      return;
    }

    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    final models = await widget.aiService.fetchAvailableModels(baseUrl, apiKey);

    // Hide loading
    if (mounted) Navigator.pop(context);

    if (models.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No models found or error fetching models.'),
          ),
        );
      }
      return;
    }

    if (mounted) {
      final isNvidia = AiService.isNvidiaBaseUrl(baseUrl);
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            isNvidia ? 'Select a Free NVIDIA Model' : 'Select a Model',
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: ListView.builder(
              itemCount: models.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(models[index]),
                  onTap: () {
                    setState(() {
                      _modelController.text = models[index];
                    });
                    Navigator.pop(context);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildSettingsCard({
    required IconData icon,
    required String title,
    String? subtitle,
    required List<Widget> children,
    required bool isDark,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    icon,
                    color: Theme.of(context).primaryColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF475569),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            ...children,
          ],
        ),
      ),
    );
  }

  InputDecoration _buildInputDecoration({
    required String labelText,
    required String hintText,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      labelStyle: TextStyle(
        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      hintStyle: TextStyle(
        color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8),
        fontSize: 13,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
          width: 1.2,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
          width: 1.2,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.primary,
          width: 1.8,
        ),
      ),
      floatingLabelBehavior: FloatingLabelBehavior.auto,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          // 1. Appearance Card
          _buildSettingsCard(
            icon: Icons.palette_outlined,
            title: 'Appearance',
            subtitle: 'Choose your preferred color theme',
            isDark: isDark,
            children: [
              ValueListenableBuilder<ThemeMode>(
                valueListenable: themeNotifier,
                builder: (context, currentMode, _) {
                  return SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      style: SegmentedButton.styleFrom(
                        selectedBackgroundColor: Theme.of(
                          context,
                        ).colorScheme.primary,
                        selectedForegroundColor: Colors.white,
                        backgroundColor: isDark
                            ? const Color(0xFF1E293B)
                            : Colors.white,
                        foregroundColor: isDark ? Colors.white : Colors.black87,
                        side: BorderSide(
                          color: isDark
                              ? const Color(0xFF334155)
                              : const Color(0xFFE2E8F0),
                        ),
                      ),
                      segments: [
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: const Text(
                            'System',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          icon: const Icon(Icons.brightness_auto, size: 16),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: const Text(
                            'Light',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          icon: const Icon(Icons.light_mode, size: 16),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: const Text(
                            'Dark',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          icon: const Icon(Icons.dark_mode, size: 16),
                        ),
                      ],
                      selected: {currentMode},
                      onSelectionChanged: (Set<ThemeMode> newSelection) async {
                        final mode = newSelection.first;
                        themeNotifier.value = mode;
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setString('themeMode', mode.name);
                      },
                    ),
                  );
                },
              ),
            ],
          ),

          // 2. AI Engine Config Card
          _buildSettingsCard(
            icon: Icons.psychology_outlined,
            title: 'AI Engine Configuration',
            subtitle: 'Supports any OpenAI-compatible API endpoint',
            isDark: isDark,
            children: [
              TextField(
                controller: _apiKeyController,
                decoration: _buildInputDecoration(
                  labelText: 'API Key',
                  hintText: 'sk-...',
                  prefixIcon: const Icon(Icons.key_rounded, size: 18),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureKey ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
                obscureText: _obscureKey,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _baseUrlController,
                decoration: _buildInputDecoration(
                  labelText: 'API Base URL',
                  hintText: 'https://api.deepseek.com',
                  prefixIcon: const Icon(Icons.dns_rounded, size: 18),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ActionChip(
                    label: const Text(
                      'Local Server',
                      style: TextStyle(fontSize: 11),
                    ),
                    tooltip: 'For local Llama.cpp or LM Studio',
                    onPressed: () =>
                        _baseUrlController.text = 'http://192.168.1.X:8080/v1',
                  ),
                  ActionChip(
                    label: const Text(
                      'Ollama Cloud',
                      style: TextStyle(fontSize: 11),
                    ),
                    onPressed: () {
                      _baseUrlController.text = 'https://ollama.com/v1';
                      _modelController.text = 'gemma3:4b';
                    },
                  ),
                  ActionChip(
                    label: const Text(
                      'DeepSeek',
                      style: TextStyle(fontSize: 11),
                    ),
                    onPressed: () =>
                        _baseUrlController.text = 'https://api.deepseek.com',
                  ),
                  ActionChip(
                    label: const Text('Groq', style: TextStyle(fontSize: 11)),
                    onPressed: () => _baseUrlController.text =
                        'https://api.groq.com/openai/v1',
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.memory_rounded, size: 16),
                    label: const Text('NVIDIA', style: TextStyle(fontSize: 11)),
                    tooltip: 'NVIDIA NIM free endpoints',
                    onPressed: () {
                      _baseUrlController.text = AiService.nvidiaBaseUrl;
                      _modelController.text = AiService.nvidiaDefaultModel;
                    },
                  ),
                  ActionChip(
                    label: const Text('Custom', style: TextStyle(fontSize: 11)),
                    tooltip: 'Clear fields',
                    onPressed: () {
                      _baseUrlController.clear();
                      _apiKeyController.clear();
                      _modelController.clear();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _modelController,
                      decoration: _buildInputDecoration(
                        labelText: 'Model',
                        hintText: 'deepseek-chat',
                        prefixIcon: const Icon(
                          Icons.smart_toy_rounded,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _fetchModels,
                    icon: const Icon(
                      Icons.cloud_download,
                      size: 18,
                      color: Colors.white,
                    ),
                    label: const Text(
                      'Fetch',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          // 3. Parameters & Tuning Card
          _buildSettingsCard(
            icon: Icons.tune_outlined,
            title: 'Tuning & Boundaries',
            subtitle: 'Configure LLM agent parameters',
            isDark: isDark,
            children: [
              SwitchListTile(
                title: const Text('Disable Maximum Steps'),
                subtitle: const Text(
                  '⚠️ Can cause infinite loops.',
                  style: TextStyle(color: Colors.orange, fontSize: 12),
                ),
                value: _disableMaxSteps,
                onChanged: (bool value) {
                  setState(() {
                    _disableMaxSteps = value;
                  });
                  _autoSave();
                },
                contentPadding: EdgeInsets.zero,
              ),
              if (!_disableMaxSteps) ...[
                const SizedBox(height: 8),
                Text(
                  'Maximum Steps Per Task: ${_maxSteps.toInt()}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
                Slider(
                  value: _maxSteps,
                  min: 5,
                  max: 50,
                  divisions: 45,
                  label: _maxSteps.toInt().toString(),
                  onChanged: (value) {
                    setState(() {
                      _maxSteps = value;
                    });
                  },
                  onChangeEnd: (value) {
                    _autoSave();
                  },
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _maxTokensController,
                keyboardType: TextInputType.number,
                decoration: _buildInputDecoration(
                  labelText: 'Context Limit (Max Tokens)',
                  hintText: '1024',
                  prefixIcon: const Icon(Icons.token_rounded, size: 18),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Temperature: ${_temperature.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                ),
              ),
              Slider(
                value: _temperature,
                min: 0.0,
                max: 2.0,
                divisions: 20,
                label: _temperature.toStringAsFixed(2),
                onChanged: (value) {
                  setState(() {
                    _temperature = value;
                  });
                },
                onChangeEnd: (value) {
                  _autoSave();
                },
              ),
            ],
          ),

          // 4. Behavior & Extensions Card
          _buildSettingsCard(
            icon: Icons.extension_outlined,
            title: 'Behavior & Extensions',
            subtitle: 'Additional feature flags and overlay options',
            isDark: isDark,
            children: [
              SwitchListTile(
                title: const Text('Use Screen Compression'),
                subtitle: const Text(
                  'Removes duplicate elements to save tokens',
                ),
                value: _useScreenCompression,
                onChanged: (bool value) {
                  setState(() {
                    _useScreenCompression = value;
                  });
                  _autoSave();
                },
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                title: const Text('Send System Prompt'),
                subtitle: const Text('Turn off for custom LoRA fine-tunes'),
                value: _useSystemPrompt,
                onChanged: (bool value) {
                  setState(() {
                    _useSystemPrompt = value;
                  });
                  _autoSave();
                },
                contentPadding: EdgeInsets.zero,
              ),
              if (FeatureFlags.floatingOverlayEnabled)
                SwitchListTile(
                  title: const Text('Enable Floating Agent Icon'),
                  subtitle: const Text('Assign tasks without opening the app'),
                  value: _floatingIconEnabled,
                  onChanged: (val) async {
                    if (val) {
                      bool? isGranted =
                          await FlutterOverlayWindow.isPermissionGranted();
                      if (isGranted != true) {
                        bool? result =
                            await FlutterOverlayWindow.requestPermission();
                        if (result != true) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Permission to draw over other apps is required.',
                                ),
                              ),
                            );
                          }
                          return;
                        }
                      }
                      if (await FlutterOverlayWindow.isActive() == false) {
                        await FlutterOverlayWindow.showOverlay(
                          enableDrag: true,
                          overlayTitle: "PrivateAgent",
                          overlayContent: "Floating Assistant",
                          flag: OverlayFlag.focusPointer,
                          alignment: OverlayAlignment.centerRight,
                          visibility: NotificationVisibility.visibilitySecret,
                          positionGravity: PositionGravity.auto,
                          startPosition: const OverlayPosition(0, 200),
                          width: 56,
                          height: 56,
                        );
                      }
                    } else {
                      if (await FlutterOverlayWindow.isActive() == true) {
                        await FlutterOverlayWindow.closeOverlay();
                      }
                    }
                    setState(() => _floatingIconEnabled = val);
                    _autoSave();
                  },
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),

          // 4b. Voice Assistant background listening — sherpa-onnx wake-word
          // detection for the 5 supported names (Phase 5b).
          _buildSettingsCard(
            icon: Icons.mic_none_outlined,
            title: 'Voice Assistant (Beta)',
            subtitle: 'Always-on wake-word listening — early preview',
            isDark: isDark,
            children: [
              SwitchListTile(
                title: const Text('Background listening'),
                subtitle: const Text(
                  'Keeps an ongoing notification while active. Say "Hey '
                  '[name]" to start a voice command hands-free — only works '
                  'if your assistant name is Aigentik, Nova, Codey, Juno, '
                  'or Milo.',
                ),
                value: _voiceAssistantListening,
                onChanged: (bool value) async {
                  if (value) {
                    final status = await Permission.microphone.request();
                    if (!status.isGranted) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Microphone permission is required for '
                            'background listening.',
                          ),
                        ),
                      );
                      return;
                    }
                    await VoiceAssistantForegroundService.start();
                  } else {
                    await VoiceAssistantForegroundService.stop();
                  }
                  setState(() => _voiceAssistantListening = value);
                },
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),

          // 4b2. Wake Word identity/sensitivity — Section 9's Settings card,
          // built out in Phase 10 (previously only editable during
          // onboarding, with no way to change the name or tune sensitivity
          // afterward).
          if (_wakeWordConfig != null) _buildWakeWordCard(isDark),

          // 4b3. Default Assistant (optional) — Phase 9. Only shown when
          // the device actually exposes ROLE_ASSISTANT; discoverable from
          // Settings rather than pushed during onboarding, per the plan's
          // Section 11 guidance (a system permission dialog most users
          // would decline if forced up front).
          if (_assistantRoleAvailable) _buildDefaultAssistantCard(isDark),

          // 4c. Text-to-speech voice/rate/pitch/volume (Phase 8).
          _buildSettingsCard(
            icon: Icons.record_voice_over_outlined,
            title: 'Spoken Responses',
            subtitle: 'Voice, speed, pitch, and volume for TTS playback',
            isDark: isDark,
            children: [
              Text(
                'Speed: ${_ttsSettings.rate.toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
              ),
              Slider(
                value: _ttsSettings.rate,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                label: _ttsSettings.rate.toStringAsFixed(2),
                onChanged: (value) {
                  setState(() => _ttsSettings = _ttsSettings.copyWith(rate: value));
                },
                onChangeEnd: (value) => _saveTtsSettings(_ttsSettings),
              ),
              const SizedBox(height: 8),
              Text(
                'Pitch: ${_ttsSettings.pitch.toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
              ),
              Slider(
                value: _ttsSettings.pitch,
                min: 0.0,
                max: 2.0,
                divisions: 20,
                label: _ttsSettings.pitch.toStringAsFixed(2),
                onChanged: (value) {
                  setState(() => _ttsSettings = _ttsSettings.copyWith(pitch: value));
                },
                onChangeEnd: (value) => _saveTtsSettings(_ttsSettings),
              ),
              const SizedBox(height: 8),
              Text(
                'Volume: ${_ttsSettings.volume.toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
              ),
              Slider(
                value: _ttsSettings.volume,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                label: _ttsSettings.volume.toStringAsFixed(2),
                onChanged: (value) {
                  setState(() => _ttsSettings = _ttsSettings.copyWith(volume: value));
                },
                onChangeEnd: (value) => _saveTtsSettings(_ttsSettings),
              ),
              const SizedBox(height: 12),
              if (!_voicesLoaded)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(),
                )
              else if (_availableVoices.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No alternate voices reported by this device — using the '
                    'system default voice.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: _ttsSettings.voiceName,
                  decoration: _buildInputDecoration(
                    labelText: 'Voice',
                    hintText: 'Device default',
                    prefixIcon: const Icon(Icons.person_outline, size: 18),
                  ),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('Device default'),
                    ),
                    ..._availableVoices.map(
                      (v) => DropdownMenuItem<String>(
                        value: v['name'],
                        child: Text(
                          '${v['name']} (${v['locale']})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (name) {
                    final selected = _availableVoices.firstWhere(
                      (v) => v['name'] == name,
                      orElse: () => {'name': '', 'locale': ''},
                    );
                    final settings = name == null
                        ? _ttsSettings.copyWith(clearVoice: true)
                        : _ttsSettings.copyWith(
                            voiceName: name,
                            voiceLocale: selected['locale'],
                          );
                    _saveTtsSettings(settings);
                  },
                ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Test voice'),
                  onPressed: () {
                    widget.voiceService.speak(
                      "Hi, this is how I'll sound when I respond.",
                    );
                  },
                ),
              ),
            ],
          ),

          // 5. Telegram Remote Access Card
          _buildSettingsCard(
            icon: Icons.send_and_archive_outlined,
            title: 'Telegram Remote Access',
            subtitle: 'Control your agent remotely from anywhere',
            isDark: isDark,
            children: [
              TextField(
                controller: _telegramTokenController,
                decoration: _buildInputDecoration(
                  labelText: 'Telegram Bot Token',
                  hintText: '123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11',
                  prefixIcon: const Icon(Icons.send_rounded, size: 18),
                ),
              ),
              SwitchListTile(
                title: const Text('Enable Telegram Bot'),
                subtitle: const Text('Allows remote control via Telegram chat'),
                value: _telegramEnabled,
                onChanged: (val) {
                  setState(() => _telegramEnabled = val);
                  _autoSave();
                },
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),

          // 6. Accessibility Screen Control Card
          _buildSettingsCard(
            icon: Icons.visibility_outlined,
            title: 'Screen Control (Accessibility)',
            subtitle: 'Required to read screen and perform automated clicks',
            isDark: isDark,
            children: [_buildAccessibilityCard()],
          ),

          // 7. System Permissions Card
          _buildSettingsCard(
            icon: Icons.security_outlined,
            title: 'App Permissions',
            subtitle: 'Required for automation, microphone, and contacts',
            isDark: isDark,
            children: _buildPermissionTiles(),
          ),

          // 7b. Privacy Card — plan doc Section 16.2's recommendation: a
          // visible, plain-language summary of what leaves the device and
          // where, mirroring the audit in Section 16.1 rather than leaving
          // it only documented in an engineering doc nobody using the app
          // will ever read.
          _buildSettingsCard(
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy',
            subtitle: 'What PrivateAgent captures and where it goes',
            isDark: isDark,
            children: [
              _buildPrivacyRow(
                isDark,
                'Chat & voice commands',
                'Sent to the AI provider you configure above (or stays on '
                    'your network if you point it at a local server) — '
                    'never to us or any other third party.',
              ),
              _buildPrivacyRow(
                isDark,
                'Screen contents',
                'When running a multi-step task, the on-screen text (not a '
                    'screenshot) is sent to your AI provider alongside your '
                    'request, so it can decide what to tap or type next.',
              ),
              _buildPrivacyRow(
                isDark,
                'Wake word audio',
                'Never leaves your device — the "Hey [name]" detection runs '
                    'entirely offline. Only what you say after it triggers '
                    'goes through speech-to-text like any other voice command.',
              ),
              _buildPrivacyRow(
                isDark,
                'Voice-to-text',
                'Uses your device\'s speech recognizer. Depending on your '
                    'phone and language, that may process audio on-device or '
                    'send it to your phone maker/Google\'s cloud service — '
                    'this is the same recognizer every voice feature on your '
                    'phone already uses, not something unique to this app.',
              ),
              _buildPrivacyRow(
                isDark,
                'API keys & Telegram bot token',
                'Stored in Android\'s encrypted Keystore-backed secure '
                    'storage, not plain preferences.',
              ),
              _buildPrivacyRow(
                isDark,
                'Chat & task history',
                'Stored only on this device — never uploaded, unless you '
                    'enable Telegram remote control below.',
              ),
              _buildPrivacyRow(
                isDark,
                'Telegram remote control (optional)',
                'If enabled, commands you send via Telegram pass through '
                    'Telegram\'s own servers — inherent to how Telegram '
                    'works, and only active if you turn this on.',
              ),
              _buildPrivacyRow(
                isDark,
                'Accessibility permission',
                'The most powerful permission this app holds — it can read '
                    'and interact with whatever is on your screen. That '
                    'access is required for the core screen-automation '
                    'feature and is used only to carry out your requests.',
                isLast: true,
              ),
            ],
          ),

          // 8. Task History Card
          _buildSettingsCard(
            icon: Icons.history_outlined,
            title: 'Execution logs',
            subtitle: 'View history of tasks and token analytics',
            isDark: isDark,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('View Task History'),
                subtitle: const Text(
                  'Access complete trace of execution steps',
                ),
                trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const TaskHistoryScreen(),
                    ),
                  );
                },
              ),
            ],
          ),

          // 9. About / Links Card
          _buildSettingsCard(
            icon: Icons.info_outline_rounded,
            title: 'About PrivateAgent',
            subtitle: 'Resources and repository access',
            isDark: isDark,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Project Repository'),
                subtitle: const Text('View source code on GitHub'),
                leading: const Icon(Icons.code_rounded),
                onTap: () {
                  launchUrl(
                    Uri.parse('https://github.com/orailnoor/private-agent'),
                    mode: LaunchMode.externalApplication,
                  );
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Orailnoor on YouTube'),
                subtitle: const Text('Subscribe for tutorials and updates'),
                leading: const Icon(
                  Icons.play_circle_fill_rounded,
                  color: Colors.red,
                ),
                onTap: () {
                  launchUrl(
                    Uri.parse('https://www.youtube.com/orailnoor'),
                    mode: LaunchMode.externalApplication,
                  );
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tech Jarves on YouTube'),
                subtitle: const Text('Subscribe for tutorials and updates'),
                leading: const Icon(
                  Icons.play_circle_fill_rounded,
                  color: Colors.red,
                ),
                onTap: () {
                  launchUrl(
                    Uri.parse('https://www.youtube.com/techjarves'),
                    mode: LaunchMode.externalApplication,
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _buildPermissionTiles() {
    final permissionMap = {
      'Microphone': Permission.microphone,
      'Contacts': Permission.contacts,
      'Phone': Permission.phone,
      'SMS': Permission.sms,
      'Notifications': Permission.notification,
      'Battery Optimization': Permission.ignoreBatteryOptimizations,
    };

    final icons = {
      'Microphone': Icons.mic,
      'Contacts': Icons.contacts,
      'Phone': Icons.phone,
      'SMS': Icons.sms,
      'Notifications': Icons.notifications,
      'Battery Optimization': Icons.battery_charging_full_rounded,
    };

    final list = permissionMap.entries.map((entry) {
      final status = _permissions[entry.key];
      final isGranted = status?.isGranted ?? false;

      return ListTile(
        leading: Icon(icons[entry.key]),
        title: Text(entry.key),
        trailing: isGranted
            ? Icon(
                Icons.check_circle,
                color: Theme.of(context).colorScheme.primary,
              )
            : TextButton(
                onPressed: () => _requestPermission(entry.key, entry.value),
                child: const Text('Grant'),
              ),
        subtitle: Text(
          isGranted
              ? 'Granted'
              : (status?.isDenied ?? true
                    ? 'Not granted'
                    : 'Denied permanently'),
          style: TextStyle(
            color: isGranted
                ? Theme.of(context).colorScheme.primary
                : Colors.orange,
            fontSize: 12,
          ),
        ),
      );
    }).toList();

    if (FeatureFlags.floatingOverlayEnabled) {
      list.add(
        ListTile(
          leading: const Icon(Icons.layers),
          title: const Text('Display Over Other Apps (Floating Bubble)'),
          trailing: _isOverlayPermissionGranted
              ? Icon(
                  Icons.check_circle,
                  color: Theme.of(context).colorScheme.primary,
                )
              : TextButton(
                  onPressed: () async {
                    await FlutterOverlayWindow.requestPermission();
                    final granted =
                        await FlutterOverlayWindow.isPermissionGranted();
                    setState(() {
                      _isOverlayPermissionGranted = granted;
                    });
                  },
                  child: const Text('Grant'),
                ),
          subtitle: Text(
            _isOverlayPermissionGranted ? 'Granted' : 'Not granted',
            style: TextStyle(
              color: _isOverlayPermissionGranted
                  ? Theme.of(context).colorScheme.primary
                  : Colors.orange,
              fontSize: 12,
            ),
          ),
        ),
      );
    }

    return list;
  }

  /// Section 9's "Settings → Wake Word card" spec: current name/phrase
  /// (editable), enable/disable, sensitivity, re-test, and an engine/tier
  /// indicator. The sensitivity slider is meaningful here (unlike the
  /// plan's original "hidden for Tier 2b" caveat, which was written before
  /// the Phase 5 sherpa-onnx decision) — it's wired to sherpa-onnx's
  /// `keywordsThreshold` natively in `VoiceAssistantForegroundService`.
  Widget _buildWakeWordCard(bool isDark) {
    final config = _wakeWordConfig!;
    return _buildSettingsCard(
      icon: Icons.hearing_rounded,
      title: 'Wake Word',
      subtitle: 'Your assistant\'s name and how eagerly it listens for it',
      isDark: isDark,
      children: [
        Text(
          'Wake phrase: "Hey ${config.assistantName}"',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        const SizedBox(height: 4),
        Text(
          'Engine: offline keyword spotting (sherpa-onnx)',
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white60 : Colors.black54,
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: config.assistantName,
          decoration: _buildInputDecoration(
            labelText: 'Assistant name',
            hintText: 'Pick a name',
            prefixIcon: const Icon(Icons.badge_outlined, size: 18),
          ),
          items: [
            for (final preset in WakeWordSettingsService.presetNames)
              DropdownMenuItem<String>(value: preset, child: Text(preset)),
          ],
          onChanged: (name) {
            if (name == null || name == config.assistantName) return;
            _saveWakeWordConfig(
              config.copyWith(
                assistantName: name,
                wakePhrase: 'Hey $name',
                tier: _wakeWordSettingsService.tierForName(name),
              ),
            );
          },
        ),
        SwitchListTile(
          title: const Text('Wake word enabled'),
          subtitle: const Text(
            'When off, background listening won\'t react to the wake '
            'phrase even if it\'s turned on above',
          ),
          value: config.enabled,
          onChanged: (value) =>
              _saveWakeWordConfig(config.copyWith(enabled: value)),
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 4),
        Text(
          'Sensitivity: ${(config.sensitivity * 100).round()}%',
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
        ),
        Text(
          'Higher means it triggers more easily but may misfire more often; '
          'lower means fewer misfires but you may need to say it more '
          'clearly.',
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white60 : Colors.black54,
          ),
        ),
        Slider(
          value: config.sensitivity,
          min: 0.0,
          max: 1.0,
          divisions: 20,
          label: '${(config.sensitivity * 100).round()}%',
          onChanged: (value) {
            setState(() => _wakeWordConfig = config.copyWith(sensitivity: value));
          },
          onChangeEnd: (value) =>
              _saveWakeWordConfig(config.copyWith(sensitivity: value)),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _isTestingWakeWord ? null : _runWakeWordRetest,
          icon: _isTestingWakeWord
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.mic_rounded, size: 18),
          label: Text(
            _isTestingWakeWord
                ? 'Listening for "${config.assistantName}"...'
                : 'Re-test wake word',
          ),
        ),
        if (_wakeWordTestPassed != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                _wakeWordTestPassed! ? Icons.check_circle : Icons.error_outline,
                size: 16,
                color: _wakeWordTestPassed! ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _wakeWordTestPassed!
                      ? 'Heard: "$_wakeWordTestHeard"'
                      : _wakeWordTestHeard == null
                      ? 'Didn\'t hear anything — try again.'
                      : 'Heard "$_wakeWordTestHeard", but not the wake phrase.',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Phase 9 (optional/additive, plan Section 10.1/10.3): lets long-press
  /// -home / the assistant gesture route to PrivateAgent, via
  /// `RoleManager.ROLE_ASSISTANT`. Deliberately opt-in and reversible —
  /// explains what it does and how to undo it before the user ever taps
  /// the button, rather than assuming they'll figure it out after the
  /// system picker appears.
  Widget _buildDefaultAssistantCard(bool isDark) {
    return _buildSettingsCard(
      icon: Icons.assistant_rounded,
      title: 'Default Assistant (Optional)',
      subtitle: 'Route long-press-home / your phone\'s assistant gesture '
          'to PrivateAgent',
      isDark: isDark,
      children: [
        Text(
          _isDefaultAssistant
              ? 'PrivateAgent is currently your Android assistant.'
              : 'Not set — long-press-home currently opens your phone\'s '
                    'usual assistant.',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: _isDefaultAssistant
                ? (isDark ? Colors.greenAccent : Colors.green.shade700)
                : (isDark ? Colors.white70 : Colors.black87),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'This is separate from the wake word and mic button, which '
          'already work without this. Reliability varies by phone maker — '
          'some (notably Samsung) may not fully hand off from their own '
          'assistant. You can always undo this from Android\'s own '
          'Settings → Apps → Default apps → Digital assistant app, even '
          'if PrivateAgent is uninstalled or misbehaving.',
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white60 : Colors.black54,
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _isDefaultAssistant
              ? null
              : () async {
                  await widget.screenAutomationService.requestAssistantRole();
                  // The system picker runs in a separate task; re-check
                  // when this screen next resumes rather than blocking on
                  // a result here.
                },
          icon: const Icon(Icons.assistant_rounded, size: 18),
          label: Text(
            _isDefaultAssistant
                ? 'Already set'
                : 'Make PrivateAgent my Android Assistant',
          ),
        ),
      ],
    );
  }

  /// One row of the Privacy card: a bold label plus a short plain-language
  /// explanation. Deliberately not collapsible/interactive — this is meant
  /// to be skimmed in full, not hidden behind taps.
  Widget _buildPrivacyRow(
    bool isDark,
    String label,
    String description, {
    bool isLast = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
          const SizedBox(height: 3),
          Text(
            description,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: isDark ? Colors.white60 : Colors.black54,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShizukuCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  widget.shizukuService.isAvailable
                      ? Icons.link
                      : Icons.link_off,
                  color: widget.shizukuService.isAvailable
                      ? Colors.green
                      : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  widget.shizukuService.isAvailable
                      ? 'Shizuku is running'
                      : 'Shizuku not detected',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: widget.shizukuService.isAvailable
                        ? Colors.green
                        : Colors.grey,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!widget.shizukuService.isAvailable) ...[
              const Text(
                '1. Install Shizuku from Play Store\n'
                '2. Open Shizuku and start it via Wireless Debugging\n'
                '3. Come back here and tap "Check Again"',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () async {
                  await widget.shizukuService.checkAvailability();
                  if (mounted) setState(() {});
                },
                child: const Text('Check Again'),
              ),
            ] else if (!widget.shizukuService.hasPermission) ...[
              OutlinedButton(
                onPressed: () async {
                  await widget.shizukuService.requestPermission();
                  if (mounted) setState(() {});
                },
                child: const Text('Grant Shizuku Permission'),
              ),
            ] else ...[
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 16),
                  const SizedBox(width: 4),
                  Text(
                    'Permission granted — ADB commands available',
                    style: TextStyle(color: Colors.green[700], fontSize: 13),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAccessibilityCard() {
    return FutureBuilder<bool>(
      future: widget.screenAutomationService.isServiceRunning(),
      builder: (context, snapshot) {
        final isRunning = snapshot.data ?? false;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      isRunning ? Icons.visibility : Icons.visibility_off,
                      color: isRunning ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isRunning
                          ? 'Screen Control is active'
                          : 'Screen Control is disabled',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: isRunning ? Colors.green : Colors.grey,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (!isRunning) ...[
                  const Text(
                    'Tap below to open Accessibility Settings, then find "PrivateAgent Screen Control" and enable it.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await widget.screenAutomationService
                          .openAccessibilitySettings();
                    },
                    icon: const Icon(Icons.settings),
                    label: const Text('Open Accessibility Settings'),
                  ),
                ] else ...[
                  Text(
                    'Can read screen, tap, scroll, and type in other apps',
                    style: TextStyle(color: Colors.green[700], fontSize: 13),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
