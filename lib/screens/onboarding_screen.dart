import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'dart:ui';
import '../config/feature_flags.dart';
import '../models/wake_word_config.dart';
import '../services/ai_service.dart';
import '../services/screen_automation_service.dart';
import '../services/voice_service.dart';
import '../services/wake_word_settings_service.dart';
import 'home_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  final PageController _pageController = PageController();
  final ScreenAutomationService _screenAutomationService =
      ScreenAutomationService();
  final AiService _aiService = AiService();
  final VoiceService _voiceService = VoiceService();
  final WakeWordSettingsService _wakeWordSettingsService =
      WakeWordSettingsService();

  static const _stepLabels = [
    'Welcome',
    'Assistant',
    'Permissions',
    'AI Setup',
    'Voice Test',
    'Ready',
  ];

  int _currentStep = 0;
  bool _isAccessibilityGranted = false;
  bool _isMicrophoneGranted = false;
  bool _isNotificationsGranted = false;
  bool _isContactsGranted = false;
  bool _isPhoneGranted = false;
  bool _isSmsGranted = false;
  bool _isOverlayGranted = false;
  bool _isBatteryUnrestricted = false;

  // Assistant Identity state
  final TextEditingController _assistantNameController =
      TextEditingController();
  bool _isTestingWakeWord = false;
  bool? _wakeWordTestPassed;
  String? _wakeWordTestHeard;

  // Voice Test state
  bool _isRunningVoiceTest = false;
  bool? _voiceTestPassed;
  String? _voiceTestHeard;

  // AI config states
  String _selectedProvider = 'deepseek';
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _baseUrlController = TextEditingController(
    text: 'https://api.deepseek.com',
  );
  final TextEditingController _modelController = TextEditingController(
    text: 'deepseek-chat',
  );
  bool _obscureKey = true;
  bool _isValidating = false;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAiDefaults();
    _loadWakeWordDefaults();
    _checkPermissions();
    _voiceService.init();
  }

  Future<void> _loadAiDefaults() async {
    await _aiService.init();
    if (!mounted || !_aiService.isConfigured) return;
    setState(() {
      _selectedProvider = 'custom';
      _apiKeyController.text = _aiService.apiKey;
      _baseUrlController.text = _aiService.baseUrl;
      _modelController.text = _aiService.model;
    });
  }

  Future<void> _loadWakeWordDefaults() async {
    final config = await _wakeWordSettingsService.loadConfig();
    if (!mounted || config == null) return;
    setState(() {
      _assistantNameController.text = config.assistantName;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    _assistantNameController.dispose();
    _voiceService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
    }
  }

  Future<void> _checkPermissions() async {
    final accessibilityRunning = await _screenAutomationService
        .isServiceRunning();
    final microphoneStatus = await Permission.microphone.status;
    final notificationsStatus = await Permission.notification.status;
    final contactsStatus = await Permission.contacts.status;
    final phoneStatus = await Permission.phone.status;
    final smsStatus = await Permission.sms.status;
    final batteryStatus = await Permission.ignoreBatteryOptimizations.status;
    final overlayGranted = FeatureFlags.floatingOverlayEnabled
        ? await FlutterOverlayWindow.isPermissionGranted()
        : false;

    if (mounted) {
      setState(() {
        _isAccessibilityGranted = accessibilityRunning;
        _isMicrophoneGranted = microphoneStatus.isGranted;
        _isNotificationsGranted = notificationsStatus.isGranted;
        _isContactsGranted = contactsStatus.isGranted;
        _isPhoneGranted = phoneStatus.isGranted;
        _isSmsGranted = smsStatus.isGranted;
        _isBatteryUnrestricted = batteryStatus.isGranted;
        _isOverlayGranted = overlayGranted;
      });
    }
  }

  Future<void> _requestPermission(Permission permission) async {
    await permission.request();
    _checkPermissions();
  }

  Future<void> _requestAccessibility() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Enable Screen Control'),
        content: const Text(
          'If Android shows “Restricted setting”, open App Info first, tap the '
          'three-dot menu, and choose “Allow restricted settings”. Then return '
          'and open Accessibility Settings to enable PrivateAgent Screen Control.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _screenAutomationService.openAccessibilitySettings();
            },
            child: const Text('Accessibility Settings'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              openAppSettings();
            },
            child: const Text('Open App Info First'),
          ),
        ],
      ),
    );
  }

  Future<void> _requestOverlayPermission() async {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    bool granted = await FlutterOverlayWindow.isPermissionGranted();
    if (!granted) {
      await FlutterOverlayWindow.requestPermission();
      granted = await FlutterOverlayWindow.isPermissionGranted();
    }
    setState(() {
      _isOverlayGranted = granted;
    });
  }

  void _selectProvider(String provider) {
    setState(() {
      _selectedProvider = provider;
      _validationError = null;
      if (provider == 'deepseek') {
        _baseUrlController.text = 'https://api.deepseek.com';
        _modelController.text = 'deepseek-chat';
      } else if (provider == 'groq') {
        _baseUrlController.text = 'https://api.groq.com/openai/v1';
        _modelController.text = 'llama-3.3-70b-versatile';
      } else if (provider == 'nvidia') {
        _baseUrlController.text = AiService.nvidiaBaseUrl;
        _modelController.text = AiService.nvidiaDefaultModel;
      } else if (provider == 'ollama') {
        _baseUrlController.text = 'http://10.0.2.2:11434/v1';
        _modelController.text = 'gemma2';
      } else if (provider == 'local') {
        _baseUrlController.text = 'http://10.0.2.2:1234/v1';
        _modelController.text = 'qwen2.5-7b-instruct';
      } else if (provider == 'google') {
        _baseUrlController.text = AiService.googleAiBaseUrl;
        _modelController.text = AiService.googleAiDefaultModel;
      } else {
        _baseUrlController.clear();
        _modelController.clear();
      }
    });
  }

  /// Validates + saves the AI provider config and advances to the next
  /// onboarding step. Does NOT mark onboarding complete or navigate away —
  /// that now happens on the Readiness page's "Finish Setup" action, since
  /// Voice Test and Readiness come after AI Setup in the revised flow.
  Future<void> _validateAiConfig() async {
    setState(() {
      _isValidating = true;
      _validationError = null;
    });

    final apiKey = _apiKeyController.text.trim();
    final baseUrl = _baseUrlController.text.trim();
    final model = _modelController.text.trim();

    if (baseUrl.isEmpty || model.isEmpty) {
      setState(() {
        _validationError = 'Please fill out API Base URL and Model.';
        _isValidating = false;
      });
      return;
    }

    if (_selectedProvider != 'ollama' &&
        _selectedProvider != 'local' &&
        apiKey.isEmpty) {
      setState(() {
        _validationError = 'API Key is required for this provider.';
        _isValidating = false;
      });
      return;
    }

    try {
      final models = await _aiService.fetchAvailableModels(baseUrl, apiKey);
      if (models.isNotEmpty ||
          _selectedProvider == 'ollama' ||
          _selectedProvider == 'local') {
        await _aiService.saveSettings(
          apiKey: apiKey,
          baseUrl: baseUrl,
          model: model,
        );

        if (mounted) {
          setState(() {
            _isValidating = false;
          });
          _pageController.nextPage(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutCubic,
          );
        }
      } else {
        setState(() {
          _validationError =
              'Failed to fetch models from the server. Verify base URL and API Key.';
          _isValidating = false;
        });
      }
    } catch (e) {
      setState(() {
        _validationError =
            'Error: ${e.toString().replaceFirst('Exception: ', '')}';
        _isValidating = false;
      });
    }
  }

  /// The actual "finish onboarding" action, now on the Readiness page.
  Future<void> _finishSetup() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_completed', true);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('All set! Launching PrivateAgent...'),
        backgroundColor: Colors.indigoAccent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  /// Persists the assistant name/wake phrase immediately on selection, per
  /// the plan's requirement that backgrounding mid-onboarding doesn't lose
  /// the choice. `name` should always be one of
  /// `WakeWordSettingsService.presetNames` — those are the only names with
  /// a bundled, pre-tokenized wake-word model (Phase 5b decision).
  Future<void> _saveWakeWordChoice(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final existing = _wakeWordSettingsService.config;
    await _wakeWordSettingsService.saveConfig(
      WakeWordConfig(
        assistantName: trimmed,
        wakePhrase: 'Hey $trimmed',
        tier: _wakeWordSettingsService.tierForName(trimmed),
        engine: WakeWordSettingsService.defaultEngine,
        enabled: true,
        sensitivity: existing?.sensitivity ?? 0.5,
        createdAt: existing?.createdAt ?? DateTime.now(),
      ),
    );
  }

  /// Captures a single utterance via the existing push-to-talk `VoiceService`
  /// with a safety timeout — `VoiceService` doesn't surface mic/init
  /// failures as a callback, so without this a denied mic would hang the
  /// test forever (same hazard `VoiceConversationController` solves).
  Future<String?> _captureUtterance({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final completer = Completer<String?>();
    try {
      await _voiceService.startListening(
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
    return completer.future.timeout(
      timeout,
      onTimeout: () async {
        await _voiceService.stopListening();
        return null;
      },
    );
  }

  Future<void> _runWakeWordTest() async {
    final phrase = _assistantNameController.text.trim();
    if (phrase.isEmpty) return;
    setState(() {
      _isTestingWakeWord = true;
      _wakeWordTestPassed = null;
      _wakeWordTestHeard = null;
    });

    final heard = await _captureUtterance();
    final passed =
        heard != null &&
        heard.toLowerCase().contains(phrase.toLowerCase());

    if (!mounted) return;
    setState(() {
      _isTestingWakeWord = false;
      _wakeWordTestHeard = heard;
      _wakeWordTestPassed = passed;
    });
  }

  Future<void> _runVoiceTest() async {
    setState(() {
      _isRunningVoiceTest = true;
      _voiceTestPassed = null;
      _voiceTestHeard = null;
    });

    final heard = await _captureUtterance();
    if (!mounted) return;

    setState(() {
      _isRunningVoiceTest = false;
      _voiceTestHeard = heard;
      _voiceTestPassed = heard != null && heard.trim().isNotEmpty;
    });

    if (_voiceTestPassed == true && heard != null) {
      await _voiceService.speak('You said: $heard');
    }
  }

  Future<void> _fetchModels() async {
    final baseUrl = _baseUrlController.text.trim();
    final apiKey = _apiKeyController.text.trim();

    if (baseUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please enter an API Base URL first.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
      return;
    }

    setState(() {
      _isValidating = true;
    });

    try {
      final models = await _aiService.fetchAvailableModels(baseUrl, apiKey);

      setState(() {
        _isValidating = false;
      });

      if (models.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'No models found. Check base URL or API Key.',
              ),
              backgroundColor: Colors.orangeAccent,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
        return;
      }

      if (mounted) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        showModalBottomSheet(
          context: context,
          backgroundColor: isDark ? const Color(0xFF161329) : Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          builder: (context) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AiService.isNvidiaBaseUrl(baseUrl)
                          ? 'Select a Free NVIDIA Model'
                          : 'Select a Model',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        itemCount: models.length,
                        itemBuilder: (context, index) {
                          final modelName = models[index];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            title: Text(
                              modelName,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: isDark ? Colors.white70 : Colors.black87,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right_rounded,
                              size: 18,
                            ),
                            onTap: () {
                              setState(() {
                                _modelController.text = modelName;
                              });
                              Navigator.pop(context);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      }
    } catch (e) {
      setState(() {
        _isValidating = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error: ${e.toString().replaceFirst('Exception: ', '')}',
            ),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    }
  }

  bool get _canProceedFromPermissions {
    return _isAccessibilityGranted &&
        _isMicrophoneGranted &&
        _isNotificationsGranted &&
        (!FeatureFlags.floatingOverlayEnabled || _isOverlayGranted);
  }

  /// Gate for the final "Finish Setup" action on the Readiness page.
  /// Battery-optimization exemption and wake-word setup are shown there as
  /// advisory (⚠️) rather than blocking — Android may not let the app force
  /// the battery exemption, and no wake-word engine exists yet (Phase 5),
  /// so requiring it would trap users in onboarding for an inert feature.
  bool get _canFinishSetup {
    return _isAccessibilityGranted &&
        _isMicrophoneGranted &&
        _isNotificationsGranted &&
        (!FeatureFlags.floatingOverlayEnabled || _isOverlayGranted) &&
        _aiService.isConfigured;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF0B0F19)
          : const Color(0xFFF8FAFC),
      body: Stack(
        children: [
          // Background fluid glow effect
          _buildBackgroundGlows(isDark),

          // Blur filter over background glows
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 120, sigmaY: 120),
              child: Container(color: Colors.transparent),
            ),
          ),

          SafeArea(
            child: Column(
              children: [
                // Top Custom Animated Stepper Bar
                Padding(
                  padding: const EdgeInsets.only(
                    top: 24,
                    left: 32,
                    right: 32,
                    bottom: 8,
                  ),
                  child: _buildAnimatedStepper(isDark),
                ),

                Expanded(
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (page) {
                      setState(() {
                        _currentStep = page;
                      });
                    },
                    children: [
                      _buildWelcomePage(isDark),
                      _buildAssistantIdentityPage(isDark),
                      _buildPermissionsPage(isDark),
                      _buildModelSetupPage(isDark),
                      _buildVoiceTestPage(isDark),
                      _buildReadinessPage(isDark),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackgroundGlows(bool isDark) {
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned(
            top: -100,
            right: -100,
            child: Container(
              width: 350,
              height: 350,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    isDark
                        ? const Color(0xFF6366F1).withOpacity(0.18)
                        : const Color(0xFF4F46E5).withOpacity(0.08),
                    isDark
                        ? const Color(0xFF6366F1).withOpacity(0)
                        : const Color(0xFF4F46E5).withOpacity(0),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -50,
            left: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    isDark
                        ? const Color(0xFF38BDF8).withOpacity(0.15)
                        : const Color(0xFF0EA5E9).withOpacity(0.06),
                    isDark
                        ? const Color(0xFF38BDF8).withOpacity(0)
                        : const Color(0xFF0EA5E9).withOpacity(0),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnimatedStepper(bool isDark) {
    // Six steps don't fit as fixed-width segments the way three did, so this
    // uses Expanded segments (scales to any step count) plus a single
    // "Step X of Y: Label" line instead of six individually-labeled segments.
    return Column(
      children: [
        Row(
          children: List.generate(_stepLabels.length, (index) {
            final isActive = _currentStep == index;
            final isCompleted = _currentStep > index;

            return Expanded(
              child: Container(
                margin: EdgeInsets.only(
                  right: index == _stepLabels.length - 1 ? 0 : 4,
                ),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: isActive
                        ? Theme.of(context).primaryColor
                        : isCompleted
                        ? Theme.of(context).primaryColor.withOpacity(0.5)
                        : (isDark
                              ? const Color(0xFF1E293B)
                              : const Color(0xFFE2E8F0)),
                    boxShadow: isActive
                        ? [
                            BoxShadow(
                              color: Theme.of(
                                context,
                              ).primaryColor.withOpacity(0.25),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 10),
        Text(
          'Step ${_currentStep + 1} of ${_stepLabels.length}: '
          '${_stepLabels[_currentStep]}',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).primaryColor,
          ),
        ),
      ],
    );
  }

  // --- STEP 1: WELCOME SCREEN ---
  Widget _buildWelcomePage(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(flex: 3),
          // Large Custom Glowing Logo Container
          Stack(
            alignment: Alignment.center,
            children: [
              // Outer Halo Glow
              Container(
                width: 170,
                height: 170,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context).primaryColor.withOpacity(0.12),
                ),
              ),
              Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark ? const Color(0xFF151D30) : Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(isDark ? 0.25 : 0.08),
                      blurRadius: 25,
                      offset: const Offset(0, 10),
                    ),
                  ],
                  border: Border.all(
                    color: Theme.of(context).primaryColor.withOpacity(0.15),
                    width: 1.5,
                  ),
                ),
                child: Icon(
                  Icons.smart_toy_rounded,
                  size: 70,
                  color: Theme.of(context).primaryColor,
                ),
              ),
            ],
          ),
          const Spacer(flex: 2),
          // Clean Title
          Text(
            'PrivateAgent',
            style: TextStyle(
              fontSize: 38,
              fontWeight: FontWeight.w900,
              color: isDark ? Colors.white : const Color(0xFF1E293B),
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Your local, secure, and smart mobile companion. PrivateAgent can navigate apps, perform operations, and speak with you.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
              height: 1.55,
            ),
          ),
          const Spacer(flex: 2),

          // Custom Sleek Features list
          _buildFeatureCard(
            Icons.vpn_key_outlined,
            'Local & Private',
            'Full support for local-first execution. Keys remain encrypted locally.',
            isDark,
          ),
          const SizedBox(height: 12),
          _buildFeatureCard(
            Icons.ads_click_rounded,
            'Automated Actions',
            'Can read your screen and perform operations across other apps.',
            isDark,
          ),

          const Spacer(flex: 3),
          // Get Started button
          Container(
            width: double.infinity,
            height: 56,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: Theme.of(context).colorScheme.primary,
              boxShadow: [
                BoxShadow(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withOpacity(0.25),
                  blurRadius: 15,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ElevatedButton(
              onPressed: () {
                _pageController.nextPage(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                foregroundColor: Colors.white,
                shadowColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Get Started',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.2,
                    ),
                  ),
                  SizedBox(width: 10),
                  Icon(Icons.arrow_forward_rounded, size: 20),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildFeatureCard(
    IconData icon,
    String title,
    String subtitle,
    bool isDark,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.06),
          width: 1.2,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 22, color: Theme.of(context).primaryColor),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
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
            ),
          ),
        ],
      ),
    );
  }

  // --- STEP: ASSISTANT IDENTITY (wake word / assistant name) ---
  Widget _buildAssistantIdentityPage(bool isDark) {
    final name = _assistantNameController.text.trim();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          const Text(
            'What should I call myself?',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Pick a name for your assistant. Wake-word detection currently '
            'only works for these 5 names — each one ships with its own '
            'offline detection model built into the app. Support for typing '
            'any name may come later; for now, other names still work fine '
            'everywhere else in the app via the mic button.',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 90,
            child: ListView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              children: [
                for (final preset in WakeWordSettingsService.presetNames) ...[
                  _buildAssistantNamePresetCard(preset, isDark),
                  const SizedBox(width: 10),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (name.isNotEmpty)
            Text(
              'Wake phrase: "Hey $name"',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: (name.isEmpty || _isTestingWakeWord)
                ? null
                : () async {
                    await _saveWakeWordChoice(name);
                    await _runWakeWordTest();
                  },
            icon: _isTestingWakeWord
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Theme.of(context).primaryColor,
                      ),
                    ),
                  )
                : const Icon(Icons.mic_rounded, size: 18),
            label: Text(
              _isTestingWakeWord ? 'Listening for "$name"...' : 'Test it',
            ),
          ),
          if (_wakeWordTestPassed != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  _wakeWordTestPassed!
                      ? Icons.check_circle_rounded
                      : Icons.error_outline_rounded,
                  color: _wakeWordTestPassed! ? Colors.green : Colors.orange,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _wakeWordTestPassed!
                        ? 'Mic heard: "${_wakeWordTestHeard ?? ''}" — this checks your mic hears the phrase. Always-on background detection arrives once background listening ships.'
                        : _wakeWordTestHeard == null
                        ? "Didn't catch anything — try again closer to the mic."
                        : 'Heard "$_wakeWordTestHeard", not "$name" — try again.',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF475569),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const Spacer(),
          Row(
            children: [
              TextButton(
                onPressed: () {
                  _pageController.previousPage(
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                  );
                },
                style: TextButton.styleFrom(
                  foregroundColor: isDark
                      ? Colors.white
                      : const Color(0xFF475569),
                ),
                child: const Text(
                  'Back',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const Spacer(),
              Container(
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: Theme.of(context).colorScheme.primary,
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withOpacity(0.25),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: () async {
                    if (name.isNotEmpty) await _saveWakeWordChoice(name);
                    _pageController.nextPage(
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    shadowColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                  ),
                  child: const Row(
                    children: [
                      Text('Next', style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(width: 8),
                      Icon(Icons.arrow_forward_rounded, size: 16),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildAssistantNamePresetCard(String name, bool isDark) {
    final isSelected = _assistantNameController.text.trim() == name;

    return Container(
      width: 104,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
          width: isSelected ? 2 : 1.2,
        ),
      ),
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        color: isSelected
            ? Theme.of(context).colorScheme.primary.withOpacity(0.12)
            : Theme.of(context).colorScheme.surface,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            setState(() {
              _assistantNameController.text = name;
              _wakeWordTestPassed = null;
              _wakeWordTestHeard = null;
            });
            _saveWakeWordChoice(name);
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.record_voice_over_rounded,
                size: 24,
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : (isDark ? Colors.grey[400] : Colors.grey[600]),
              ),
              const SizedBox(height: 8),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : (isDark ? Colors.grey[300] : Colors.grey[700]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- STEP: VOICE TEST ---
  Widget _buildVoiceTestPage(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          const Text(
            "Let's test your voice",
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "Say something and I'll say it back — this confirms speech-to-text "
            'and text-to-speech both work before you rely on voice for real.',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
            ),
          ),
          const Spacer(),
          Center(
            child: GestureDetector(
              onTap: _isRunningVoiceTest ? null : _runVoiceTest,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context).colorScheme.primary.withOpacity(
                    _isRunningVoiceTest ? 0.25 : 0.12,
                  ),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                ),
                child: Icon(
                  _isRunningVoiceTest ? Icons.graphic_eq_rounded : Icons.mic_rounded,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              _isRunningVoiceTest ? 'Listening...' : 'Tap to speak',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
          ),
          if (_voiceTestPassed != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: (_voiceTestPassed! ? Colors.green : Colors.orange)
                    .withOpacity(0.1),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: (_voiceTestPassed! ? Colors.green : Colors.orange)
                      .withOpacity(0.25),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _voiceTestPassed!
                        ? Icons.check_circle_rounded
                        : Icons.error_outline_rounded,
                    color: _voiceTestPassed! ? Colors.green : Colors.orange,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _voiceTestPassed!
                          ? 'Heard: "${_voiceTestHeard ?? ''}" — and spoke it back.'
                          : "Didn't hear anything — check the microphone "
                                'permission and try again.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF475569),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Spacer(),
          Row(
            children: [
              TextButton(
                onPressed: () {
                  _pageController.previousPage(
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                  );
                },
                style: TextButton.styleFrom(
                  foregroundColor: isDark
                      ? Colors.white
                      : const Color(0xFF475569),
                ),
                child: const Text(
                  'Back',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const Spacer(),
              Container(
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: Theme.of(context).colorScheme.primary,
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withOpacity(0.25),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: () {
                    _pageController.nextPage(
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    shadowColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                  ),
                  child: const Row(
                    children: [
                      Text('Next', style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(width: 8),
                      Icon(Icons.arrow_forward_rounded, size: 16),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // --- STEP: ASSISTANT READINESS CHECK ---
  Widget _buildReadinessPage(bool isDark) {
    final wakeWordConfigured = _assistantNameController.text.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          const Text(
            'Assistant Readiness',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'One last check before you start.',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              children: [
                _buildReadinessRow(
                  'Accessibility',
                  _isAccessibilityGranted,
                  isDark,
                ),
                _buildReadinessRow('Microphone', _isMicrophoneGranted, isDark),
                _buildReadinessRow(
                  'Notifications',
                  _isNotificationsGranted,
                  isDark,
                ),
                if (FeatureFlags.floatingOverlayEnabled)
                  _buildReadinessRow(
                    'Floating Bubble',
                    _isOverlayGranted,
                    isDark,
                  ),
                _buildReadinessRow(
                  'Battery unrestricted',
                  _isBatteryUnrestricted,
                  isDark,
                  advisory: true,
                ),
                _buildReadinessRow(
                  'Wake word configured',
                  wakeWordConfigured,
                  isDark,
                  advisory: true,
                ),
                _buildReadinessRow(
                  'AI configured',
                  _aiService.isConfigured,
                  isDark,
                ),
              ],
            ),
          ),
          if (!_canFinishSetup)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Go back and finish the mandatory items above before finishing setup.',
                style: TextStyle(fontSize: 12, color: Colors.orange[700]),
              ),
            ),
          Container(
            width: double.infinity,
            height: 56,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: _canFinishSetup
                  ? Theme.of(context).colorScheme.primary
                  : (isDark
                        ? const Color(0xFF1E293B)
                        : const Color(0xFFE2E8F0)),
              boxShadow: _canFinishSetup
                  ? [
                      BoxShadow(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withOpacity(0.25),
                        blurRadius: 15,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: ElevatedButton(
              onPressed: _canFinishSetup ? _finishSetup : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                foregroundColor: Colors.white,
                shadowColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Finish Setup',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  SizedBox(width: 8),
                  Icon(Icons.check_circle_outline_rounded, size: 20),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildReadinessRow(
    String label,
    bool ok,
    bool isDark, {
    bool advisory = false,
  }) {
    final color = ok ? Colors.green : (advisory ? Colors.orange : Colors.red);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(
            ok
                ? Icons.check_circle_rounded
                : (advisory
                      ? Icons.warning_amber_rounded
                      : Icons.cancel_rounded),
            color: color,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- STEP 2: PERMISSIONS SCREEN ---
  Widget _buildPermissionsPage(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          const Text(
            'Configure Permissions',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Permissions are needed to interact with other apps.',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              children: [
                _buildSectionHeader('MANDATORY', isDark),
                _buildPermissionCard(
                  'Screen Control (Accessibility)',
                  'Allows the AI to read your screen and automatically perform clicks, scrolls, and typing to execute tasks across other apps on your phone.',
                  Icons.visibility_rounded,
                  _isAccessibilityGranted,
                  _requestAccessibility,
                  isDark,
                ),
                const SizedBox(height: 12),
                _buildPermissionCard(
                  'Microphone',
                  'Required to listen to your voice commands and convert speech to text.',
                  Icons.mic_rounded,
                  _isMicrophoneGranted,
                  () => _requestPermission(Permission.microphone),
                  isDark,
                ),
                if (FeatureFlags.floatingOverlayEnabled) ...[
                  const SizedBox(height: 12),
                  _buildPermissionCard(
                    'Display Over Other Apps (Floating Bubble)',
                    'Allows PrivateAgent to show a floating overlay bubble when backgrounded or executing a task so you can monitor progress and execute actions.',
                    Icons.layers_rounded,
                    _isOverlayGranted,
                    _requestOverlayPermission,
                    isDark,
                  ),
                ],
                const SizedBox(height: 12),
                _buildPermissionCard(
                  'Notifications',
                  'Required for the ongoing "listening" indicator voice features show while active — not just task-complete alerts. Without this, background voice features can be silently demoted by Android.',
                  Icons.notifications_rounded,
                  _isNotificationsGranted,
                  () => _requestPermission(Permission.notification),
                  isDark,
                ),
                const SizedBox(height: 12),
                _buildPermissionCard(
                  'Battery Optimization',
                  'Allow PrivateAgent to run in the background so it can hear your wake word later. Android may not let every app request this — if declined, voice features still work via the mic button.',
                  Icons.battery_charging_full_rounded,
                  _isBatteryUnrestricted,
                  () => _requestPermission(Permission.ignoreBatteryOptimizations),
                  isDark,
                ),
                const SizedBox(height: 20),
                _buildSectionHeader('OPTIONAL', isDark),
                _buildPermissionCard(
                  'Contacts',
                  'Used to look up phone numbers and contact names when you ask the AI to call or text someone.',
                  Icons.contacts_rounded,
                  _isContactsGranted,
                  () => _requestPermission(Permission.contacts),
                  isDark,
                ),
                const SizedBox(height: 12),
                _buildPermissionCard(
                  'Phone',
                  'Enables the AI to dial phone calls on your behalf when requested.',
                  Icons.phone_rounded,
                  _isPhoneGranted,
                  () => _requestPermission(Permission.phone),
                  isDark,
                ),
                const SizedBox(height: 12),
                _buildPermissionCard(
                  'SMS',
                  'Allows the AI to send and read text messages on your behalf when requested.',
                  Icons.sms_rounded,
                  _isSmsGranted,
                  () => _requestPermission(Permission.sms),
                  isDark,
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),

          // Bottom Navigation Row
          Row(
            children: [
              TextButton(
                onPressed: () {
                  _pageController.previousPage(
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                  );
                },
                style: TextButton.styleFrom(
                  foregroundColor: isDark
                      ? Colors.white
                      : const Color(0xFF475569),
                ),
                child: const Text(
                  'Back',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const Spacer(),
              Container(
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: _canProceedFromPermissions
                      ? Theme.of(context).colorScheme.primary
                      : (isDark
                            ? const Color(0xFF1E293B)
                            : const Color(0xFFE2E8F0)),
                  boxShadow: _canProceedFromPermissions
                      ? [
                          BoxShadow(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withOpacity(0.25),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
                ),
                child: ElevatedButton(
                  onPressed: _canProceedFromPermissions
                      ? () {
                          _pageController.nextPage(
                            duration: const Duration(milliseconds: 400),
                            curve: Curves.easeOutCubic,
                          );
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    shadowColor: Colors.transparent,
                    disabledForegroundColor: isDark
                        ? const Color(0xFF475569)
                        : const Color(0xFF94A3B8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                  ),
                  child: const Row(
                    children: [
                      Text(
                        'Next',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SizedBox(width: 8),
                      Icon(Icons.arrow_forward_rounded, size: 16),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4, left: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _buildPermissionCard(
    String title,
    String description,
    IconData icon,
    bool isGranted,
    VoidCallback onGrant,
    bool isDark,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isGranted
              ? Colors.green.withOpacity(0.3)
              : Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.2 : 0.03),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      icon,
                      size: 20,
                      color: Theme.of(context).primaryColor,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (isGranted)
                    const Icon(
                      Icons.check_circle_rounded,
                      color: Colors.green,
                      size: 24,
                    )
                  else
                    ElevatedButton(
                      onPressed: onGrant,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        minimumSize: const Size(60, 36),
                      ),
                      child: const Text(
                        'Grant',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                description,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF475569),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- STEP 3: MODEL SETUP SCREEN ---
  Widget _buildModelSetupPage(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          const Text(
            'Configure AI Model',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Select a provider to prefill API details automatically.',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 20),

          // Providers Grid/List
          SizedBox(
            height: 90,
            child: ListView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              children: [
                _buildProviderCard(
                  'deepseek',
                  'DeepSeek',
                  Icons.analytics_rounded,
                  isDark,
                ),
                const SizedBox(width: 10),
                _buildProviderCard('groq', 'Groq', Icons.speed_rounded, isDark),
                const SizedBox(width: 10),
                _buildProviderCard(
                  'nvidia',
                  'NVIDIA',
                  Icons.memory_rounded,
                  isDark,
                ),
                const SizedBox(width: 10),
                _buildProviderCard(
                  'google',
                  'Google AI',
                  Icons.auto_awesome_rounded,
                  isDark,
                ),
                const SizedBox(width: 10),
                _buildProviderCard(
                  'ollama',
                  'Ollama',
                  Icons.computer_rounded,
                  isDark,
                ),
                const SizedBox(width: 10),
                _buildProviderCard(
                  'local',
                  'Local Server',
                  Icons.dns_rounded,
                  isDark,
                ),
                const SizedBox(width: 10),
                _buildProviderCard(
                  'custom',
                  'Custom',
                  Icons.settings_suggest_rounded,
                  isDark,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              children: [
                if (_selectedProvider != 'ollama' &&
                    _selectedProvider != 'local') ...[
                  _buildFormTextField(
                    controller: _apiKeyController,
                    label: 'API Key',
                    hint: 'sk-xxxxxxxxxxxx',
                    obscure: _obscureKey,
                    isDark: isDark,
                    suffix: IconButton(
                      icon: Icon(
                        _obscureKey
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        color: Colors.grey,
                      ),
                      onPressed: () =>
                          setState(() => _obscureKey = !_obscureKey),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                _buildFormTextField(
                  controller: _baseUrlController,
                  label: 'API Base URL',
                  hint: 'https://api.deepseek.com',
                  isDark: isDark,
                ),
                const SizedBox(height: 16),
                _buildFormTextField(
                  controller: _modelController,
                  label: 'Model Name',
                  hint: 'deepseek-chat',
                  isDark: isDark,
                  suffix: IconButton(
                    icon: _isValidating
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                isDark ? Colors.white : Colors.black,
                              ),
                            ),
                          )
                        : Icon(
                            Icons.sync_rounded,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                    tooltip: 'Fetch models list',
                    onPressed: _isValidating ? null : _fetchModels,
                  ),
                ),

                if (_validationError != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.redAccent.withOpacity(0.2),
                      ),
                    ),
                    child: Text(
                      _validationError!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
              ],
            ),
          ),

          // Action Buttons Row
          Row(
            children: [
              TextButton(
                onPressed: _isValidating
                    ? null
                    : () {
                        _pageController.previousPage(
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeOutCubic,
                        );
                      },
                style: TextButton.styleFrom(
                  foregroundColor: isDark
                      ? Colors.white
                      : const Color(0xFF475569),
                ),
                child: const Text(
                  'Back',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const Spacer(),
              Container(
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: _isValidating
                      ? (isDark
                            ? const Color(0xFF1E293B)
                            : const Color(0xFFE2E8F0))
                      : Theme.of(context).colorScheme.primary,
                  boxShadow: _isValidating
                      ? null
                      : [
                          BoxShadow(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withOpacity(0.25),
                            blurRadius: 12,
                            offset: const Offset(0, 5),
                          ),
                        ],
                ),
                child: ElevatedButton(
                  onPressed: _isValidating ? null : _validateAiConfig,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    shadowColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                  ),
                  child: _isValidating
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        )
                      : const Row(
                          children: [
                            Text(
                              'Continue',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            SizedBox(width: 8),
                            Icon(Icons.arrow_forward_rounded, size: 16),
                          ],
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildProviderCard(
    String id,
    String label,
    IconData icon,
    bool isDark,
  ) {
    final isSelected = _selectedProvider == id;

    return Container(
      width: 104,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
          width: isSelected ? 2 : 1.2,
        ),
        boxShadow: isSelected
            ? [
                BoxShadow(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withOpacity(0.15),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        color: isSelected
            ? Theme.of(context).colorScheme.primary.withOpacity(0.12)
            : Theme.of(context).colorScheme.surface,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _selectProvider(id),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 26,
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : (isDark ? Colors.grey[400] : Colors.grey[600]),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : (isDark ? Colors.grey[300] : Colors.grey[700]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFormTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool obscure = false,
    Widget? suffix,
    required bool isDark,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.15 : 0.02),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            fontSize: 13,
            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
          ),
          hintText: hint,
          hintStyle: TextStyle(
            fontSize: 13,
            color: isDark ? Colors.grey[700] : Colors.grey[400],
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
          border: InputBorder.none,
          suffixIcon: suffix,
        ),
      ),
    );
  }
}
