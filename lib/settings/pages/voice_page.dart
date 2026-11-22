import 'dart:async';

import 'package:bao_editor/monaco/flutter/keybinding_entry.dart'
    show KeybindingPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_menu.dart';
import '../../ide/ide_quick_input.dart' show IdeKeycap;
import '../../keybindings/key_chord.dart';
import '../../platform/app_platform.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../voice/voice_hotkey.dart';
import '../../voice/voice_model_installer.dart';
import '../../voice/voice_settings.dart';
import '../../voice/voice_stt_service.dart';
import '../../voice/voice_tts_service.dart';
import '../../voice/wav_recorder.dart';
import '../user_settings.dart';
import 'settings_dropdown.dart';
import 'settings_widgets.dart';
import 'stash_hotkey_field.dart' show StashHotkeyField;

/// Settings → Voice: configure Speech-to-Text (system built-in or OpenAI-
/// compatible Whisper API) and Text-to-Speech (system voice or OpenAI-
/// compatible TTS API).
class VoiceSettingsPage extends StatefulWidget {
  const VoiceSettingsPage({super.key, this.settings});

  final UserSettings? settings;

  @override
  State<VoiceSettingsPage> createState() => _VoiceSettingsPageState();
}

class _VoiceSettingsPageState extends State<VoiceSettingsPage> {
  final _sttKeyController = TextEditingController();
  final _ttsKeyController = TextEditingController();

  List<SystemVoiceInfo> _systemVoices = const [];
  List<VoiceInputDevice> _inputDevices = const [];
  bool _hasSttKey = false;
  bool _hasTtsKey = false;
  String? _sttTestResult;
  String? _keyStatus;

  VoiceSettingsStore get _store => VoiceSettingsStore.instance;
  VoiceSttService get _stt => VoiceSttService.instance;
  VoiceTtsService get _tts => VoiceTtsService.instance;
  VoiceModelInstaller get _installer => VoiceModelInstaller.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAsync());
  }

  Future<void> _loadAsync() async {
    final results = await Future.wait([
      _tts.listSystemVoices(),
      WavRecorder.listInputDevices(),
      _store.readSttApiKey(),
      _store.readTtsApiKey(),
    ]);
    if (!mounted) return;
    setState(() {
      _systemVoices = results[0] as List<SystemVoiceInfo>;
      _inputDevices = results[1] as List<VoiceInputDevice>;
      _hasSttKey = (results[2] as String?)?.isNotEmpty == true;
      _hasTtsKey = (results[3] as String?)?.isNotEmpty == true;
    });
  }

  @override
  void dispose() {
    _sttKeyController.dispose();
    _ttsKeyController.dispose();
    super.dispose();
  }

  Future<void> _update(VoiceConfig next) =>
      _store.save(next, settings: widget.settings);

  Future<void> _saveSttKey(bool isZh) async {
    final text = _sttKeyController.text.trim();
    try {
      await _store.writeSttApiKey(text);
      if (!mounted) return;
      _sttKeyController.clear();
      setState(() {
        _hasSttKey = text.isNotEmpty;
        _keyStatus = text.isEmpty
            ? (isZh ? '已清除语音识别 API Key' : 'Cleared STT API key')
            : (isZh ? '语音识别 API Key 已安全保存至系统凭据库' : 'STT API key saved securely');
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _keyStatus = e.toString());
    }
  }

  Future<void> _saveTtsKey(bool isZh) async {
    final text = _ttsKeyController.text.trim();
    try {
      await _store.writeTtsApiKey(text);
      if (!mounted) return;
      _ttsKeyController.clear();
      setState(() {
        _hasTtsKey = text.isNotEmpty;
        _keyStatus = text.isEmpty
            ? (isZh ? '已清除语音合成 API Key' : 'Cleared TTS API key')
            : (isZh ? '语音合成 API Key 已安全保存至系统凭据库' : 'TTS API key saved securely');
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _keyStatus = e.toString());
    }
  }

  Future<void> _toggleSttTest(bool isZh) async {
    if (_stt.isListening) {
      final result = await _stt.stop();
      if (!mounted) return;
      setState(() {
        if (result.error != null && result.text.isEmpty) {
          _sttTestResult = result.error;
        } else if (result.hasText) {
          _sttTestResult = isZh
              ? '识别结果：${result.text}'
              : 'Transcript: ${result.text}';
        } else {
          _sttTestResult = isZh ? '未识别到语音内容' : 'No speech detected';
        }
      });
      return;
    }
    setState(() => _sttTestResult = null);
    final ok = await _stt.start(owner: this);
    if (!ok && mounted) {
      setState(() => _sttTestResult = _stt.lastError);
    }
  }

  Future<void> _toggleTtsPreview(bool isZh) async {
    const previewId = '__voice_settings_preview__';
    if (_tts.isSpeakingId(previewId)) {
      await _tts.stop();
      return;
    }
    final sample = isZh
        ? '你好，我是 Ayte 语音助手，当前语音播报工作正常。'
        : 'Hello, this is Ayte voice playback. Text to speech is working.';
    await _tts.speak(sample, id: previewId, raw: true, isZh: isZh);
  }

  int _rateStepIndex(double rate) {
    var best = 0;
    var bestDiff = double.infinity;
    for (var i = 0; i < VoiceConfig.rateSteps.length; i++) {
      final diff = (VoiceConfig.rateSteps[i] - rate).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = i;
      }
    }
    return best;
  }

  String _hotkeyDescription(String spec, bool? taken, {required bool isZh}) {
    final label = VoiceHotkeyService.formatLabel(spec, mac: AppPlatform.isMacOS);
    final lines = <String>[
      if (label.isEmpty)
        (isZh
            ? '未设置全局快捷键。点击输入框并按下组合键即可录制（支持从任意应用唤起 Ayte 开始/结束语音输入）。'
            : 'No global shortcut set. Click the box and press a key combo to trigger voice input from any app.')
      else
        (isZh
            ? '在任意应用中按下 $label 可唤起 Ayte 并开始/结束语音输入（Esc 取消录制，Backspace 清除）。'
            : 'Press $label from any app to bring Ayte forward and toggle voice input (Esc cancels, Backspace clears).'),
      if (taken == false && label.isNotEmpty)
        (isZh
            ? '⚠ 该快捷键已被其他应用占用，请更换组合键。'
            : '⚠ Shortcut is already in use by another app. Choose another combo.'),
    ];
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    return ListenableBuilder(
      listenable: Listenable.merge([
        _store,
        _stt,
        _tts,
        _installer,
        VoiceHotkeyService.instance,
      ]),
      builder: (context, _) {
        final cfg = _store.config;
        final sttEngineLabel = switch (cfg.sttEngine) {
          VoiceSttEngine.localAi =>
            isZh
                ? '本地 AI 识别（SenseVoice · 推荐 · 免费离线高精度）'
                : 'Local AI (SenseVoice · Recommended)',
          VoiceSttEngine.system =>
            isZh ? '系统离线识别（SAPI · 备用）' : 'System Offline (SAPI)',
          VoiceSttEngine.openaiCompatible =>
            isZh ? 'OpenAI 兼容 API（Whisper / SenseVoice）' : 'OpenAI-compatible API',
        };
        final ttsEngineLabel = switch (cfg.ttsEngine) {
          VoiceTtsEngine.edgeNeural =>
            isZh
                ? '微软 Edge 神经网络（推荐 · 免费真人音色）'
                : 'Microsoft Edge Neural (Recommended · Free)',
          VoiceTtsEngine.system =>
            isZh ? '系统离线语音（SAPI · 断网可用）' : 'System Offline Voice',
          VoiceTtsEngine.openaiCompatible =>
            isZh ? 'OpenAI 兼容 TTS API' : 'OpenAI-compatible TTS API',
        };
        final edgeVoiceEntry = VoiceConfig.edgeVoices.firstWhere(
          (v) => v.id == cfg.ttsEdgeVoice,
          orElse: () => VoiceConfig.edgeVoices.first,
        );
        final edgeVoiceLabel = isZh ? edgeVoiceEntry.zh : edgeVoiceEntry.en;
        final vadSilenceLabel =
            '${(cfg.sttVadSilenceMs / 1000).toStringAsFixed(1)}s';
        final langEntry = VoiceConfig.supportedLanguages.firstWhere(
          (l) => l.code == cfg.sttLanguage,
          orElse: () => VoiceConfig.supportedLanguages.first,
        );
        final langLabel = isZh ? langEntry.zh : langEntry.en;
        final selectedDevice = _inputDevices
            .where((d) => d.id == cfg.sttInputDeviceId)
            .firstOrNull;
        final inputDeviceLabel = cfg.sttInputDeviceId < 0 ||
                selectedDevice == null
            ? (isZh ? '系统默认麦克风' : 'System Default Microphone')
            : selectedDevice.name;
        final voiceLabel = cfg.ttsVoice.isEmpty
            ? (isZh ? '自动（按语言匹配系统音色）' : 'Auto (match language)')
            : cfg.ttsVoice;
        final rateIndex = _rateStepIndex(cfg.ttsRate);
        final rateLabel = '${VoiceConfig.rateSteps[rateIndex]}x';
        final testingStt = _stt.isListening && identical(_stt.activeOwner, this);
        final previewingTts = _tts.isSpeakingId('__voice_settings_preview__');
        final localInstalled = _installer.isInstalled;
        final localInstalling = _installer.isInstalling;
        final installLocation = _installer.installedLocation;

        return SettingsPage(
          title: isZh ? '语音' : 'Voice',
          description: isZh
              ? '在对话输入框中说话转文字，并朗读 AI 回复或播报任务完成提醒。默认使用本地免费高精度 AI 识别与 Edge 真人音色，也支持自定义 OpenAI 兼容 API。'
              : 'Dictate prompts with your microphone and listen to AI replies. Uses local SenseVoice AI & Edge Neural voices by default, with optional OpenAI-compatible APIs.',
          children: [
            SettingsCard(
              children: [
                SettingsSwitchRow(
                  label: isZh ? '启用语音功能' : 'Enable Voice Features',
                  description: isZh
                      ? '在输入框工具栏显示麦克风与对话模式按钮，并在每条 AI 回复底部显示朗读按钮'
                      : 'Show microphone & conversation mode controls in the composer and speak buttons on replies',
                  value: cfg.enabled,
                  onChanged: (v) => unawaited(_update(cfg.copyWith(enabled: v))),
                ),
                SettingsSwitchRow(
                  label: isZh ? '连续语音对话模式' : 'Hands-Free Voice Conversation Mode',
                  description: isZh
                      ? '一键联动：说话停顿自动结束 → AI 纠错并自动发送 → 回复完成自动用真人音色朗读 → 读完自动重新开麦'
                      : 'Combines auto-stop on silence pause, AI correction + auto-send, auto-read replies & follow-up mic',
                  value: cfg.conversationMode,
                  enabled: cfg.enabled,
                  onChanged: (v) =>
                      unawaited(_update(cfg.copyWith(conversationMode: v))),
                ),
                SettingsSwitchRow(
                  label: isZh ? '语音操作提示音' : 'Voice Earcon Chimes',
                  description: isZh
                      ? '开麦、自动收麦和退出连续对话时播放极轻的提示音，免手对话时无需紧盯屏幕'
                      : 'Play subtle audio chimes when starting/stopping recording or exiting conversation mode',
                  value: cfg.earcons,
                  enabled: cfg.enabled,
                  onChanged: (v) =>
                      unawaited(_update(cfg.copyWith(earcons: v))),
                ),
              ],
            ),
            SettingsGroup(
              title: isZh
                  ? '本地语音组件（SenseVoice 识别 + Edge 真人音色）'
                  : 'Local Voice Runtime (SenseVoice + Edge Neural TTS)',
              children: [
                SettingsRow(
                  label: localInstalled && !localInstalling
                      ? (isZh ? '已安装就绪' : 'Installed & Ready')
                      : localInstalling
                      ? _installer.statusMessage
                      : (isZh ? '尚未安装本地语音包' : 'Local Voice Pack Not Installed'),
                  description: localInstalled && !localInstalling
                      ? (isZh
                            ? '离线高精度中英识别与微软 Edge 神经网络播报均已就绪${installLocation != null ? '（$installLocation）' : ''}'
                            : 'Offline SenseVoice STT and Edge Neural TTS are ready${installLocation != null ? ' ($installLocation)' : ''}')
                      : localInstalling
                      ? (_installer.stage == VoiceInstallStage.downloadingModel
                            ? '${VoiceModelInstaller.formatMb(_installer.downloadedBytes)} / ${VoiceModelInstaller.formatMb(_installer.totalBytes)}'
                                '${_installer.speedBytesPerSec > 0 ? ' · ${(_installer.speedBytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s' : ''}'
                            : (isZh
                                  ? '首次安装约需 1–2 分钟，支持断点续传与国内镜像加速…'
                                  : 'First-time setup takes ~1–2 minutes with automatic mirror fallback…'))
                      : _installer.stage == VoiceInstallStage.error &&
                            _installer.error != null
                      ? (isZh
                            ? '下载失败：${_installer.error}（已保留断点，点击重试可继续下载）'
                            : 'Download failed: ${_installer.error} (resumable)')
                      : (isZh
                            ? '一键在线下载独立 Python 运行时（sherpa-onnx + edge-tts）与 SenseVoiceSmall 离线模型（约 245 MB），支持国内镜像加速与断点续传'
                            : 'One-click online install of isolated Python runtime (sherpa-onnx + edge-tts) & SenseVoiceSmall model (~245 MB) with resume'),
                  trailing: localInstalling
                      ? IdeButton(
                          label: isZh ? '取消下载' : 'Cancel',
                          icon: Codicons.close,
                          secondary: true,
                          onPressed: _installer.cancel,
                        )
                      : localInstalled
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Codicons.check,
                              size: 14,
                              color: AppColors.accent,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              isZh ? '已就绪' : 'Ready',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.accent,
                              ),
                            ),
                          ],
                        )
                      : IdeButton(
                          label: _installer.stage == VoiceInstallStage.error
                              ? (isZh ? '重试在线下载' : 'Retry Download')
                              : (isZh ? '一键在线下载安装' : 'Download & Install'),
                          icon: Codicons.cloudDownload,
                          onPressed: () =>
                              unawaited(_installer.install(isZh: isZh)),
                        ),
                ),
                if (localInstalling)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _installer.progress > 0.02
                            ? _installer.progress
                            : null,
                        minHeight: 5,
                        backgroundColor: AppColors.border,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          AppColors.accent,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            SettingsGroup(
              title: isZh ? '语音输入（语音转文字 STT）' : 'Voice Input (Speech-to-Text)',
              children: [
                SettingsRow(
                  label: isZh ? '识别引擎' : 'Recognition Engine',
                  description: isZh
                      ? '推荐使用本地 SenseVoice AI 模型（免费离线、中英混输自动标点、0.1 秒出字、绝不重复）；也支持自定义 Whisper / 硅基流动等 API'
                      : 'Local SenseVoice AI is recommended (free, offline, accurate Chinese/English with punctuation). Also supports OpenAI-compatible APIs.',
                  trailing: SettingsDropdown(
                    current: sttEngineLabel,
                    semanticLabel: sttEngineLabel,
                    entries: () => [
                      IdeMenuAction(
                        isZh
                            ? '本地 AI 识别（SenseVoice · 推荐 · 免费离线高精度）'
                            : 'Local AI (SenseVoice · Recommended)',
                        checked: cfg.sttEngine == VoiceSttEngine.localAi,
                        onSelected: () => unawaited(
                          _update(
                            cfg.copyWith(sttEngine: VoiceSttEngine.localAi),
                          ),
                        ),
                      ),
                      IdeMenuAction(
                        isZh
                            ? 'OpenAI 兼容 API（Whisper / SenseVoice）'
                            : 'OpenAI-compatible API',
                        checked:
                            cfg.sttEngine == VoiceSttEngine.openaiCompatible,
                        onSelected: () => unawaited(
                          _update(
                            cfg.copyWith(
                              sttEngine: VoiceSttEngine.openaiCompatible,
                            ),
                          ),
                        ),
                      ),
                      IdeMenuAction(
                        isZh ? '系统离线识别（SAPI · 备用）' : 'System Offline (SAPI)',
                        checked: cfg.sttEngine == VoiceSttEngine.system,
                        onSelected: () => unawaited(
                          _update(
                            cfg.copyWith(sttEngine: VoiceSttEngine.system),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (AppPlatform.isWindows || AppPlatform.isMacOS)
                  SettingsRow(
                    label: isZh ? '麦克风输入设备' : 'Microphone Input Device',
                    description: isZh
                        ? '接有耳机麦、外置 USB 麦克风或虚拟声卡时可在此指定输入源'
                        : 'Select a specific microphone or keep the system default',
                    trailing: SettingsDropdown(
                      current: inputDeviceLabel,
                      semanticLabel: inputDeviceLabel,
                      entries: () => [
                        IdeMenuAction(
                          isZh ? '系统默认麦克风' : 'System Default Microphone',
                          checked: cfg.sttInputDeviceId < 0,
                          onSelected: () => unawaited(
                            _update(cfg.copyWith(sttInputDeviceId: -1)),
                          ),
                        ),
                        for (final dev in _inputDevices)
                          IdeMenuAction(
                            dev.name,
                            checked: cfg.sttInputDeviceId == dev.id,
                            onSelected: () => unawaited(
                              _update(cfg.copyWith(sttInputDeviceId: dev.id)),
                            ),
                          ),
                      ],
                    ),
                  ),
                SettingsRow(
                  label: isZh ? '识别语言' : 'Language',
                  description: isZh
                      ? '日常纯中文/中英混输建议选「中文」或「自动」；指定语言可避免短句被误判为粤语或日语'
                      : 'Pin a language (e.g. Chinese) to prevent short utterances from being misclassified',
                  trailing: SettingsDropdown(
                    current: langLabel,
                    semanticLabel: langLabel,
                    entries: () => [
                      for (final lang in VoiceConfig.supportedLanguages)
                        IdeMenuAction(
                          isZh ? lang.zh : lang.en,
                          checked: cfg.sttLanguage == lang.code,
                          onSelected: () => unawaited(
                            _update(cfg.copyWith(sttLanguage: lang.code)),
                          ),
                        ),
                    ],
                  ),
                ),
                SettingsSwitchRow(
                  label: isZh ? '边说边出字（实时流式输出）' : 'Live Streaming Dictation',
                  description: isZh
                      ? '说话过程中实时将识别文字直接写入输入框，无需等到停止录音'
                      : 'Stream recognized words directly into the composer while you speak',
                  value: cfg.sttStreaming,
                  enabled: cfg.enabled,
                  onChanged: (v) =>
                      unawaited(_update(cfg.copyWith(sttStreaming: v))),
                ),
                SettingsSwitchRow(
                  label: isZh ? '语音结束后 AI 自动纠错' : 'AI Auto-Correction After Dictation',
                  description: isZh
                      ? '结合上下文自动修正同音错别字（如“编书处”→“边输出”）、标点符号与英文术语大小写，按 Ctrl+Z 可撤销回原文'
                      : 'Fix homophones, punctuation, and tech terms using context after dictation (Ctrl+Z reverts to raw text)',
                  value: cfg.sttAiCorrect,
                  enabled: cfg.enabled,
                  onChanged: (v) =>
                      unawaited(_update(cfg.copyWith(sttAiCorrect: v))),
                ),
                if (cfg.sttAiCorrect)
                  SettingsRow(
                    label: isZh ? '常用术语 / 纠错热词' : 'Custom Glossary / Hotwords',
                    description: isZh
                        ? '逗号分隔的项目名或专业词汇，AI 纠错时会优先按这里的拼写修正'
                        : 'Comma-separated project or tech terms preferred during AI proofreading',
                    trailing: SettingsTextField(
                      value: cfg.sttGlossary,
                      semanticLabel: 'Voice Glossary',
                      hint: 'Ayte, Flutter, SenseVoice, FastAPI',
                      width: 260,
                      onSubmitted: (v) =>
                          unawaited(_update(cfg.copyWith(sttGlossary: v))),
                    ),
                  ),
                SettingsSwitchRow(
                  label: isZh ? '说完停顿自动结束录音（VAD）' : 'Auto-stop on Silence Pause (VAD)',
                  description: isZh
                      ? '检测到你停止说话达到设定静音时长后自动完成录音，无需手动再点结束'
                      : 'Automatically finishes recording once you pause speaking',
                  value: cfg.sttVadAutoStop,
                  enabled: cfg.enabled,
                  onChanged: (v) =>
                      unawaited(_update(cfg.copyWith(sttVadAutoStop: v))),
                ),
                if (cfg.effectiveVadAutoStop)
                  SettingsRow(
                    label: isZh ? '停顿自动结束等待时长' : 'Silence Pause Timeout',
                    trailing: SettingsDropdown(
                      current: vadSilenceLabel,
                      semanticLabel: vadSilenceLabel,
                      entries: () => [
                        for (final ms in VoiceConfig.vadSilenceOptionsMs)
                          IdeMenuAction(
                            '${(ms / 1000).toStringAsFixed(1)}s',
                            checked: cfg.sttVadSilenceMs == ms,
                            onSelected: () => unawaited(
                              _update(cfg.copyWith(sttVadSilenceMs: ms)),
                            ),
                          ),
                      ],
                    ),
                  ),
                SettingsSwitchRow(
                  label: isZh ? '语音识别完成后自动发送' : 'Auto-send after dictation',
                  description: isZh
                      ? '停止录音并填入文字后直接发送消息，适合免手动语音交互'
                      : 'Automatically submit the message right after speech recognition completes',
                  value: cfg.sttAutoSend,
                  enabled: cfg.enabled,
                  onChanged: (v) =>
                      unawaited(_update(cfg.copyWith(sttAutoSend: v))),
                ),
                SettingsRow(
                  label: isZh ? '全局语音快捷键' : 'Global Voice Shortcut',
                  description: _hotkeyDescription(
                    cfg.sttHotkey,
                    VoiceHotkeyService.instance.hotkeyTaken,
                    isZh: isZh,
                  ),
                  trailing: SettingsButtons(
                    children: [
                      _VoiceHotkeyField(
                        hotkey: cfg.sttHotkey,
                        isZh: isZh,
                        onChanged: (spec) =>
                            unawaited(_update(cfg.copyWith(sttHotkey: spec))),
                      ),
                      if (cfg.sttHotkey.isNotEmpty)
                        IdeButton(
                          label: isZh ? '清除' : 'Clear',
                          secondary: true,
                          onPressed: () =>
                              unawaited(_update(cfg.copyWith(sttHotkey: ''))),
                        ),
                      if (cfg.sttHotkey != VoiceConfig.defaultSttHotkey)
                        IdeButton(
                          label: isZh
                              ? '默认 (${VoiceHotkeyService.formatLabel(VoiceConfig.defaultSttHotkey, mac: AppPlatform.isMacOS)})'
                              : 'Default (${VoiceHotkeyService.formatLabel(VoiceConfig.defaultSttHotkey, mac: AppPlatform.isMacOS)})',
                          secondary: true,
                          onPressed: () => unawaited(
                            _update(
                              cfg.copyWith(
                                sttHotkey: VoiceConfig.defaultSttHotkey,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (cfg.sttEngine == VoiceSttEngine.openaiCompatible) ...[
                  SettingsRow(
                    label: isZh ? 'API 地址（Base URL）' : 'API Base URL',
                    description: isZh
                        ? '将请求 /audio/transcriptions 接口'
                        : 'Calls /audio/transcriptions on this endpoint',
                    trailing: SettingsTextField(
                      value: cfg.sttApiBaseUrl,
                      semanticLabel: 'STT API Base URL',
                      hint: VoiceConfig.defaultApiBaseUrl,
                      width: 260,
                      onSubmitted: (v) => unawaited(
                        _update(
                          cfg.copyWith(
                            sttApiBaseUrl: v.isEmpty
                                ? VoiceConfig.defaultApiBaseUrl
                                : v,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SettingsRow(
                    label: isZh ? '识别模型' : 'STT Model',
                    trailing: SettingsTextField(
                      value: cfg.sttModel,
                      semanticLabel: 'STT Model',
                      hint: VoiceConfig.defaultSttModel,
                      width: 220,
                      onSubmitted: (v) => unawaited(
                        _update(
                          cfg.copyWith(
                            sttModel: v.isEmpty ? VoiceConfig.defaultSttModel : v,
                          ),
                        ),
                      ),
                    ),
                  ),
                  _ApiKeyRow(
                    label: isZh ? 'STT API Key' : 'STT API Key',
                    hasKey: _hasSttKey,
                    controller: _sttKeyController,
                    isZh: isZh,
                    onSave: () => unawaited(_saveSttKey(isZh)),
                  ),
                ],
                SettingsRow(
                  label: isZh ? '测试麦克风识别' : 'Test Microphone',
                    description: testingStt
                        ? (_stt.liveTranscript.isNotEmpty
                              ? _stt.liveTranscript
                              : (isZh
                                    ? '正在聆听，请说话，再次点击结束识别…'
                                    : 'Listening… click again to stop.'))
                        : (_stt.isStarting || _stt.isTranscribing)
                        ? (isZh ? '正在处理音频…' : 'Processing audio…')
                        : (_sttTestResult ??
                              (isZh
                                  ? '点击开始说话，再点一次查看识别结果'
                                  : 'Click to start speaking, click again to transcribe')),
                    trailing: IdeButton(
                      label: testingStt
                          ? (isZh ? '停止识别' : 'Stop')
                          : (isZh ? '开始测试' : 'Test Mic'),
                      icon: testingStt ? Codicons.debugStop : Codicons.mic,
                      secondary: !testingStt,
                      onPressed: (_stt.isStarting || _stt.isTranscribing)
                          ? null
                          : () => unawaited(_toggleSttTest(isZh)),
                    ),
                  ),
              ],
            ),
            SettingsGroup(
              title: isZh ? '语音播报（文字转语音 TTS）' : 'Voice Output (Text-to-Speech)',
              children: [
                SettingsRow(
                  label: isZh ? '播报引擎' : 'Speech Engine',
                  description: isZh
                      ? '推荐微软 Edge 神经网络音色（免费免 Key，接近真人语调，断网自动回退系统 SAPI）；也支持自定义 OpenAI TTS API'
                      : 'Edge Neural TTS offers free lifelike voices with automatic offline fallback to OS speech',
                  trailing: SettingsDropdown(
                    current: ttsEngineLabel,
                    semanticLabel: ttsEngineLabel,
                    entries: () => [
                      IdeMenuAction(
                        isZh
                            ? '微软 Edge 神经网络（推荐 · 免费真人音色）'
                            : 'Microsoft Edge Neural (Recommended · Free)',
                        checked: cfg.ttsEngine == VoiceTtsEngine.edgeNeural,
                        onSelected: () => unawaited(
                          _update(
                            cfg.copyWith(ttsEngine: VoiceTtsEngine.edgeNeural),
                          ),
                        ),
                      ),
                      IdeMenuAction(
                        isZh ? '系统离线语音（SAPI · 断网可用）' : 'System Offline Voice',
                        checked: cfg.ttsEngine == VoiceTtsEngine.system,
                        onSelected: () => unawaited(
                          _update(
                            cfg.copyWith(ttsEngine: VoiceTtsEngine.system),
                          ),
                        ),
                      ),
                      IdeMenuAction(
                        isZh ? 'OpenAI 兼容 TTS API' : 'OpenAI-compatible TTS API',
                        checked:
                            cfg.ttsEngine == VoiceTtsEngine.openaiCompatible,
                        onSelected: () => unawaited(
                          _update(
                            cfg.copyWith(
                              ttsEngine: VoiceTtsEngine.openaiCompatible,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SettingsSwitchRow(
                  label: isZh ? '自动朗读 AI 回复' : 'Auto-read AI Replies',
                  description: isZh
                      ? '当 AI 完成一轮回复后自动用语音朗读回答内容（代码块与链接会自动跳过）'
                      : 'Automatically read finished AI replies aloud (code blocks and URLs are skipped)',
                  value: cfg.ttsAutoRead,
                  enabled: cfg.enabled,
                  onChanged: (v) =>
                      unawaited(_update(cfg.copyWith(ttsAutoRead: v))),
                ),
                SettingsSwitchRow(
                  label: isZh ? '任务完成语音提醒' : 'Spoken Completion Announcement',
                  description: isZh
                      ? '后台任务完成或需要你确认时，用语音简短播报提醒（Windows / macOS / Linux 均支持）'
                      : 'Speak a short announcement when a task finishes or needs your confirmation',
                  value: cfg.completionAnnouncement,
                  enabled: cfg.enabled,
                  onChanged: (v) => unawaited(
                    _update(cfg.copyWith(completionAnnouncement: v)),
                  ),
                ),
                if (cfg.ttsEngine == VoiceTtsEngine.edgeNeural)
                  SettingsRow(
                    label: isZh ? 'Edge 神经网络音色' : 'Edge Neural Voice',
                    description: isZh
                        ? '中文回复使用所选中文音色；纯英文回复自动切换为自然英语女声 Aria'
                        : 'Uses selected voice; automatically switches Chinese voices to Aria for pure English replies',
                    trailing: SettingsDropdown(
                      current: edgeVoiceLabel,
                      semanticLabel: edgeVoiceLabel,
                      entries: () => [
                        for (final v in VoiceConfig.edgeVoices)
                          IdeMenuAction(
                            isZh ? v.zh : v.en,
                            checked: cfg.ttsEdgeVoice == v.id,
                            onSelected: () => unawaited(
                              _update(cfg.copyWith(ttsEdgeVoice: v.id)),
                            ),
                          ),
                      ],
                    ),
                  )
                else if (cfg.ttsEngine == VoiceTtsEngine.system)
                  SettingsRow(
                    label: isZh ? '系统音色' : 'System Voice',
                    description: isZh
                        ? '留空将根据内容中英文自动选择最佳已安装音色'
                        : 'Auto picks the best installed voice based on reply language',
                    trailing: SettingsDropdown(
                      current: voiceLabel,
                      semanticLabel: voiceLabel,
                      entries: () => [
                        IdeMenuAction(
                          isZh ? '自动（按语言匹配系统音色）' : 'Auto (match language)',
                          checked: cfg.ttsVoice.isEmpty,
                          onSelected: () =>
                              unawaited(_update(cfg.copyWith(ttsVoice: ''))),
                        ),
                        for (final v in _systemVoices)
                          IdeMenuAction(
                            v.displayLabel,
                            checked: cfg.ttsVoice == v.name,
                            onSelected: () => unawaited(
                              _update(cfg.copyWith(ttsVoice: v.name)),
                            ),
                          ),
                      ],
                    ),
                  )
                else ...[
                  SettingsRow(
                    label: isZh ? 'TTS API 地址' : 'TTS API Base URL',
                    description: isZh
                        ? '将请求 /audio/speech 接口'
                        : 'Calls /audio/speech on this endpoint',
                    trailing: SettingsTextField(
                      value: cfg.ttsApiBaseUrl,
                      semanticLabel: 'TTS API Base URL',
                      hint: VoiceConfig.defaultApiBaseUrl,
                      width: 260,
                      onSubmitted: (v) => unawaited(
                        _update(
                          cfg.copyWith(
                            ttsApiBaseUrl: v.isEmpty
                                ? VoiceConfig.defaultApiBaseUrl
                                : v,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SettingsRow(
                    label: isZh ? 'TTS 模型' : 'TTS Model',
                    trailing: SettingsTextField(
                      value: cfg.ttsModel,
                      semanticLabel: 'TTS Model',
                      hint: VoiceConfig.defaultTtsModel,
                      width: 220,
                      onSubmitted: (v) => unawaited(
                        _update(
                          cfg.copyWith(
                            ttsModel: v.isEmpty ? VoiceConfig.defaultTtsModel : v,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SettingsRow(
                    label: isZh ? 'API 音色' : 'API Voice',
                    trailing: SettingsDropdown(
                      current: cfg.ttsApiVoice,
                      semanticLabel: cfg.ttsApiVoice,
                      entries: () => [
                        for (final voice in VoiceConfig.openaiVoices)
                          IdeMenuAction(
                            voice,
                            checked: cfg.ttsApiVoice == voice,
                            onSelected: () => unawaited(
                              _update(cfg.copyWith(ttsApiVoice: voice)),
                            ),
                          ),
                      ],
                    ),
                  ),
                  _ApiKeyRow(
                    label: isZh ? 'TTS API Key' : 'TTS API Key',
                    hasKey: _hasTtsKey,
                    controller: _ttsKeyController,
                    isZh: isZh,
                    onSave: () => unawaited(_saveTtsKey(isZh)),
                  ),
                ],
                SettingsRow(
                  label: isZh ? '播报语速' : 'Speech Rate',
                  trailing: SettingsSlider(
                    step: rateIndex,
                    count: VoiceConfig.rateSteps.length,
                    label: rateLabel,
                    semanticLabel: isZh ? '播报语速 $rateLabel' : 'Rate $rateLabel',
                    onChanged: (i) => unawaited(
                      _update(cfg.copyWith(ttsRate: VoiceConfig.rateSteps[i])),
                    ),
                  ),
                ),
                SettingsRow(
                  label: isZh ? '试听语音效果' : 'Preview Voice',
                  description: _tts.lastError ??
                      (isZh
                          ? '使用当前引擎、音色与语速朗读一段示例文本'
                          : 'Speak a short sample using the active voice settings'),
                  trailing: IdeButton(
                    label: previewingTts
                        ? (isZh ? '停止试听' : 'Stop')
                        : (isZh ? '试听' : 'Preview'),
                    icon: previewingTts ? Codicons.debugStop : Codicons.unmute,
                    secondary: !previewingTts,
                    onPressed: () => unawaited(_toggleTtsPreview(isZh)),
                  ),
                ),
              ],
            ),
            if (_keyStatus != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  _keyStatus!,
                  style: SettingsText.description.copyWith(
                    color: AppColors.accent,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ApiKeyRow extends StatelessWidget {
  const _ApiKeyRow({
    required this.label,
    required this.hasKey,
    required this.controller,
    required this.isZh,
    required this.onSave,
  });

  final String label;
  final bool hasKey;
  final TextEditingController controller;
  final bool isZh;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(5),
      borderSide: BorderSide(color: AppColors.borderStrong),
    );
    final mono = TextStyle(
      fontFamily: AppFonts.mono,
      fontFamilyFallback: AppFonts.monoFallbacks,
      fontSize: 12,
    );
    return SettingsRow(
      label: label,
      description: hasKey
          ? (isZh
                ? '已保存至系统安全凭据库（留空点保存可清除）'
                : 'Stored securely in system keychain (save empty to clear)')
          : (isZh
                ? '将加密存储在系统凭据库，不会明文写入 settings.json'
                : 'Encrypted in OS keychain; never written to settings.json'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 190,
            child: TextField(
              controller: controller,
              obscureText: true,
              onSubmitted: (_) => onSave(),
              style: mono.copyWith(color: AppColors.text),
              decoration: InputDecoration(
                isDense: true,
                hintText: hasKey ? '••••••••••••' : 'sk-...',
                hintStyle: mono.copyWith(color: AppColors.textFaint),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                border: border,
                enabledBorder: border,
                focusedBorder: border.copyWith(
                  borderSide: BorderSide(color: AppColors.accent),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IdeButton(
            label: isZh ? '保存' : 'Save',
            secondary: true,
            onPressed: onSave,
          ),
        ],
      ),
    );
  }
}

/// Click-to-record global hotkey field for voice input; pauses the OS hotkey
/// while recording so pressing the current combo reaches this widget.
class _VoiceHotkeyField extends StatefulWidget {
  const _VoiceHotkeyField({
    required this.hotkey,
    required this.isZh,
    required this.onChanged,
  });

  final String hotkey;
  final bool isZh;
  final ValueChanged<String> onChanged;

  @override
  State<_VoiceHotkeyField> createState() => _VoiceHotkeyFieldState();
}

class _VoiceHotkeyFieldState extends State<_VoiceHotkeyField> {
  final _focus = FocusNode(debugLabel: 'Voice shortcut');
  bool _recording = false;
  bool _refused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    if (_recording) unawaited(VoiceHotkeyService.instance.resume());
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _stop();
  }

  void _start() {
    if (_recording) return;
    setState(() {
      _recording = true;
      _refused = false;
    });
    unawaited(VoiceHotkeyService.instance.pause());
    _focus.requestFocus();
  }

  void _stop() {
    if (!_recording) return;
    setState(() => _recording = false);
    unawaited(VoiceHotkeyService.instance.resume());
    if (_focus.hasFocus) _focus.unfocus();
  }

  void _take(String spec) {
    _stop();
    if (spec != widget.hotkey) widget.onChanged(spec);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_recording) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final chord = KeyChord.fromEvent(event);
    if (chord == null) return KeyEventResult.handled;
    if (!chord.hasModifier) {
      if (chord.key == LogicalKeyboardKey.escape) {
        _stop();
        return KeyEventResult.handled;
      }
      if (chord.key == LogicalKeyboardKey.backspace ||
          chord.key == LogicalKeyboardKey.delete) {
        _take('');
        return KeyEventResult.handled;
      }
    }
    final spec = StashHotkeyField.specOf(chord, KeybindingPlatform.current);
    if (spec == null) {
      setState(() => _refused = true);
    } else {
      _take(spec);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final label = VoiceHotkeyService.formatLabel(
      widget.hotkey,
      mac: AppPlatform.isMacOS,
    );
    final Widget shown;
    if (_recording) {
      shown = Text(
        _refused
            ? (widget.isZh ? '需包含修饰键（Ctrl/Alt/Shift）' : 'Add a modifier key')
            : (widget.isZh ? '请按下组合键…' : 'Press shortcut…'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: _refused ? AppColors.caution : AppColors.textMuted,
          fontSize: 12,
        ),
      );
    } else if (label.isEmpty) {
      shown = Text(
        widget.isZh ? '未设置' : 'None',
        style: TextStyle(color: AppColors.textFaint, fontSize: 12),
      );
    } else {
      shown = IdeKeycap(label);
    }
    return Semantics(
      button: true,
      label: widget.isZh ? '全局语音快捷键' : 'Global Voice Shortcut',
      value: label,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _recording ? _stop : _start,
            child: Container(
              width: 170,
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: _recording ? AppColors.accent : AppColors.borderStrong,
                ),
              ),
              child: shown,
            ),
          ),
        ),
      ),
    );
  }
}
