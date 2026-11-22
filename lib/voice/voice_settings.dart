import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/secret_store.dart';
import '../settings/user_settings.dart';

/// Speech-to-Text engine backend.
enum VoiceSttEngine {
  /// Built-in local AI model (SenseVoiceSmall ONNX via sherpa-onnx: free,
  /// offline, high accuracy for Chinese & English, automatic punctuation).
  localAi,

  /// Built-in legacy OS offline speech recognition (Windows SAPI).
  system,

  /// Custom OpenAI-compatible `/audio/transcriptions` endpoint (Whisper, etc.).
  openaiCompatible;

  static VoiceSttEngine get platformDefault =>
      !kIsWeb && Platform.isWindows ? localAi : system;

  static VoiceSttEngine parse(Object? raw) => switch (raw) {
    'localAi' => localAi,
    'system' => system,
    'openaiCompatible' => openaiCompatible,
    _ => platformDefault,
  };
}

/// Text-to-Speech engine backend.
enum VoiceTtsEngine {
  /// Free Microsoft Edge Neural TTS (lifelike Chinese/English/Japanese voices,
  /// falls back to OS system TTS automatically when offline).
  edgeNeural,

  /// Built-in OS speech synthesis (Windows SAPI / macOS `say` / Linux espeak).
  system,

  /// Custom OpenAI-compatible `/audio/speech` endpoint.
  openaiCompatible;

  static VoiceTtsEngine get platformDefault =>
      !kIsWeb && Platform.isWindows ? edgeNeural : system;

  static VoiceTtsEngine parse(Object? raw) => switch (raw) {
    'edgeNeural' => edgeNeural,
    'system' => system,
    'openaiCompatible' => openaiCompatible,
    _ => platformDefault,
  };
}

/// Persisted voice configuration under `voice.*` keys in `settings.json`.
/// API keys are stored separately in [SecretStore] (OS keychain / DPAPI).
@immutable
class VoiceConfig {
  const VoiceConfig({
    this.enabled = true,
    this.conversationMode = false,
    this.sttEngine = VoiceSttEngine.system,
    this.sttLanguage = 'zh-CN',
    this.sttHotkey = defaultSttHotkey,
    this.sttStreaming = true,
    this.sttAiCorrect = true,
    this.sttVadAutoStop = false,
    this.sttVadSilenceMs = defaultVadSilenceMs,
    this.sttGlossary = '',
    this.sttAutoSend = false,
    this.sttApiBaseUrl = defaultApiBaseUrl,
    this.sttModel = defaultSttModel,
    this.ttsEngine = VoiceTtsEngine.system,
    this.ttsEdgeVoice = defaultEdgeVoice,
    this.ttsVoice = '',
    this.ttsRate = 1.0,
    this.ttsAutoRead = false,
    this.ttsApiBaseUrl = defaultApiBaseUrl,
    this.ttsModel = defaultTtsModel,
    this.ttsApiVoice = defaultTtsApiVoice,
    this.completionAnnouncement = false,
  });

  static const defaultSttHotkey = 'alt+shift+v';
  static const defaultVadSilenceMs = 1800;
  static const defaultEdgeVoice = 'zh-CN-XiaoxiaoNeural';
  static const defaultApiBaseUrl = 'https://api.openai.com/v1';
  static const defaultSttModel = 'whisper-1';
  static const defaultTtsModel = 'tts-1';
  static const defaultTtsApiVoice = 'alloy';

  static const enabledKey = 'voice.enabled';
  static const conversationModeKey = 'voice.conversationMode';
  static const sttEngineKey = 'voice.stt.engine';
  static const sttLanguageKey = 'voice.stt.language';
  static const sttHotkeyKey = 'voice.stt.hotkey';
  static const sttStreamingKey = 'voice.stt.streaming';
  static const sttAiCorrectKey = 'voice.stt.aiCorrect';
  static const sttVadAutoStopKey = 'voice.stt.vadAutoStop';
  static const sttVadSilenceMsKey = 'voice.stt.vadSilenceMs';
  static const sttGlossaryKey = 'voice.stt.glossary';
  static const sttAutoSendKey = 'voice.stt.autoSend';
  static const sttApiBaseUrlKey = 'voice.stt.apiBaseUrl';
  static const sttModelKey = 'voice.stt.model';
  static const ttsEngineKey = 'voice.tts.engine';
  static const ttsEdgeVoiceKey = 'voice.tts.edgeVoice';
  static const ttsVoiceKey = 'voice.tts.voice';
  static const ttsRateKey = 'voice.tts.rate';
  static const ttsAutoReadKey = 'voice.tts.autoRead';
  static const ttsApiBaseUrlKey = 'voice.tts.apiBaseUrl';
  static const ttsModelKey = 'voice.tts.model';
  static const ttsApiVoiceKey = 'voice.tts.apiVoice';
  static const completionAnnouncementKey = 'voice.notifications.announcement';

  /// SecretStore keys (never written into settings.json).
  static const sttApiKeySecretId = 'ayte.voice.stt.apiKey';
  static const ttsApiKeySecretId = 'ayte.voice.tts.apiKey';

  static const defaults = VoiceConfig();

  static const supportedLanguages = <({String code, String zh, String en})>[
    (code: 'zh-CN', zh: '中文（简体）', en: 'Chinese (Simplified)'),
    (code: 'en-US', zh: '英语（美国）', en: 'English (US)'),
    (code: 'ja-JP', zh: '日语', en: 'Japanese'),
    (code: 'auto', zh: '自动检测', en: 'Auto-detect'),
  ];

  static const edgeVoices = <({String id, String zh, String en})>[
    (id: 'zh-CN-XiaoxiaoNeural', zh: '晓晓（自然温柔女声）', en: 'Xiaoxiao (Chinese Female)'),
    (id: 'zh-CN-YunxiNeural', zh: '云希（阳光自然男声）', en: 'Yunxi (Chinese Male)'),
    (id: 'zh-CN-XiaoyiNeural', zh: '晓伊（清晰活泼女声）', en: 'Xiaoyi (Chinese Female)'),
    (id: 'zh-CN-YunjianNeural', zh: '云健（沉稳播音男声）', en: 'Yunjian (Chinese Male)'),
    (id: 'zh-CN-XiaochenNeural', zh: '晓辰（亲切自然女声）', en: 'Xiaochen (Chinese Female)'),
    (
      id: 'zh-CN-liaoning-XiaobeiNeural',
      zh: '晓北（东北方言女声）',
      en: 'Xiaobei (Dongbei Female)',
    ),
    (id: 'zh-TW-HsiaoChenNeural', zh: '晓臻（台湾自然女声）', en: 'HsiaoChen (Taiwan Female)'),
    (id: 'en-US-AriaNeural', zh: 'Aria（美式英语女声）', en: 'Aria (English US Female)'),
    (id: 'en-US-GuyNeural', zh: 'Guy（美式英语男声）', en: 'Guy (English US Male)'),
    (id: 'ja-JP-NanamiNeural', zh: 'Nanami（日语女声）', en: 'Nanami (Japanese Female)'),
  ];

  static const vadSilenceOptionsMs = <int>[1200, 1500, 1800, 2200, 3000];

  static const openaiVoices = <String>[
    'alloy',
    'ash',
    'coral',
    'echo',
    'fable',
    'nova',
    'onyx',
    'sage',
    'shimmer',
  ];

  static const rateSteps = <double>[0.75, 0.9, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0];

  final bool enabled;
  final bool conversationMode;
  final VoiceSttEngine sttEngine;
  final String sttLanguage;
  final String sttHotkey;
  final bool sttStreaming;
  final bool sttAiCorrect;
  final bool sttVadAutoStop;
  final int sttVadSilenceMs;
  final String sttGlossary;
  final bool sttAutoSend;
  final String sttApiBaseUrl;
  final String sttModel;
  final VoiceTtsEngine ttsEngine;
  final String ttsEdgeVoice;
  final String ttsVoice;
  final double ttsRate;
  final bool ttsAutoRead;
  final String ttsApiBaseUrl;
  final String ttsModel;
  final String ttsApiVoice;
  final bool completionAnnouncement;

  /// Effective hands-free behaviors: Conversation Mode activates all three.
  bool get effectiveVadAutoStop => sttVadAutoStop || conversationMode;
  bool get effectiveAutoSend => sttAutoSend || conversationMode;
  bool get effectiveAutoRead => ttsAutoRead || conversationMode;

  factory VoiceConfig.fromSettings(Object? Function(String key) read) {
    final rawRate = read(ttsRateKey);
    final rate = switch (rawRate) {
      final num n => n.toDouble().clamp(0.5, 2.0),
      _ => defaults.ttsRate,
    };
    final rawSilence = read(sttVadSilenceMsKey);
    final silenceMs = switch (rawSilence) {
      final num n => n.toInt().clamp(800, 5000),
      _ => defaultVadSilenceMs,
    };
    return VoiceConfig(
      enabled: read(enabledKey) != false,
      conversationMode: read(conversationModeKey) == true,
      sttEngine: VoiceSttEngine.parse(read(sttEngineKey)),
      sttLanguage: _nonEmptyString(read(sttLanguageKey), defaults.sttLanguage),
      sttHotkey: read(sttHotkeyKey) is String
          ? (read(sttHotkeyKey) as String).trim()
          : defaults.sttHotkey,
      sttStreaming: read(sttStreamingKey) != false,
      sttAiCorrect: read(sttAiCorrectKey) != false,
      sttVadAutoStop: read(sttVadAutoStopKey) == true,
      sttVadSilenceMs: silenceMs,
      sttGlossary: read(sttGlossaryKey) is String
          ? (read(sttGlossaryKey) as String).trim()
          : '',
      sttAutoSend: read(sttAutoSendKey) == true,
      sttApiBaseUrl: _nonEmptyString(
        read(sttApiBaseUrlKey),
        defaults.sttApiBaseUrl,
      ),
      sttModel: _nonEmptyString(read(sttModelKey), defaults.sttModel),
      ttsEngine: VoiceTtsEngine.parse(read(ttsEngineKey)),
      ttsEdgeVoice: _nonEmptyString(
        read(ttsEdgeVoiceKey),
        defaults.ttsEdgeVoice,
      ),
      ttsVoice: read(ttsVoiceKey) is String
          ? (read(ttsVoiceKey) as String).trim()
          : defaults.ttsVoice,
      ttsRate: rate,
      ttsAutoRead: read(ttsAutoReadKey) == true,
      ttsApiBaseUrl: _nonEmptyString(
        read(ttsApiBaseUrlKey),
        defaults.ttsApiBaseUrl,
      ),
      ttsModel: _nonEmptyString(read(ttsModelKey), defaults.ttsModel),
      ttsApiVoice: _nonEmptyString(read(ttsApiVoiceKey), defaults.ttsApiVoice),
      completionAnnouncement: read(completionAnnouncementKey) == true,
    );
  }

  static String _nonEmptyString(Object? value, String fallback) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return fallback;
  }

  VoiceConfig copyWith({
    bool? enabled,
    bool? conversationMode,
    VoiceSttEngine? sttEngine,
    String? sttLanguage,
    String? sttHotkey,
    bool? sttStreaming,
    bool? sttAiCorrect,
    bool? sttVadAutoStop,
    int? sttVadSilenceMs,
    String? sttGlossary,
    bool? sttAutoSend,
    String? sttApiBaseUrl,
    String? sttModel,
    VoiceTtsEngine? ttsEngine,
    String? ttsEdgeVoice,
    String? ttsVoice,
    double? ttsRate,
    bool? ttsAutoRead,
    String? ttsApiBaseUrl,
    String? ttsModel,
    String? ttsApiVoice,
    bool? completionAnnouncement,
  }) => VoiceConfig(
    enabled: enabled ?? this.enabled,
    conversationMode: conversationMode ?? this.conversationMode,
    sttEngine: sttEngine ?? this.sttEngine,
    sttLanguage: sttLanguage ?? this.sttLanguage,
    sttHotkey: sttHotkey ?? this.sttHotkey,
    sttStreaming: sttStreaming ?? this.sttStreaming,
    sttAiCorrect: sttAiCorrect ?? this.sttAiCorrect,
    sttVadAutoStop: sttVadAutoStop ?? this.sttVadAutoStop,
    sttVadSilenceMs: sttVadSilenceMs ?? this.sttVadSilenceMs,
    sttGlossary: sttGlossary ?? this.sttGlossary,
    sttAutoSend: sttAutoSend ?? this.sttAutoSend,
    sttApiBaseUrl: sttApiBaseUrl ?? this.sttApiBaseUrl,
    sttModel: sttModel ?? this.sttModel,
    ttsEngine: ttsEngine ?? this.ttsEngine,
    ttsEdgeVoice: ttsEdgeVoice ?? this.ttsEdgeVoice,
    ttsVoice: ttsVoice ?? this.ttsVoice,
    ttsRate: ttsRate ?? this.ttsRate,
    ttsAutoRead: ttsAutoRead ?? this.ttsAutoRead,
    ttsApiBaseUrl: ttsApiBaseUrl ?? this.ttsApiBaseUrl,
    ttsModel: ttsModel ?? this.ttsModel,
    ttsApiVoice: ttsApiVoice ?? this.ttsApiVoice,
    completionAnnouncement:
        completionAnnouncement ?? this.completionAnnouncement,
  );

  /// Converts to settings.json entries, returning `null` for default values so
  /// settings.json stays clean.
  Map<String, Object?> toSettingsMap() => {
    enabledKey: enabled == defaults.enabled ? null : enabled,
    conversationModeKey: conversationMode == defaults.conversationMode
        ? null
        : conversationMode,
    sttEngineKey:
        sttEngine == VoiceSttEngine.platformDefault ? null : sttEngine.name,
    sttLanguageKey: sttLanguage == defaults.sttLanguage ? null : sttLanguage,
    sttHotkeyKey: sttHotkey == defaults.sttHotkey ? null : sttHotkey,
    sttStreamingKey: sttStreaming == defaults.sttStreaming ? null : sttStreaming,
    sttAiCorrectKey: sttAiCorrect == defaults.sttAiCorrect ? null : sttAiCorrect,
    sttVadAutoStopKey:
        sttVadAutoStop == defaults.sttVadAutoStop ? null : sttVadAutoStop,
    sttVadSilenceMsKey:
        sttVadSilenceMs == defaults.sttVadSilenceMs ? null : sttVadSilenceMs,
    sttGlossaryKey: sttGlossary == defaults.sttGlossary ? null : sttGlossary,
    sttAutoSendKey: sttAutoSend == defaults.sttAutoSend ? null : sttAutoSend,
    sttApiBaseUrlKey:
        sttApiBaseUrl == defaults.sttApiBaseUrl ? null : sttApiBaseUrl,
    sttModelKey: sttModel == defaults.sttModel ? null : sttModel,
    ttsEngineKey:
        ttsEngine == VoiceTtsEngine.platformDefault ? null : ttsEngine.name,
    ttsEdgeVoiceKey: ttsEdgeVoice == defaults.ttsEdgeVoice ? null : ttsEdgeVoice,
    ttsVoiceKey: ttsVoice == defaults.ttsVoice ? null : ttsVoice,
    ttsRateKey: ttsRate == defaults.ttsRate ? null : ttsRate,
    ttsAutoReadKey: ttsAutoRead == defaults.ttsAutoRead ? null : ttsAutoRead,
    ttsApiBaseUrlKey:
        ttsApiBaseUrl == defaults.ttsApiBaseUrl ? null : ttsApiBaseUrl,
    ttsModelKey: ttsModel == defaults.ttsModel ? null : ttsModel,
    ttsApiVoiceKey: ttsApiVoice == defaults.ttsApiVoice ? null : ttsApiVoice,
    completionAnnouncementKey:
        completionAnnouncement == defaults.completionAnnouncement
        ? null
        : completionAnnouncement,
  };

  @override
  bool operator ==(Object other) =>
      other is VoiceConfig &&
      other.enabled == enabled &&
      other.conversationMode == conversationMode &&
      other.sttEngine == sttEngine &&
      other.sttLanguage == sttLanguage &&
      other.sttHotkey == sttHotkey &&
      other.sttStreaming == sttStreaming &&
      other.sttAiCorrect == sttAiCorrect &&
      other.sttVadAutoStop == sttVadAutoStop &&
      other.sttVadSilenceMs == sttVadSilenceMs &&
      other.sttGlossary == sttGlossary &&
      other.sttAutoSend == sttAutoSend &&
      other.sttApiBaseUrl == sttApiBaseUrl &&
      other.sttModel == sttModel &&
      other.ttsEngine == ttsEngine &&
      other.ttsEdgeVoice == ttsEdgeVoice &&
      other.ttsVoice == ttsVoice &&
      other.ttsRate == ttsRate &&
      other.ttsAutoRead == ttsAutoRead &&
      other.ttsApiBaseUrl == ttsApiBaseUrl &&
      other.ttsModel == ttsModel &&
      other.ttsApiVoice == ttsApiVoice &&
      other.completionAnnouncement == completionAnnouncement;

  @override
  int get hashCode => Object.hashAll([
    enabled,
    conversationMode,
    sttEngine,
    sttLanguage,
    sttHotkey,
    sttStreaming,
    sttAiCorrect,
    sttVadAutoStop,
    sttVadSilenceMs,
    sttGlossary,
    sttAutoSend,
    sttApiBaseUrl,
    sttModel,
    ttsEngine,
    ttsEdgeVoice,
    ttsVoice,
    ttsRate,
    ttsAutoRead,
    ttsApiBaseUrl,
    ttsModel,
    ttsApiVoice,
    completionAnnouncement,
  ]);
}

/// Manages [VoiceConfig] synchronized with `settings.json` and secure API keys
/// stored in [SecretStore].
class VoiceSettingsStore extends ChangeNotifier {
  // ignore: prefer_initializing_formals
  VoiceSettingsStore({SecretStore? secrets}) : _secrets = secrets;

  static final VoiceSettingsStore instance = VoiceSettingsStore();

  final SecretStore? _secrets;
  SecretStore get _secretStore => _secrets ?? SecretStore.instance;

  VoiceConfig _config = VoiceConfig(
    sttEngine: VoiceSttEngine.platformDefault,
    ttsEngine: VoiceTtsEngine.platformDefault,
  );
  UserSettings? _userSettings;
  void Function(bool)? _onCompletionAnnouncementSync;

  VoiceConfig get config => _config;

  /// Connects this store to [settings] so changes in `settings.json` flow in
  /// and saves write back.
  void follow(
    UserSettings settings, {
    void Function(bool enabled)? onCompletionAnnouncementChanged,
  }) {
    _userSettings?.removeListener(_reload);
    _userSettings = settings;
    _onCompletionAnnouncementSync = onCompletionAnnouncementChanged;
    settings.addListener(_reload);
    _reload();
  }

  void _reload() {
    final settings = _userSettings;
    if (settings == null) return;
    final next = VoiceConfig.fromSettings((key) => settings[key]);
    if (next == _config) return;
    _config = next;
    _onCompletionAnnouncementSync?.call(next.completionAnnouncement);
    notifyListeners();
  }

  /// Updates the in-memory config and persists modified keys to `settings.json`.
  Future<void> save(VoiceConfig next, {UserSettings? settings}) async {
    final prev = _config;
    _config = next;
    if (prev.completionAnnouncement != next.completionAnnouncement) {
      _onCompletionAnnouncementSync?.call(next.completionAnnouncement);
    }
    notifyListeners();

    final target = settings ?? _userSettings;
    if (target == null) return;
    final prevMap = prev.toSettingsMap();
    final nextMap = next.toSettingsMap();
    for (final entry in nextMap.entries) {
      if (prevMap[entry.key] != entry.value) {
        try {
          await target.update(entry.key, entry.value);
        } on Object catch (error) {
          debugPrint('${entry.key} not kept: $error');
        }
      }
    }
  }

  Future<String?> readSttApiKey() => _safeReadSecret(VoiceConfig.sttApiKeySecretId);

  Future<String?> readTtsApiKey() => _safeReadSecret(VoiceConfig.ttsApiKeySecretId);

  Future<void> writeSttApiKey(String value) =>
      _safeWriteSecret(VoiceConfig.sttApiKeySecretId, value);

  Future<void> writeTtsApiKey(String value) =>
      _safeWriteSecret(VoiceConfig.ttsApiKeySecretId, value);

  Future<String?> _safeReadSecret(String id) async {
    try {
      final value = await _secretStore.read(id);
      if (value == null || value.trim().isEmpty) return null;
      return value.trim();
    } on SecretStoreException catch (error) {
      debugPrint('Voice secret read failed ($id): $error');
      return null;
    }
  }

  Future<void> _safeWriteSecret(String id, String value) async {
    final trimmed = value.trim();
    try {
      if (trimmed.isEmpty) {
        await _secretStore.delete(id);
      } else {
        await _secretStore.write(id, trimmed);
      }
    } on SecretStoreException catch (error) {
      debugPrint('Voice secret write failed ($id): $error');
      rethrow;
    }
  }

  @visibleForTesting
  void resetForTest([VoiceConfig? config]) {
    _userSettings?.removeListener(_reload);
    _userSettings = null;
    _config =
        config ??
        VoiceConfig(
          sttEngine: VoiceSttEngine.platformDefault,
          ttsEngine: VoiceTtsEngine.platformDefault,
        );
    notifyListeners();
  }
}
