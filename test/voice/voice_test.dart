import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:baocode/models/secret_store.dart';
import 'package:baocode/voice/local_sensevoice.dart';
import 'package:baocode/voice/voice_ai_corrector.dart';
import 'package:baocode/voice/voice_hotkey.dart';
import 'package:baocode/voice/voice_model_installer.dart';
import 'package:baocode/voice/voice_settings.dart';
import 'package:baocode/voice/voice_stt_service.dart';
import 'package:baocode/voice/voice_text_cleaner.dart';
import 'package:baocode/voice/voice_tts_service.dart';

void main() {
  group('VoiceTextCleaner', () {
    test('strips fenced code, links, markdown tokens and voice cues', () {
      const input = '''
# 总结
[softly] 请查看 [文档](https://example.com/docs) 和 `main.dart`：
```dart
void main() => print('hi');
```
详见 https://example.com/raw
''';
      final cleaned = VoiceTextCleaner.cleanForSpeech(input, isZh: true);
      expect(cleaned, contains('总结'));
      expect(cleaned, contains('文档'));
      expect(cleaned, contains('main.dart'));
      expect(cleaned, contains('代码片段已略过'));
      expect(cleaned, isNot(contains('print')));
      expect(cleaned, isNot(contains('https://')));
      expect(cleaned, isNot(contains('[softly]')));
    });

    test('truncates long summary cleanly', () {
      final longText = '这是一段很长的测试回复内容' * 10;
      final summary = VoiceTextCleaner.cleanForSummary(longText, maxChars: 30);
      expect(summary.length, lessThanOrEqualTo(30));
    });

    test('detects CJK text', () {
      expect(VoiceTextCleaner.containsCjk('你好 world'), isTrue);
      expect(VoiceTextCleaner.containsCjk('Hello world 123'), isFalse);
    });
  });

  group('VoiceConfig & VoiceSettingsStore', () {
    test('parses defaults and custom values cleanly', () {
      final def = VoiceConfig.fromSettings((_) => null);
      expect(def.enabled, isTrue);
      expect(def.sttEngine, VoiceSttEngine.platformDefault);
      expect(def.ttsEngine, VoiceTtsEngine.platformDefault);
      expect(def.ttsRate, 1.0);

      final custom = VoiceConfig.fromSettings(
        (key) => {
          VoiceConfig.enabledKey: false,
          VoiceConfig.sttEngineKey: 'openaiCompatible',
          VoiceConfig.sttLanguageKey: 'en-US',
          VoiceConfig.sttAutoSendKey: true,
          VoiceConfig.ttsEngineKey: 'openaiCompatible',
          VoiceConfig.ttsRateKey: 1.5,
          VoiceConfig.ttsAutoReadKey: true,
          VoiceConfig.completionAnnouncementKey: true,
        }[key],
      );
      expect(custom.enabled, isFalse);
      expect(custom.sttEngine, VoiceSttEngine.openaiCompatible);
      expect(custom.sttLanguage, 'en-US');
      expect(custom.sttAutoSend, isTrue);
      expect(custom.ttsEngine, VoiceTtsEngine.openaiCompatible);
      expect(custom.ttsRate, 1.5);
      expect(custom.ttsAutoRead, isTrue);
      expect(custom.completionAnnouncement, isTrue);
    });

    test('omits defaults in toSettingsMap', () {
      final map = VoiceConfig(
        sttEngine: VoiceSttEngine.platformDefault,
        ttsEngine: VoiceTtsEngine.platformDefault,
      ).toSettingsMap();
      expect(map.values.every((v) => v == null), isTrue);
    });

    test('stores and clears API keys via SecretStore', () async {
      final secrets = MemorySecretStore();
      final store = VoiceSettingsStore(secrets: secrets);

      expect(await store.readSttApiKey(), isNull);
      await store.writeSttApiKey('  sk-test-stt  ');
      expect(await store.readSttApiKey(), 'sk-test-stt');

      await store.writeTtsApiKey('sk-test-tts');
      expect(await store.readTtsApiKey(), 'sk-test-tts');

      await store.writeSttApiKey('');
      expect(await store.readSttApiKey(), isNull);
    });
  });

  group('Voice API helpers', () {
    test('normalizes OpenAI transcription and speech URIs', () {
      expect(
        VoiceSttService.buildTranscriptionsUri('https://api.openai.com/v1/')
            .toString(),
        'https://api.openai.com/v1/audio/transcriptions',
      );
      expect(
        VoiceSttService.buildTranscriptionsUri(
          'https://local.host/v1/audio/transcriptions',
        ).toString(),
        'https://local.host/v1/audio/transcriptions',
      );
      expect(
        VoiceTtsService.buildSpeechUri('https://api.openai.com/v1').toString(),
        'https://api.openai.com/v1/audio/speech',
      );
    });

    test('extracts ISO-639 language codes and parses transcription JSON', () {
      expect(VoiceSttService.toIso639Language('zh-CN'), 'zh');
      expect(VoiceSttService.toIso639Language('en-US'), 'en');
      expect(VoiceSttService.toIso639Language('auto'), isNull);
      expect(
        VoiceSttService.parseTranscriptionResponse('{"text": " 你好世界 "}'),
        '你好世界',
      );
      expect(
        VoiceSttService.parseTranscriptionResponse('plain text'),
        'plain text',
      );
    });

    test('deduplicates repeated and cumulative SAPI transcript segments', () {
      final segments = <String>[];
      VoiceSttService.appendSegment(segments, '我不好');
      VoiceSttService.appendSegment(segments, '我不好');
      VoiceSttService.appendSegment(segments, '我不好');
      expect(segments, ['我不好']);

      VoiceSttService.appendSegment(segments, '我不好意思');
      expect(segments, ['我不好意思']);

      // Trailing partial duplicate is not appended twice.
      expect(VoiceSttService.mergeTranscript(segments, '不好意思'), '我不好意思');
      expect(VoiceSttService.mergeTranscript(segments, '我不好意思迟到了'), '我不好意思迟到了');
      expect(VoiceSttService.mergeTranscript(segments, '明天见'), '我不好意思明天见');
    });

    test('strips SenseVoice metadata tags cleanly', () {
      expect(
        LocalSenseVoice.stripSenseVoiceTags(
          '<|zh|><|NEUTRAL|><|Speech|><|withitn|>你好，帮我检查一下代码。',
        ),
        '你好，帮我检查一下代码。',
      );
    });
  });

  group('VoiceHotkeyService & hotkey settings', () {
    test('parses default, custom, and explicitly cleared sttHotkey', () {
      expect(
        VoiceConfig.fromSettings((_) => null).sttHotkey,
        VoiceConfig.defaultSttHotkey,
      );
      expect(
        VoiceConfig.fromSettings(
          (k) => k == VoiceConfig.sttHotkeyKey ? 'ctrl+alt+m' : null,
        ).sttHotkey,
        'ctrl+alt+m',
      );
      expect(
        VoiceConfig.fromSettings(
          (k) => k == VoiceConfig.sttHotkeyKey ? '' : null,
        ).sttHotkey,
        '',
      );
      expect(
        const VoiceConfig(sttHotkey: '').toSettingsMap()[VoiceConfig.sttHotkeyKey],
        '',
      );
    });

    test('formats hotkey labels for Windows and macOS', () {
      expect(
        VoiceHotkeyService.formatLabel('alt+shift+v', mac: false),
        'Alt+Shift+V',
      );
      expect(
        VoiceHotkeyService.formatLabel('alt+shift+v', mac: true),
        '⌥⇧V',
      );
      expect(
        VoiceHotkeyService.formatLabel('ctrl+shift+space', mac: false),
        'Ctrl+Shift+Space',
      );
      expect(VoiceHotkeyService.formatLabel('', mac: false), '');
    });

    test('dispatches global hotkey to focused composer or most recent active', () {
      final store = VoiceSettingsStore(secrets: MemorySecretStore());
      final service = VoiceHotkeyService(store: store);
      final ownerA = Object();
      final ownerB = Object();
      var hitsA = 0;
      var hitsB = 0;
      var focusA = false;
      var focusB = false;

      service.registerComposer(
        ownerA,
        onTrigger: ({autoOpened = false}) => hitsA++,
        isFocused: () => focusA,
      );
      service.registerComposer(
        ownerB,
        onTrigger: ({autoOpened = false}) => hitsB++,
        isFocused: () => focusB,
      );

      // Most recently registered (B) wins when neither is focused.
      service.handleHotkeyPressed();
      expect(hitsA, 0);
      expect(hitsB, 1);

      // Focused composer (A) takes priority.
      focusA = true;
      service.handleHotkeyPressed();
      expect(hitsA, 1);
      expect(hitsB, 1);

      // Marking A active makes A win even after losing focus.
      focusA = false;
      service.markActive(ownerA);
      service.handleHotkeyPressed();
      expect(hitsA, 2);

      // Disabled voice ignores hotkey.
      store.resetForTest(const VoiceConfig(enabled: false));
      service.handleHotkeyPressed();
      expect(hitsA, 2);
      expect(hitsB, 1);
    });
  });

  group('VoiceAiCorrector & streaming settings', () {
    test('defaults sttStreaming and sttAiCorrect to true and parses false', () {
      final def = VoiceConfig.fromSettings((_) => null);
      expect(def.sttStreaming, isTrue);
      expect(def.sttAiCorrect, isTrue);

      final off = VoiceConfig.fromSettings(
        (k) => {
          VoiceConfig.sttStreamingKey: false,
          VoiceConfig.sttAiCorrectKey: false,
        }[k],
      );
      expect(off.sttStreaming, isFalse);
      expect(off.sttAiCorrect, isFalse);
    });

    test('sanitizes AI output and rejects hallucinated long answers', () {
      expect(
        VoiceAiCorrector.sanitizeOutput(
          '<asr>我希望边语音边输出，AI 还能帮我纠正。</asr>',
          original: '我希望边语音编书处 ai还能帮我纠正',
        ),
        '我希望边语音边输出，AI 还能帮我纠正。',
      );
      expect(
        VoiceAiCorrector.sanitizeOutput(
          '“帮我检查一下代码”',
          original: '帮我检查一下代马',
        ),
        '帮我检查一下代码',
      );
      // Hallucinated long answer falls back to original raw transcript.
      final longAnswer = '好的，我可以帮你做这件事，具体步骤如下：' * 10;
      expect(
        VoiceAiCorrector.sanitizeOutput(longAnswer, original: '帮我改一下'),
        '帮我改一下',
      );
    });

    test('corrects transcript via configured asker and falls back on error', () async {
      addTearDown(() => VoiceAiCorrector.askerForTest = null);
      VoiceAiCorrector.askerForTest =
          (system, prompt, {model, exact = false, location, cancel}) async {
            expect(prompt, contains('<asr>'));
            expect(prompt, contains('编书处'));
            expect(prompt, contains('<context>'));
            expect(prompt, contains('<glossary>'));
            expect(prompt, contains('SenseVoice'));
            return '我希望边语音边输出，AI 还能帮我纠正。';
          };

      final fixed = await VoiceAiCorrector.correct(
        '我希望边语音编书处 ai还能帮我纠正',
        lastReply: '刚才聊到了语音实时输出功能',
        glossary: 'Ayte, SenseVoice, Flutter',
      );
      expect(fixed, '我希望边语音边输出，AI 还能帮我纠正。');

      VoiceAiCorrector.askerForTest =
          (system, prompt, {model, exact = false, location, cancel}) async {
            throw Exception('offline');
          };
      final fallback = await VoiceAiCorrector.correct('原始语音文本');
      expect(fallback, '原始语音文本');

      // Cancelling an in-flight correction immediately returns the raw text.
      final cancel = Completer<void>();
      VoiceAiCorrector.askerForTest =
          (system, prompt, {model, exact = false, location, cancel}) =>
              Completer<String>().future;
      final future = VoiceAiCorrector.correct('等不及了', cancel: cancel.future);
      cancel.complete();
      expect(await future, '等不及了');
    });

    test('conversation mode, Edge TTS helpers, and VAD settings work cleanly', () {
      const conv = VoiceConfig(conversationMode: true);
      expect(conv.effectiveVadAutoStop, isTrue);
      expect(conv.effectiveAutoSend, isTrue);
      expect(conv.effectiveAutoRead, isTrue);

      expect(VoiceTtsService.formatEdgeRate(1.0), '+0%');
      expect(VoiceTtsService.formatEdgeRate(1.25), '+25%');
      expect(VoiceTtsService.formatEdgeRate(0.85), '-15%');
      expect(
        VoiceTtsService.pickEdgeVoice('zh-CN-XiaoxiaoNeural', '你好世界'),
        'zh-CN-XiaoxiaoNeural',
      );
      expect(
        VoiceTtsService.pickEdgeVoice('zh-CN-XiaoxiaoNeural', 'Hello world'),
        'en-US-AriaNeural',
      );
      expect(VoiceSttService.isStopConversationCommand('结束对话。'), isTrue);
      expect(VoiceSttService.isStopConversationCommand('结束吧！'), isTrue);
      expect(VoiceSttService.isStopConversationCommand('Stop conversation.'), isTrue);
      expect(
        VoiceSttService.isStopConversationCommand('帮我把结束对话功能优化一下'),
        isFalse,
      );
    });
  });

  group('Voice v2 optimizations (streaming TTS, commands, language, guards)', () {
    test('splits long speech cleanly with concise first chunk and intact filenames', () {
      const sample =
          '已经帮你修好了 main.dart 里的 3.14 浮点数问题！接下来我们优化一下语音播报的响应速度。'
          '第三句会和短句合并在一起播报，确保语调自然连贯。';
      final chunks = VoiceTtsService.splitIntoSpeechSentences(sample);
      expect(chunks.length, greaterThanOrEqualTo(2));
      expect(chunks.first, contains('main.dart'));
      expect(chunks.first, contains('3.14'));
      expect(chunks.first.length, lessThanOrEqualTo(75));

      const longFirst =
          '这是一段非常长没有句号的开头介绍，用来测试第一句超过八十五个字符时会自动按逗号切分出较短的首包，从而把首次出声时间压到半秒以内，让交互体验更加自然流畅。';
      final splitLong = VoiceTtsService.splitIntoSpeechSentences(longFirst);
      expect(splitLong.length, greaterThanOrEqualTo(2));
      expect(splitLong.first.length, lessThanOrEqualTo(76));
    });

    test('maps BCP-47 tags to SenseVoice language codes accurately', () {
      expect(LocalSenseVoice.mapSenseVoiceLanguage('zh-CN'), 'zh');
      expect(LocalSenseVoice.mapSenseVoiceLanguage('en-US'), 'en');
      expect(LocalSenseVoice.mapSenseVoiceLanguage('ja-JP'), 'ja');
      expect(LocalSenseVoice.mapSenseVoiceLanguage('zh-HK'), 'yue');
      expect(LocalSenseVoice.mapSenseVoiceLanguage('auto'), 'auto');
      expect(LocalSenseVoice.mapSenseVoiceLanguage(null), 'auto');
    });

    test('matches exact voice commands without false positives on prompts', () {
      expect(
        VoiceSttService.matchVoiceCommand('结束对话。'),
        VoiceCommand.stopConversation,
      );
      expect(
        VoiceSttService.matchVoiceCommand('清空输入框！'),
        VoiceCommand.clearInput,
      );
      expect(
        VoiceSttService.matchVoiceCommand('停止生成'),
        VoiceCommand.stopGeneration,
      );
      expect(
        VoiceSttService.matchVoiceCommand('撤销输入'),
        VoiceCommand.undoInput,
      );
      expect(
        VoiceSttService.matchVoiceCommand('请帮我添加一个清空输入框按钮'),
        isNull,
      );
    });

    test('merges user glossary and dynamic workspace terms deduplicated', () {
      expect(
        VoiceSttService.mergeGlossaries(
          'Ayte, Flutter, SenseVoice',
          'ayte, composer.dart, voice_tts_service.dart',
        ),
        'Ayte, Flutter, SenseVoice, composer.dart, voice_tts_service.dart',
      );
    });

    test('persists sttInputDeviceId and earcons cleanly and omits defaults', () {
      final def = VoiceConfig.fromSettings((_) => null);
      expect(def.sttInputDeviceId, -1);
      expect(def.earcons, isTrue);

      final custom = VoiceConfig.fromSettings(
        (k) => {
          VoiceConfig.sttInputDeviceIdKey: 2,
          VoiceConfig.earconsKey: false,
        }[k],
      );
      expect(custom.sttInputDeviceId, 2);
      expect(custom.earcons, isFalse);

      final customMap = custom.toSettingsMap();
      expect(customMap[VoiceConfig.sttInputDeviceIdKey], 2);
      expect(customMap[VoiceConfig.earconsKey], false);
    });

    test('conversation follow-up guards against unfocused window and unsent drafts', () {
      final store = VoiceSettingsStore(secrets: MemorySecretStore());
      store.resetForTest(const VoiceConfig(enabled: true, conversationMode: true));
      var windowFocused = true;
      var hasDraft = false;
      var autoTriggered = 0;

      final service = VoiceHotkeyService(
        store: store,
        isWindowFocused: () => windowFocused,
      );
      final owner = Object();
      service.registerComposer(
        owner,
        onTrigger: ({autoOpened = false}) {
          if (autoOpened) autoTriggered++;
        },
        isFocused: () => true,
        hasDraft: () => hasDraft,
      );

      // Unfocused window: never silently open mic.
      windowFocused = false;
      service.handleConversationFollowUp();
      expect(autoTriggered, 0);

      // Focused window but unsent draft present: never clobber user draft.
      windowFocused = true;
      hasDraft = true;
      service.handleConversationFollowUp();
      expect(autoTriggered, 0);

      // Focused window and clean composer: auto-opens mic with autoOpened=true.
      hasDraft = false;
      service.handleConversationFollowUp();
      expect(autoTriggered, 1);
    });

    test('formats installer byte sizes cleanly', () {
      expect(VoiceModelInstaller.formatMb(1024 * 1024), '1.0 MB');
      expect(VoiceModelInstaller.formatMb(239233841), '228.2 MB');
    });
  });

  group('OpenAI-compatible TTS voice discovery & keyless mode', () {
    test('builds speech fallback URIs when /v1 is omitted', () {
      expect(
        VoiceTtsService.buildSpeechUris('https://api.openai.com/v1')
            .map((u) => u.toString())
            .toList(),
        ['https://api.openai.com/v1/audio/speech'],
      );
      expect(
        VoiceTtsService.buildSpeechUris('http://192.168.100.129:17865/')
            .map((u) => u.toString())
            .toList(),
        [
          'http://192.168.100.129:17865/audio/speech',
          'http://192.168.100.129:17865/v1/audio/speech',
        ],
      );
      expect(
        VoiceTtsService.buildSpeechUris(
          'http://localhost:8880/v1/audio/speech',
        ).map((u) => u.toString()).toList(),
        ['http://localhost:8880/v1/audio/speech'],
      );
    });

    test('builds deduplicated candidate voice-listing URIs', () {
      expect(
        VoiceTtsService.buildVoiceListUris('http://192.168.100.129:17865/')
            .map((u) => u.toString())
            .toList(),
        [
          'http://192.168.100.129:17865/v1/audio/voices',
          'http://192.168.100.129:17865/audio/voices',
          'http://192.168.100.129:17865/v1/voices',
          'http://192.168.100.129:17865/voices',
          'http://192.168.100.129:17865/api/voices',
          'http://192.168.100.129:17865/speakers',
        ],
      );
      expect(
        VoiceTtsService.buildVoiceListUris(
          'http://localhost:8880/v1/audio/speech',
        ).map((u) => u.toString()).toList(),
        [
          'http://localhost:8880/v1/audio/voices',
          'http://localhost:8880/v1/voices',
          'http://localhost:8880/voices',
          'http://localhost:8880/api/voices',
          'http://localhost:8880/speakers',
        ],
      );
      expect(VoiceTtsService.buildVoiceListUris('not-a-url'), isEmpty);
    });

    test('parses diverse OpenAI-compatible voice list payloads', () {
      final simple = VoiceTtsService.parseOpenAiVoicesResponse(
        '{"voices": ["af_heart", "zf_xiaobei", "af_heart"]}',
      );
      expect(simple.map((v) => v.id).toList(), ['af_heart', 'zf_xiaobei']);
      expect(simple.first.displayLabel, 'af_heart');

      final detailed = VoiceTtsService.parseOpenAiVoicesResponse(
        jsonEncode({
          'voices': [
            {'voice_id': 'zh_female_1', 'name': '温柔女声', 'locale': 'zh-CN'},
          ],
        }),
      );
      expect(detailed, hasLength(1));
      expect(detailed.first.id, 'zh_female_1');
      expect(detailed.first.displayLabel, '温柔女声 (zh_female_1) · zh-CN');

      final nested = VoiceTtsService.parseOpenAiVoicesResponse(
        jsonEncode({
          'code': 0,
          'data': {
            'items': [
              {
                'id': 'narrator_01',
                'display_name': '旁白',
                'languages': ['zh', 'en'],
              },
            ],
          },
        }),
      );
      expect(nested, hasLength(1));
      expect(nested.first.id, 'narrator_01');
      expect(nested.first.displayLabel, '旁白 (narrator_01) · zh/en');

      final mapped = VoiceTtsService.parseOpenAiVoicesResponse(
        jsonEncode({
          'voices': {
            'zf_xiaobei': {'name': '小贝', 'lang': 'zh-CN'},
          },
        }),
      );
      expect(mapped, hasLength(1));
      expect(mapped.first.id, 'zf_xiaobei');
      expect(mapped.first.displayLabel, '小贝 (zf_xiaobei) · zh-CN');

      final topList = VoiceTtsService.parseOpenAiVoicesResponse(
        jsonEncode([
          {'short_name': 'zh-CN-XiaoxiaoNeural', 'friendly_name': '晓晓'},
        ]),
      );
      expect(topList, hasLength(1));
      expect(topList.first.id, 'zh-CN-XiaoxiaoNeural');
      expect(topList.first.displayLabel, '晓晓 (zh-CN-XiaoxiaoNeural)');

      expect(
        VoiceTtsService.parseOpenAiVoicesResponse(
          '{"error": {"message": "not found"}}',
        ),
        isEmpty,
      );
      expect(
        VoiceTtsService.parseOpenAiVoicesResponse('<html><body>ok</body></html>'),
        isEmpty,
      );
    });

    test('detects audio container extensions cleanly', () {
      expect(
        VoiceTtsService.detectAudioExtension([
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45,
        ]),
        'wav',
      );
      expect(
        VoiceTtsService.detectAudioExtension([0x4F, 0x67, 0x67, 0x53, 0]),
        'ogg',
      );
      expect(
        VoiceTtsService.detectAudioExtension([0x66, 0x4C, 0x61, 0x43, 0]),
        'flac',
      );
      expect(VoiceTtsService.detectAudioExtension([0x49, 0x44, 0x33]), 'mp3');
    });

    test('persists custom ttsApiVoice values cleanly', () {
      final cfg = VoiceConfig.fromSettings(
        (key) => {
          VoiceConfig.ttsEngineKey: 'openaiCompatible',
          VoiceConfig.ttsApiVoiceKey: 'zf_xiaobei_custom',
        }[key],
      );
      expect(cfg.ttsApiVoice, 'zf_xiaobei_custom');
      expect(
        cfg.toSettingsMap()[VoiceConfig.ttsApiVoiceKey],
        'zf_xiaobei_custom',
      );
    });

    test('lists voices and synthesizes keyless with /v1 fallback', () async {
      final seenVoicePaths = <String>[];
      final seenAuthHeaders = <String?>[];
      final seenSpeechPaths = <String>[];
      Map<String, dynamic>? speechBody;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((req) async {
        if (req.method == 'GET') {
          seenVoicePaths.add(req.uri.path);
          seenAuthHeaders.add(req.headers.value(HttpHeaders.authorizationHeader));
          if (req.uri.path == '/voices') {
            req.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode({
                  'voices': [
                    {'id': 'local_zh_1', 'name': '小青'},
                    {'id': 'local_en_1', 'name': 'Alex'},
                  ],
                }),
              );
          } else {
            req.response.statusCode = HttpStatus.notFound;
          }
          await req.response.close();
          return;
        }
        if (req.method == 'POST') {
          seenSpeechPaths.add(req.uri.path);
          seenAuthHeaders.add(req.headers.value(HttpHeaders.authorizationHeader));
          final rawBody = await utf8.decoder.bind(req).join();
          if (req.uri.path == '/v1/audio/speech') {
            speechBody = jsonDecode(rawBody) as Map<String, dynamic>;
            req.response
              ..statusCode = HttpStatus.ok
              ..add([0x49, 0x44, 0x33, 0x03]);
          } else {
            req.response.statusCode = HttpStatus.notFound;
          }
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.methodNotAllowed;
        await req.response.close();
      });

      final baseUrl = 'http://${server.address.address}:${server.port}';
      final http = HttpOverrides.runWithHttpOverrides(
        HttpClient.new,
        _DirectHttpOverrides(),
      );
      addTearDown(() => http.close(force: true));

      // Keyless voice listing falls through 404s until /voices succeeds.
      final listed = await VoiceTtsService.listOpenAiVoices(
        baseUrl: baseUrl,
        client: http,
      );
      expect(listed.error, isNull);
      expect(listed.voices.map((v) => v.id).toList(), [
        'local_zh_1',
        'local_en_1',
      ]);
      expect(seenVoicePaths, [
        '/v1/audio/voices',
        '/audio/voices',
        '/v1/voices',
        '/voices',
      ]);
      expect(seenAuthHeaders.every((h) => h == null), isTrue);

      // Keyless synthesis retries /v1/audio/speech on 404 and sends custom voice.
      seenAuthHeaders.clear();
      final bytes = await VoiceTtsService.synthesizeViaOpenAi(
        text: '你好',
        baseUrl: baseUrl,
        model: 'tts-1',
        voice: 'local_zh_1',
        client: http,
      );
      expect(bytes, [0x49, 0x44, 0x33, 0x03]);
      expect(seenSpeechPaths, ['/audio/speech', '/v1/audio/speech']);
      expect(seenAuthHeaders.every((h) => h == null), isTrue);
      expect(speechBody?['voice'], 'local_zh_1');

      // When an API key is provided, Bearer header is attached.
      seenAuthHeaders.clear();
      final withKey = await VoiceTtsService.listOpenAiVoices(
        baseUrl: baseUrl,
        apiKey: 'sk-local',
        client: http,
      );
      expect(withKey.voices, hasLength(2));
      expect(seenAuthHeaders.every((h) => h == 'Bearer sk-local'), isTrue);
    });

    test('stops probing immediately on 401 unauthorized', () async {
      var hits = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((req) async {
        hits++;
        req.response.statusCode = HttpStatus.unauthorized;
        await req.response.close();
      });

      final baseUrl = 'http://${server.address.address}:${server.port}';
      final http = HttpOverrides.runWithHttpOverrides(
        HttpClient.new,
        _DirectHttpOverrides(),
      );
      addTearDown(() => http.close(force: true));
      final result = await VoiceTtsService.listOpenAiVoices(
        baseUrl: baseUrl,
        client: http,
      );
      expect(result.voices, isEmpty);
      expect(result.error, 'HTTP 401');
      expect(hits, 1);
    });
  });
}

class _DirectHttpOverrides extends HttpOverrides {}
