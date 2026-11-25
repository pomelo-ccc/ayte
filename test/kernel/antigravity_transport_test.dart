import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart' show AgentPaths;
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/panels/context_usage_panel.dart';
import 'package:baocode/chat/session_links.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_cli.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_translator.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/commit_attribution.dart';
import 'package:baocode/kernel/extension_switches.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../e2e/helpers/fake_cli_harness.dart';

void main() {
  group('AntigravityModels deduplication & context windows', () {
    test(
      'updateFromJson collapses raw agy 1.5.12 model variants into clean families with selectable 512K override',
      () {
        const rawJson = {
          'command': {
            'data': {
              'models': [
                {'id': 'gemini-4-neon-high', 'label': 'Gemini 4 Neon (High)'},
                {'id': 'gemini-4-neon-xhigh', 'label': 'Gemini 4 Neon (XHigh)'},
                {'id': 'gemini-4-neon-medium', 'label': 'Gemini 4 Neon (Medium)'},
                {'id': 'gemini-4-neon-low', 'label': 'Gemini 4 Neon (Low)'},
                {'id': 'gemini-4-carbon-medium', 'label': 'Gemini 4 Carbon (Medium)'},
                {'id': 'gemini-4-carbon-high', 'label': 'Gemini 4 Carbon (High)'},
                {'id': 'gemini-4-carbon-low', 'label': 'Gemini 4 Carbon (Low)'},
                {'id': 'gemini-4-argon-medium', 'label': 'Gemini 4 Argon (Medium)'},
                {'id': 'gemini-4-argon-high', 'label': 'Gemini 4 Argon (High)'},
                {'id': 'gemini-4-argon-low', 'label': 'Gemini 4 Argon (Low)'},
                {'id': 'gemini-4-hydrogen-high', 'label': 'Gemini 4 Hydrogen (High)'},
                {'id': 'gemini-4-hydrogen-xhigh', 'label': 'Gemini 4 Hydrogen (XHigh)'},
                {'id': 'gemini-4-hydrogen-medium', 'label': 'Gemini 4 Hydrogen (Medium)'},
                {'id': 'gemini-4-hydrogen-low', 'label': 'Gemini 4 Hydrogen (Low)'},
                {'id': 'gemini-pro-orchestrator-neon', 'label': 'Orchestrator (Neon)'},
                {'id': 'gemini-pro-orchestrator', 'label': 'Orchestrator (Carbon)'},
                {'id': 'gemini-pro-orchestrator-argon', 'label': 'Orchestrator (Argon)'},
                {'id': 'gemini-3.8-flash-high', 'label': 'Gemini 3.8 Flash (High)'},
                {'id': 'gemini-3.8-flash-medium', 'label': 'Gemini 3.8 Flash (Medium)'},
                {'id': 'gemini-3.8-flash-low', 'label': 'Gemini 3.8 Flash (Low)'},
                {'id': 'claude-opus-5-5-high', 'label': 'Claude Opus 5.5 (High)'},
                {'id': 'claude-opus-5-5-medium', 'label': 'Claude Opus 5.5 (Medium)'},
                {'id': 'claude-opus-5-5-low', 'label': 'Claude Opus 5.5 (Low)'},
                {'id': 'claude-sonnet-5-5-high', 'label': 'Claude Sonnet 5.5 (High)'},
                {'id': 'claude-sonnet-5-5-medium', 'label': 'Claude Sonnet 5.5 (Medium)'},
                {'id': 'claude-sonnet-5-5-low', 'label': 'Claude Sonnet 5.5 (Low)'},
                {'id': 'gpt-oss-120b-medium', 'label': 'GPT-OSS 120B (Medium)'},
              ],
            },
          },
        };

        AntigravityModels.updateFromJson(rawJson);
        final families = AntigravityModels.current;

        expect(families.map((m) => m.id).toList(), [
          'gemini-4-neon',
          'gemini-4-carbon',
          'gemini-4-argon',
          'gemini-4-hydrogen',
          'gemini-pro-orchestrator-neon',
          'gemini-pro-orchestrator',
          'gemini-pro-orchestrator-argon',
          'gemini-3.8-flash',
          'claude-opus-5-5',
          'claude-sonnet-5-5',
          'gpt-oss-120b',
        ]);

        final neon = AntigravityModels.of('gemini-4-neon')!;
        expect(neon.label, 'Gemini 4 Neon');
        expect(neon.effortLevels, ['low', 'medium', 'high', 'xhigh']);
        expect(neon.contextOptions, [256000, 512000]);
        expect(neon.defaultContext, 256000);
        expect(neon.supportsPresetContextWindow, isFalse);
        expect(neon.resolveContextWindow(512000), 512000);

        final argon = AntigravityModels.of('gemini-4-argon')!;
        expect(argon.effortLevels, ['low', 'medium', 'high']);
        expect(argon.contextOptions, [256000, 512000, 900000]);
        expect(argon.defaultContext, 256000);
        expect(argon.supportsPresetContextWindow, isTrue);
        expect(argon.resolveContextWindow(200000), 256000);
        expect(argon.resolveContextWindow(400000), 512000);

        final hydrogen = AntigravityModels.of('gemini-4-hydrogen')!;
        expect(hydrogen.effortLevels, ['low', 'medium', 'high', 'xhigh']);
        expect(hydrogen.contextOptions, [256000, 512000]);
        expect(hydrogen.defaultContext, 256000);
        expect(hydrogen.supportsPresetContextWindow, isFalse);
        expect(hydrogen.effectiveCliModel, 'gemini-4-hydrogen');
        expect(hydrogen.resolveContextWindow(512000), 512000);

        final orchestrator = AntigravityModels.of('gemini-pro-orchestrator')!;
        expect(orchestrator.effortLevels, isEmpty);
        expect(orchestrator.contextOptions, [256000, 512000]);

        final claudeOpus = AntigravityModels.of('claude-opus-5-5')!;
        expect(claudeOpus.effortLevels, ['low', 'medium', 'high']);
        expect(claudeOpus.contextOptions, [256000, 512000]);
        expect(claudeOpus.defaultContext, 256000);

        final gptOss = AntigravityModels.of('gpt-oss-120b')!;
        expect(gptOss.effortLevels, isEmpty);
        expect(gptOss.effectiveCliModel, 'gpt-oss-120b-medium');
        expect(gptOss.contextOptions, [128000]);
        expect(gptOss.defaultContext, 128000);
      },
    );

    test('parseVariant normalizes legacy variant IDs cleanly', () {
      final carbon = AntigravityModels.parseVariant(
        '@antigravity-cli/gemini-4-carbon-medium',
      );
      expect(carbon, isNotNull);
      expect(carbon!.model.id, 'gemini-4-carbon');
      expect(carbon.effort, 'medium');

      final gpt = AntigravityModels.parseVariant(
        '@antigravity-cli/gpt-oss-120b-medium',
      );
      expect(gpt, isNotNull);
      expect(gpt!.model.id, 'gpt-oss-120b');
      expect(gpt.effort, isNull);
    });

    test(
      'ClaudeCodeKernel exposes agy 1.5.10 context windows and emits UsageReported immediately on switch',
      () async {
        final previousCore = ClaudeCore.current;
        ClaudeCore.current = () => ClaudeCore.antigravity;
        addTearDown(() => ClaudeCore.current = previousCore);

        final providers = ModelProviders.memory();
        final descriptor = KernelDescriptor(
          id: antigravityBuiltinProviderId,
          label: 'Antigravity',
          icon: Icons.rocket_launch_rounded,
          description: 'Antigravity CLI',
          create: (_) => throw UnimplementedError(),
        );
        final kernel = ClaudeCodeKernel(
          descriptor,
          const KernelContext(
            cwd: '/tmp',
            settings: {
              'model': '@antigravity-cli/gemini-4-carbon-medium',
              // Legacy 400K setting on Argon migrates to agy 1.5.10's 512K automatically.
              'context@@antigravity-cli/gemini-4-argon': '400000',
            },
          ),
          providers: providers,
          start: (_) async => throw UnimplementedError(),
        );
        addTearDown(kernel.dispose);

        final reported = <UsageReported>[];
        final sub = kernel.events.listen((event) {
          if (event is UsageReported) reported.add(event);
        });
        addTearDown(sub.cancel);

        // Legacy variant ID normalized to canonical family ref + preserved effort,
        // and fixed-window Carbon reports Cortex's real 256K compaction limit.
        expect(kernel.model.selected, '@antigravity-cli/gemini-4-carbon');
        expect(kernel.effort.selected, 'medium');
        expect(kernel.contextSize.selected, '256000');
        expect(kernel.contextWindow, 256000);
        expect(
          kernel.contextSize.selectedFor('@antigravity-cli/gemini-4-argon'),
          '512000',
        );

        final neonContexts = kernel.contextSize
            .optionsFor('@antigravity-cli/gemini-4-neon')
            .map((o) => o.label)
            .toList();
        expect(neonContexts, ['256K', '512K（强制）']);

        final carbonContexts = kernel.contextSize
            .optionsFor('@antigravity-cli/gemini-4-carbon')
            .map((o) => o.label)
            .toList();
        expect(carbonContexts, ['256K', '512K（强制）']);

        // Forcing 512K on Gemini 4 Neon updates contextWindow immediately.
        kernel.model.select('@antigravity-cli/gemini-4-neon');
        kernel.contextSize.select('@antigravity-cli/gemini-4-neon', '512000');
        await Future<void>.delayed(Duration.zero);
        expect(kernel.contextSize.selected, '512000');
        expect(kernel.contextWindow, 512000);
        expect(reported.last.usage.window, 512000);

        final argonContexts = kernel.contextSize
            .optionsFor('@antigravity-cli/gemini-4-argon')
            .map((o) => o.label)
            .toList();
        expect(argonContexts, ['256K', '512K', '900K']);

        final gptContexts = kernel.contextSize
            .optionsFor('@antigravity-cli/gpt-oss-120b')
            .map((o) => o.label)
            .toList();
        expect(gptContexts, ['128K（官方固定）']);
        expect(
          kernel.effort.optionsFor('@antigravity-cli/gpt-oss-120b'),
          isEmpty,
        );

        final hydrogenEfforts = kernel.effort
            .optionsFor('@antigravity-cli/gemini-4-hydrogen')
            .map((o) => o.id)
            .toList();
        expect(hydrogenEfforts, ['low', 'medium', 'high', 'xhigh']);

        // Switching Argon's context window updates selected context & emits UsageReported immediately.
        kernel.model.select('@antigravity-cli/gemini-4-argon');
        await Future<void>.delayed(Duration.zero);
        expect(kernel.contextSize.selected, '512000');
        expect(kernel.contextWindow, 512000);

        kernel.contextSize.select(
          '@antigravity-cli/gemini-4-argon',
          '900000',
        );
        await Future<void>.delayed(Duration.zero);
        expect(kernel.contextSize.selected, '900000');
        expect(kernel.contextWindow, 900000);
        expect(reported, isNotEmpty);
        expect(reported.last.usage.window, 900000);
      },
    );
  });

  group('AntigravityTransport CLI flags, context env & usage accuracy', () {
    test('buildCliArguments and buildProcessEnvironment wire Argon 512K/900K via AGY_CLI_AUTO_COMPACT_OVERRIDE', () {
      final argonArgs = AntigravityTransport.buildCliArguments(
        model: 'gemini-4-argon',
        effort: 'high',
        permissionMode: 'default',
        maxContextTokens: 512000,
        conversationId: 'conv-123',
      );
      expect(argonArgs, contains('--settings={"contextWindow":"512K"}'));
      expect(argonArgs, contains('--model=gemini-4-argon'));
      expect(argonArgs, contains('--effort=high'));

      final argon512Env = AntigravityTransport.buildProcessEnvironment(
        baseEnvironment: const {'PATH': '/usr/bin'},
        model: 'gemini-4-argon',
        maxContextTokens: 512000,
      );
      expect(argon512Env['AGY_CLI_AUTO_COMPACT_OVERRIDE'], '512000');

      final argon256Env = AntigravityTransport.buildProcessEnvironment(
        baseEnvironment: const {
          'PATH': '/usr/bin',
          'AGY_CLI_AUTO_COMPACT_OVERRIDE': '512000',
        },
        model: 'gemini-4-argon',
        maxContextTokens: 256000,
      );
      expect(
        argon256Env.containsKey('AGY_CLI_AUTO_COMPACT_OVERRIDE'),
        isFalse,
      );

      final carbonArgs = AntigravityTransport.buildCliArguments(
        model: 'gemini-4-carbon',
        effort: 'high',
        permissionMode: 'default',
        maxContextTokens: 256000,
      );
      expect(
        carbonArgs.any((arg) => arg.startsWith('--settings=')),
        isFalse,
      );

      final neon512Args = AntigravityTransport.buildCliArguments(
        model: 'gemini-4-neon',
        effort: 'high',
        permissionMode: 'default',
        maxContextTokens: 512000,
      );
      expect(neon512Args, contains('--settings={"contextWindow":"512K"}'));

      final neon512Env = AntigravityTransport.buildProcessEnvironment(
        baseEnvironment: const {'PATH': '/usr/bin'},
        model: 'gemini-4-neon',
        maxContextTokens: 512000,
      );
      expect(neon512Env['AGY_CLI_AUTO_COMPACT_OVERRIDE'], '512000');

      final hydrogenEnv = AntigravityTransport.buildProcessEnvironment(
        baseEnvironment: const {
          'PATH': '/usr/bin',
          'AGY_CLI_AUTO_COMPACT_OVERRIDE': '512000',
        },
        model: 'gemini-4-hydrogen',
        maxContextTokens: 256000,
      );
      expect(
        hydrogenEnv.containsKey('AGY_CLI_AUTO_COMPACT_OVERRIDE'),
        isFalse,
      );
    });

    test('convertAgyUsage handles both legacy inclusive and current exclusive agy usage payloads', () {
      // Legacy agy format where input_tokens already includes cache_read_tokens
      // and total_tokens == input_tokens + output_tokens.
      final legacy = AntigravityTransport.convertAgyUsage(const {
        'input_tokens': 148793,
        'output_tokens': 2811,
        'thinking_tokens': 412,
        'cache_read_tokens': 144783,
        'total_tokens': 151604,
      });
      expect(legacy, isNotNull);
      expect(legacy!.contextTokens, 151604);
      expect(legacy.usage['input_tokens'], 4010);
      expect(legacy.usage['cache_read_input_tokens'], 144783);
      expect(legacy.usage['output_tokens'], 2811);

      // Current agy format where input_tokens is uncached input only (often
      // smaller than cache_read_tokens) and total_tokens may be absent or
      // equal to input + cache_read + output.
      final currentNoTotal = AntigravityTransport.convertAgyUsage(const {
        'input_tokens': 2975,
        'output_tokens': 2517,
        'thinking_tokens': 1556,
        'cache_read_tokens': 30911,
      });
      expect(currentNoTotal, isNotNull);
      expect(currentNoTotal!.contextTokens, 36403);
      expect(currentNoTotal.usage['input_tokens'], 2975);
      expect(currentNoTotal.usage['cache_read_input_tokens'], 30911);
      expect(currentNoTotal.usage['output_tokens'], 2517);

      // Current agy format where a single step adds more uncached input than
      // the cached prefix (input_tokens > cache_read_tokens).
      final currentLargeDelta = AntigravityTransport.convertAgyUsage(const {
        'input_tokens': 60000,
        'output_tokens': 1000,
        'cache_read_tokens': 25000,
        'total_tokens': 86000,
      });
      expect(currentLargeDelta, isNotNull);
      expect(currentLargeDelta!.contextTokens, 86000);
      expect(currentLargeDelta.usage['input_tokens'], 60000);
      expect(currentLargeDelta.usage['cache_read_input_tokens'], 25000);

      // Even if total_tokens omits cache_read_tokens when input < cache_read,
      // contextTokens still accounts for cache_read_tokens.
      final currentUnderstatedTotal = AntigravityTransport.convertAgyUsage(const {
        'input_tokens': 2975,
        'output_tokens': 2517,
        'cache_read_tokens': 30911,
        'total_tokens': 5492,
      });
      expect(currentUnderstatedTotal, isNotNull);
      expect(currentUnderstatedTotal!.contextTokens, 36403);
      expect(currentUnderstatedTotal.usage['input_tokens'], 2975);
    });

    test('buildContextCategories reports aggregate used/free segments honestly without synthetic splits', () {
      final cats = AntigravityTransport.buildContextCategories(151604, 512000);
      expect(cats.length, 2);
      expect(ContextUsagePanel.partOf('${cats[0]['name']}'), 'used');
      expect(cats[0]['tokens'], 151604);
      expect(cats[0]['kind'], 'used');
      expect(cats[1]['tokens'], 512000 - 151604);
      expect(cats[1]['kind'], 'free');

      final empty = AntigravityTransport.buildContextCategories(0, 512000);
      expect(empty.length, 1);
      expect(empty.single['kind'], 'free');
      expect(empty.single['tokens'], 512000);
    });
  });

  group('AntigravityTransport tool mapping & normalization', () {
    test('normalizeToolParams decodes JSON-encoded parameter values', () {
      final raw = <String, Object?>{
        'Path': '"/workspace/app/package.json"',
        'StartLine': '1',
        'EndLine': '80',
        'IsDaemon': 'true',
        'PlainString': 'unquoted-value',
      };
      final normalized = AntigravityTransport.normalizeToolParams(raw);
      expect(normalized['Path'], '/workspace/app/package.json');
      expect(normalized['StartLine'], 1);
      expect(normalized['EndLine'], 80);
      expect(normalized['IsDaemon'], true);
      expect(normalized['PlainString'], 'unquoted-value');
    });

    test('cleanToolOutput strips Created At / Completed At headers', () {
      const rawRead =
          'Created At: 2026-11-07T08:40:27+08:00\n'
          'Completed At: 2026-11-07T08:40:27+08:00\n'
          'Showing lines 1-3 of 3\n'
          '1: {\n2:   "name": "demo"\n3: }';
      expect(
        AntigravityTransport.cleanToolOutput('read_file', rawRead),
        'Showing lines 1-3 of 3\n1: {\n2:   "name": "demo"\n3: }',
      );

      const rawBash =
          'Created At: 2026-11-07T08:40:27+08:00\n'
          'Completed At: 2026-11-07T08:40:28+08:00\n'
          'Command exited with code 0.\n\n'
          'Command output:\n'
          'HTTP/1.1 200 OK';
      expect(
        AntigravityTransport.cleanToolOutput('run_command', rawBash),
        'HTTP/1.1 200 OK',
      );
    });

    test('mapTool translates read_file, edit_file, and run_command', () {
      final readMapped = AntigravityTransport.mapTool(
        'read_file',
        {
          'Path': '"/workspace/app/package.json"',
          'StartLine': '10',
          'EndLine': '29',
        },
        '10: line',
      );
      expect(readMapped.name, 'Read');
      expect(readMapped.input, {
        'file_path': '/workspace/app/package.json',
        'offset': 10,
        'limit': 20,
      });

      final editMapped = AntigravityTransport.mapTool(
        'edit_file',
        {
          'Path': '"/workspace/app/README.md"',
          'Target': '"old line"',
          'Replacement': '"new line"',
        },
        'Made 1 replacement',
      );
      expect(editMapped.name, 'Edit');
      expect(editMapped.input['file_path'], '/workspace/app/README.md');
      expect(editMapped.input['old_string'], 'old line');
      expect(editMapped.input['new_string'], 'new line');
      expect(editMapped.structuredResult, isNotNull);

      final bashMapped = AntigravityTransport.mapTool(
        'run_command',
        {
          'CommandLine': '"pnpm run dev:docs"',
          'toolSummary': '"Start docs server"',
        },
        'Server listening on 5173',
      );
      expect(bashMapped.name, 'Bash');
      expect(bashMapped.input['command'], 'pnpm run dev:docs');
      expect(bashMapped.input['description'], 'Start docs server');
    });
  });

  group('AntigravityTransport per-turn duration', () {
    test(
      'reports current turn elapsed duration_ms instead of cumulative session duration_seconds',
      () async {
        final tmp = await Directory.systemTemp.createTemp('ayte_agy_dur_');
        addTearDown(() => tmp.delete(recursive: true));

        final script = File(p.join(tmp.path, 'fake_agy.sh'));
        await script.writeAsString('''#!/bin/sh
set -eu
DIR="${tmp.path}"

IFS= read -r _line1
printf '%s\\n' '{"event":"init","conversation_id":"conv-duration-test"}'
printf '%s\\n' '{"event":"step_update","step_update":{"step_index":0,"step_type":"agent_response","state":"RUNNING","text_delta":"t1"}}'
while [ ! -f "\$DIR/go1" ]; do sleep 0.01; done
printf '%s\\n' '{"event":"result","result":{"status":"ERROR","error":"FAILED_PRECONDITION (code 400): User location is not supported for the API use.","duration_seconds":69120.5}}'

IFS= read -r _line2
printf '%s\\n' '{"event":"step_update","step_update":{"step_index":1,"step_type":"agent_response","state":"RUNNING","text_delta":"t2"}}'
while [ ! -f "\$DIR/go2" ]; do sleep 0.01; done
printf '%s\\n' '{"event":"result","result":{"status":"SUCCESS","response":"done","duration_seconds":70440.25}}'
''');
        await Process.run('chmod', ['+x', script.path]);

        var now = DateTime.utc(2026, 11, 19, 11, 0, 0);
        final transport = AntigravityTransport.forTesting(
          executable: script.path,
          environment: {'HOME': tmp.path},
          launch: ClaudeLaunch(
            cwd: tmp.path,
            model: '@antigravity-cli/gemini-4-hydrogen',
            persist: false,
          ),
          now: () => now,
        );
        addTearDown(transport.close);

        final events = <Map<String, Object?>>[];
        final sub = transport.messages.listen(events.add);
        addTearDown(sub.cancel);

        Future<Map<String, Object?>> waitForEvent(
          bool Function(Map<String, Object?> e) testFn, {
          int fromIndex = 0,
        }) async {
          for (var i = fromIndex; i < events.length; i++) {
            if (testFn(events[i])) return events[i];
          }
          await for (final e in transport.messages) {
            if (testFn(e)) return e;
          }
          throw StateError('Stream closed before matching event');
        }

        // Turn 1: agy reports 19h12m (69120.5s) cumulative session duration,
        // while this turn only ran for 12s.
        transport.write({
          'type': 'user',
          'uuid': 'turn-1',
          'message': {'role': 'user', 'content': 'first'},
        });
        await waitForEvent((e) => e['type'] == 'stream_event');
        now = now.add(const Duration(seconds: 12));
        await File(p.join(tmp.path, 'go1')).writeAsString('1');

        final result1 = await waitForEvent((e) => e['type'] == 'result');
        expect(result1['subtype'], 'error');
        expect(result1['duration_ms'], 12000);

        final turn2StartIdx = events.length;
        // Idle 5 minutes between turns, then Turn 2 runs for 7s while agy
        // reports 19h34m (70440.25s) cumulative duration.
        now = now.add(const Duration(minutes: 5));
        transport.write({
          'type': 'user',
          'uuid': 'turn-2',
          'message': {'role': 'user', 'content': 'second'},
        });
        await waitForEvent(
          (e) => e['type'] == 'stream_event',
          fromIndex: turn2StartIdx,
        );
        now = now.add(const Duration(seconds: 7));
        await File(p.join(tmp.path, 'go2')).writeAsString('1');

        final result2 = await waitForEvent(
          (e) => e['type'] == 'result',
          fromIndex: turn2StartIdx,
        );
        expect(result2['subtype'], 'success');
        expect(result2['duration_ms'], 7000);

        final startedIds = events
            .where(
              (e) =>
                  e['type'] == 'command_lifecycle' && e['state'] == 'started',
            )
            .map((e) => e['command_uuid'])
            .toList();
        expect(startedIds, ['turn-1', 'turn-2']);
      },
      skip: Platform.isWindows ? 'Requires POSIX /bin/sh' : false,
    );
  });

  group('AntigravityTransport F2 launch parity, SDK MCP bridge & settings', () {
    test('buildCliArguments merges extraSettings, sessionConfigDir, and existing readable folders', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_cli_args_');
      addTearDown(() => tmp.delete(recursive: true));
      final readableDir = Directory(p.join(tmp.path, 'pastes'))..createSync();
      final missingDir = p.join(tmp.path, 'missing');
      final cfgDir = Directory(p.join(tmp.path, 'cfg'))..createSync();

      final args = AntigravityTransport.buildCliArguments(
        model: 'gemini-4-argon',
        effort: 'high',
        permissionMode: 'default',
        maxContextTokens: 512000,
        directories: [readableDir.path, tmp.path],
        readable: [readableDir.path, missingDir],
        sessionConfigDir: cfgDir.path,
        extraSettings: const {
          'permissions': {
            'allow': ['WebFetch'],
            'deny': ['mcp__baocode__x'],
          },
        },
      );

      final settingsArg = args.singleWhere((a) => a.startsWith('--settings='));
      final decoded =
          jsonDecode(settingsArg.substring('--settings='.length)) as Map;
      expect(decoded['contextWindow'], '512K');
      expect(decoded['permissions'], {
        'allow': ['WebFetch'],
        'deny': ['mcp__baocode__x'],
      });

      final addDirs = args
          .where((a) => a.startsWith('--add-dir='))
          .map((a) => a.substring('--add-dir='.length))
          .toList();
      expect(addDirs, [readableDir.path, tmp.path, cfgDir.path]);
    });

    test('buildSessionInstructions covers ownPrompt, instructions, sdkInstructions, attribution, and tools', () {
      final defaultInstr = AntigravityTransport.buildSessionInstructions(
        launch: const ClaudeLaunch(
          cwd: '/app',
          instructions: 'Project notes.',
          attribution: CommitAttribution.baocode,
        ),
        sdkInstructions: 'SDK feature guide.',
      )!;
      expect(defaultInstr, contains('<citing_code>'));
      expect(defaultInstr, contains('Project notes.'));
      expect(defaultInstr, contains('SDK feature guide.'));
      expect(defaultInstr, contains(CommitAttribution.baoCodeCommit));

      final ownPromptInstr = AntigravityTransport.buildSessionInstructions(
        launch: const ClaudeLaunch(
          cwd: '/app',
          ownPrompt: true,
          instructions: 'You are a bot.',
          attribution: CommitAttribution.none,
          tools: [],
          userServers: false,
        ),
      )!;
      expect(ownPromptInstr, isNot(contains('<citing_code>')));
      expect(ownPromptInstr, contains('Custom System Instructions'));
      expect(ownPromptInstr, contains('You are a bot.'));
      expect(ownPromptInstr, contains('Do NOT add any Co-Authored-By'));
      expect(ownPromptInstr, contains('(none — no built-in tools allowed)'));
      expect(ownPromptInstr, contains('Do not invoke user-configured MCP'));
    });

    test('buildSessionSettings builds allow/deny rules without invalid Claude Read rules', () {
      expect(
        AntigravityTransport.buildSessionSettings(
          const ClaudeLaunch(cwd: '/app'),
        ),
        isEmpty,
      );

      // `readable` folders are passed via `--add-dir`, never as Claude `Read(...)`
      // allow entries (which `agy` rejects and which would overwrite user allowlists).
      expect(
        AntigravityTransport.buildSessionSettings(
          const ClaudeLaunch(
            cwd: '/app',
            readable: [r'C:\data\pastes'],
          ),
        ),
        isEmpty,
      );

      final settings = AntigravityTransport.buildSessionSettings(
        ClaudeLaunch(
          cwd: '/app',
          readable: const [r'C:\data\pastes'],
          allowed: const ['command(ls)', 'command(ls)', 'WebFetch'],
          tools: const ['Read'],
          switches: const ExtensionSwitches(
            disabledServers: {'srv'},
            disabledTools: {
              'baocode': {'foo'},
            },
          ),
        ),
      );
      final perms = settings['permissions'] as Map;
      expect(perms['allow'], ['command(ls)', 'WebFetch']);
      expect(
        perms['deny'],
        containsAll(['mcp__srv', 'mcp__baocode__foo', 'run_command', 'edit_file']),
      );
    });

    test(
      'close() during async bridge startup leaves no leaked bridge or sessionConfigDir',
      () async {
        final tmp = await Directory.systemTemp.createTemp('agy_f2_close_race_');
        addTearDown(() => tmp.delete(recursive: true));

        final transport = AntigravityTransport.forTesting(
          executable: 'agy',
          environment: {'HOME': tmp.path},
          launch: ClaudeLaunch(
            cwd: tmp.path,
            sdkServers: const [ClaudeSdkTools.server],
            instructions: 'Race test.',
          ),
        );

        final prepFuture = transport.prepareSessionArtifactsForTesting();
        transport.close();
        await prepFuture;

        expect(transport.sdkBridgeForTesting, isNull);
        expect(transport.sessionConfigDirForTesting, isNull);
      },
    );

    test(
      '60-iteration staggered-delay close() racing prepareSessionArtifactsForTesting() leaks zero agy-mcp dirs',
      () async {
        final tmp = await Directory.systemTemp.createTemp('agy_f2_race_60_');
        addTearDown(() => tmp.delete(recursive: true));

        final agyMcpRoot = Directory(
          p.join(DataDirectory.current.cacheDir, 'agy-mcp'),
        );
        Set<String> listSubdirs() {
          if (!agyMcpRoot.existsSync()) return const {};
          return agyMcpRoot
              .listSync()
              .whereType<Directory>()
              .map((d) => p.basename(d.path))
              .toSet();
        }

        final before = listSubdirs();

        for (var i = 0; i < 60; i++) {
          final transport = AntigravityTransport.forTesting(
            executable: 'agy',
            environment: {'HOME': tmp.path},
            launch: ClaudeLaunch(
              cwd: tmp.path,
              sdkServers: const [ClaudeSdkTools.server],
              instructions: 'Race stress iteration $i.\n' * 8,
            ),
          );
          final prepFuture = transport.prepareSessionArtifactsForTesting();
          final delayUs = (i * 55) % 3301;
          if (delayUs > 0) {
            await Future<void>.delayed(Duration(microseconds: delayUs));
          }
          transport.close();
          await prepFuture;

          expect(transport.sdkBridgeForTesting, isNull);
          expect(transport.sessionConfigDirForTesting, isNull);
        }

        final after = listSubdirs();
        expect(after.difference(before), isEmpty);
      },
    );

    test(
      'materializes bridge & AGENTS.md, handles apply_flag_settings permissions, ask control channel, and cleans up on close',
      () async {
        const testTool = 'agy_f2_lifecycle_tool';
        ClaudeSdkTools.register(
          ClaudeSdkTool(
            name: testTool,
            description: 'Lifecycle test tool',
            inputSchema: const {'type': 'object'},
            alwaysLoad: true,
            asksItself: true,
            run: (input, call) async {
              final decision = await call.ask?.call(
                const ApprovalRequest(
                  id: '',
                  title: 'Run local test?',
                  toolName: 'mcp__baocode__$testTool',
                  preview: CommandPreview('echo hi', description: '/repo'),
                ),
              );
              return 'sid=${call.sessionId};ask=${decision?.name}';
            },
          ),
        );
        ClaudeSdkTools.instruct('agy_f2', 'Use agy_f2 carefully.');
        addTearDown(() {
          ClaudeSdkTools.unregister(testTool);
          ClaudeSdkTools.instruct('agy_f2', null);
        });

        final tmp = await Directory.systemTemp.createTemp('agy_f2_life_');
        addTearDown(() => tmp.delete(recursive: true));

        final transport = AntigravityTransport.forTesting(
          executable: 'agy',
          environment: {'HOME': tmp.path},
          launch: ClaudeLaunch(
            cwd: tmp.path,
            sdkServers: const [ClaudeSdkTools.server],
            instructions: 'Be concise.',
            attribution: CommitAttribution.baocode,
          ),
        );
        addTearDown(transport.close);

        await transport.prepareSessionArtifactsForTesting();
        final cfgDir = transport.sessionConfigDirForTesting;
        final bridge = transport.sdkBridgeForTesting;
        expect(cfgDir, isNotNull);
        expect(bridge, isNotNull);

        final mcpFile = File(p.join(cfgDir!.path, '.agents', 'mcp_config.json'));
        expect(mcpFile.existsSync(), isTrue);
        final mcpJson = jsonDecode(mcpFile.readAsStringSync()) as Map;
        final baocodeCfg = (mcpJson['mcpServers'] as Map)['baocode'] as Map;
        expect(baocodeCfg['url'], bridge!.endpointUri.toString());
        expect((baocodeCfg['headers'] as Map)['Authorization'], 'Bearer ${bridge.token}');
        expect(baocodeCfg.containsKey('tools'), isFalse);

        final agentsFile = File(p.join(cfgDir.path, 'AGENTS.md'));
        expect(agentsFile.existsSync(), isTrue);
        final agentsText = agentsFile.readAsStringSync();
        expect(agentsText, contains('Be concise.'));
        expect(agentsText, contains('Use agy_f2 carefully.'));

        // Ask flow over control channel + observation of conversation_id in _meta.
        final controlRequests = <Map<String, Object?>>[];
        final sub = transport.messages.listen((m) {
          if (m['type'] == 'control_request') {
            controlRequests.add(m);
            transport.write({
              'type': 'control_response',
              'response': {
                'subtype': 'success',
                'request_id': m['request_id'],
                'response': {'behavior': 'allow'},
              },
            });
          }
        });
        addTearDown(sub.cancel);

        final httpClient = _RealHttpOverrides().newRealClient();
        addTearDown(() => httpClient.close(force: true));
        final req = await httpClient.postUrl(bridge.endpointUri);
        req.headers.set('Authorization', 'Bearer ${bridge.token}');
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': testTool,
              'arguments': const <String, Object?>{},
              '_meta': {
                'antigravity.google/conversation_id': 'conv-from-mcp',
              },
            },
          }),
        );
        final res = await req.close();
        final body = jsonDecode(await utf8.decoder.bind(res).join()) as Map;
        final text = (((body['result'] as Map)['content'] as List).single as Map)['text'];
        expect(text, 'sid=conv-from-mcp;ask=allowOnce');
        expect(controlRequests, hasLength(1));
        expect((controlRequests.single['request'] as Map)['tool_name'], 'Bash');

        // Dynamic disable via apply_flag_settings updates bridge & mcp_config.json.
        transport.write({
          'type': 'control_request',
          'request_id': 'flag-1',
          'request': {
            'subtype': 'apply_flag_settings',
            'settings': {
              'permissions': {
                'allow': <String>[],
                'deny': ['mcp__baocode'],
              },
            },
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final disabledCfg = jsonDecode(mcpFile.readAsStringSync()) as Map;
        expect((disabledCfg['mcpServers'] as Map), isEmpty);

        transport.close();
        expect(cfgDir.existsSync(), isFalse);
      },
    );

    test(
      'preserves non-alphanumeric disabled tools and server keys across apply_flag_settings, mcp_status, tools/list, and tools/call',
      () async {
        const dottedTool = 'probe.dotted-tool';
        const dynamicTool = 'probe.dynamic-tool';
        const okTool = 'probe_ok-tool';
        var dottedRuns = 0;
        var dynamicRuns = 0;

        ClaudeSdkTools.register(
          ClaudeSdkTool(
            name: dottedTool,
            description: 'Dotted probe tool',
            inputSchema: const {'type': 'object'},
            run: (input, call) async {
              dottedRuns++;
              return 'dotted-ok';
            },
          ),
        );
        ClaudeSdkTools.register(
          ClaudeSdkTool(
            name: dynamicTool,
            description: 'Dynamic dotted probe tool',
            inputSchema: const {'type': 'object'},
            run: (input, call) async {
              dynamicRuns++;
              return 'dynamic-ok';
            },
          ),
        );
        ClaudeSdkTools.register(
          ClaudeSdkTool(
            name: okTool,
            description: 'Allowed probe tool',
            inputSchema: const {'type': 'object'},
            run: (input, call) async => 'ok',
          ),
        );
        addTearDown(() {
          ClaudeSdkTools.unregister(dottedTool);
          ClaudeSdkTools.unregister(dynamicTool);
          ClaudeSdkTools.unregister(okTool);
        });

        final prevSave = ExtensionSwitches.save;
        ExtensionSwitches? savedSwitches;
        ExtensionSwitches.save = (sw) async {
          savedSwitches = sw;
        };
        addTearDown(() => ExtensionSwitches.save = prevSave);

        final tmp = await Directory.systemTemp.createTemp('agy_dotted_sw_');
        addTearDown(() => tmp.delete(recursive: true));

        const initialSwitches = ExtensionSwitches(
          disabledTools: {
            ClaudeSdkTools.server: {dottedTool},
            'my.srv': {'ext.tool'},
          },
        );
        final transport = AntigravityTransport.forTesting(
          executable: 'agy',
          environment: {'HOME': tmp.path},
          launch: ClaudeLaunch(
            cwd: tmp.path,
            sdkServers: const [ClaudeSdkTools.server],
            switches: initialSwitches,
          ),
        );
        addTearDown(transport.close);

        await transport.prepareSessionArtifactsForTesting();
        final bridge = transport.sdkBridgeForTesting!;

        final responses = <String, Map<String, Object?>>{};
        final sub = transport.messages.listen((m) {
          if (m['type'] == 'control_response') {
            final resp = (m['response'] as Map).cast<String, Object?>();
            final reqId = resp['request_id'] as String?;
            if (reqId != null) responses[reqId] = resp;
          }
        });
        addTearDown(sub.cancel);

        Future<Map<String, Object?>> sendControl(
          String reqId,
          String subtype, [
          Map<String, Object?> extra = const {},
        ]) async {
          transport.write({
            'type': 'control_request',
            'request_id': reqId,
            'request': {'subtype': subtype, ...extra},
          });
          for (var i = 0; i < 100 && !responses.containsKey(reqId); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(responses.containsKey(reqId), isTrue);
          return responses[reqId]!;
        }

        final httpClient = _RealHttpOverrides().newRealClient();
        addTearDown(() => httpClient.close(force: true));

        Future<List<String>> bridgeToolNames() async {
          final req = await httpClient.postUrl(bridge.endpointUri);
          req.headers.set('Authorization', 'Bearer ${bridge.token}');
          req.headers.contentType = ContentType.json;
          req.write(
            jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}),
          );
          final res = await req.close();
          final body = jsonDecode(await utf8.decoder.bind(res).join()) as Map;
          return (((body['result'] as Map)['tools'] as List).cast<Map>())
              .map((t) => t['name'] as String)
              .toList();
        }

        Future<Map<String, Object?>> callBridgeTool(String name) async {
          final req = await httpClient.postUrl(bridge.endpointUri);
          req.headers.set('Authorization', 'Bearer ${bridge.token}');
          req.headers.contentType = ContentType.json;
          req.write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 2,
              'method': 'tools/call',
              'params': {'name': name, 'arguments': const <String, Object?>{}},
            }),
          );
          final res = await req.close();
          return (jsonDecode(await utf8.decoder.bind(res).join()) as Map)
              .cast<String, Object?>();
        }

        Future<List<String>> mcpStatusBaocodeTools(String reqId) async {
          final resp = await sendControl(reqId, 'mcp_status');
          final servers =
              ((resp['response'] as Map)['mcpServers'] as List).cast<Map>();
          final baocode = servers.firstWhere(
            (s) => s['name'] == ClaudeSdkTools.server,
          );
          return ((baocode['tools'] as List).cast<Map>())
              .map((t) => t['name'] as String)
              .toList();
        }

        // Round-trip initial denyRules through apply_flag_settings.
        await sendControl('flag-1', 'apply_flag_settings', {
          'settings': {
            'permissions': {'allow': <String>[], 'deny': initialSwitches.denyRules},
          },
        });

        expect(await bridgeToolNames(), isNot(contains(dottedTool)));
        expect(await bridgeToolNames(), containsAll([dynamicTool, okTool]));
        expect(
          ((await callBridgeTool(dottedTool))['result'] as Map)['isError'],
          isTrue,
        );
        expect(dottedRuns, 0);
        expect(
          await mcpStatusBaocodeTools('status-1'),
          isNot(contains(dottedTool)),
        );
        expect(
          await mcpStatusBaocodeTools('status-2'),
          containsAll([dynamicTool, okTool]),
        );

        // Mode B: dynamicTool was enabled at launch; call it once, then disable via denyRules.
        final dynOk = await callBridgeTool(dynamicTool);
        expect((dynOk['result'] as Map)['isError'], isNot(isTrue));
        expect(dynamicRuns, 1);

        const updatedSwitches = ExtensionSwitches(
          disabledTools: {
            ClaudeSdkTools.server: {dottedTool, dynamicTool},
            'my.srv': {'ext.tool'},
          },
        );
        await sendControl('flag-2', 'apply_flag_settings', {
          'settings': {
            'permissions': {'allow': <String>[], 'deny': updatedSwitches.denyRules},
          },
        });

        expect(await bridgeToolNames(), isNot(contains(dottedTool)));
        expect(await bridgeToolNames(), isNot(contains(dynamicTool)));
        expect(await bridgeToolNames(), contains(okTool));
        expect(
          ((await callBridgeTool(dynamicTool))['result'] as Map)['isError'],
          isTrue,
        );
        expect(dynamicRuns, 1);
        final statusToolsAfter = await mcpStatusBaocodeTools('status-3');
        expect(statusToolsAfter, isNot(contains(dottedTool)));
        expect(statusToolsAfter, isNot(contains(dynamicTool)));
        expect(statusToolsAfter, contains(okTool));

        // Verify original server key ('my.srv') and original tool name ('probe.dotted-tool') survived.
        await sendControl('toggle-1', 'mcp_toggle', {
          'serverName': 'other-srv',
          'enabled': false,
        });
        expect(savedSwitches, isNotNull);
        expect(savedSwitches!.disabledTools.keys, contains('my.srv'));
        expect(savedSwitches!.disabledTools['my.srv'], contains('ext.tool'));
        expect(
          savedSwitches!.disabledTools[ClaudeSdkTools.server],
          contains(dottedTool),
        );
      },
    );

    test(
      're-syncs bridge disabled state when apply_flag_settings runs while bridge start is in flight',
      () async {
        final tmp = await Directory.systemTemp.createTemp('agy_bridge_race_');
        addTearDown(() => tmp.delete(recursive: true));

        final transport = AntigravityTransport.forTesting(
          executable: 'agy',
          environment: {'HOME': tmp.path},
          launch: ClaudeLaunch(
            cwd: tmp.path,
            sdkServers: const [ClaudeSdkTools.server],
          ),
        );
        addTearDown(transport.close);

        final prepFuture = transport.prepareSessionArtifactsForTesting();
        transport.write({
          'type': 'control_request',
          'request_id': 'race-flag-1',
          'request': {
            'subtype': 'apply_flag_settings',
            'settings': {
              'permissions': {
                'allow': <String>[],
                'deny': ['mcp__baocode'],
              },
            },
          },
        });
        await prepFuture;

        final bridge = transport.sdkBridgeForTesting!;
        final httpClient = _RealHttpOverrides().newRealClient();
        addTearDown(() => httpClient.close(force: true));
        final req = await httpClient.postUrl(bridge.endpointUri);
        req.headers.set('Authorization', 'Bearer ${bridge.token}');
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}),
        );
        final res = await req.close();
        final body = jsonDecode(await utf8.decoder.bind(res).join()) as Map;
        expect((body['result'] as Map)['tools'], isEmpty);
      },
    );
  });

  group('AntigravityTransport F3 MCP tool normalization', () {
    setUp(() {
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: 'session_new',
          description: 'Mock session_new',
          inputSchema: const {'type': 'object'},
          kind: ToolKind.other,
          run: (input, call) async => 'Started: s-new in app.',
        ),
      );
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: 'session_send',
          description: 'Mock session_send',
          inputSchema: const {'type': 'object'},
          kind: ToolKind.other,
          run: (input, call) async => 'Sent',
        ),
      );
    });

    tearDown(() {
      ClaudeSdkTools.unregister('session_new');
      ClaudeSdkTools.unregister('session_send');
    });

    test('normalizes call_mcp_tool, mcp_baocode_*, prefixed, and bare SDK tools', () {
      final lazyBaocode = AntigravityTransport.mapTool(
        'call_mcp_tool',
        {
          'ServerName': '"baocode"',
          'ToolName': '"session_new"',
          'Arguments': '{"text":"run tests","project":"app"}',
        },
        'Started: sess-99 in app.',
      );
      expect(lazyBaocode.name, 'mcp__baocode__session_new');
      expect(lazyBaocode.input, {'text': 'run tests', 'project': 'app'});

      final lazyOther = AntigravityTransport.mapTool(
        'call_mcp_tool',
        {
          'ServerName': '"github"',
          'ToolName': '"get_issue"',
          'Arguments': '{"number":42}',
        },
        'Issue #42',
      );
      expect(lazyOther.name, 'mcp__github__get_issue');
      expect(lazyOther.input, {'number': 42});

      expect(
        AntigravityTransport.mapTool('mcp_baocode_session_send', const {}, '').name,
        'mcp__baocode__session_send',
      );
      expect(
        AntigravityTransport.mapTool('baocode:session_new', const {}, '').name,
        'mcp__baocode__session_new',
      );
      expect(
        AntigravityTransport.mapTool('baocode.session_new', const {}, '').name,
        'mcp__baocode__session_new',
      );
      expect(
        AntigravityTransport.mapTool('baocode/session_new', const {}, '').name,
        'mcp__baocode__session_new',
      );
      expect(
        AntigravityTransport.mapTool('baocode__session_new', const {}, '').name,
        'mcp__baocode__session_new',
      );
      expect(
        AntigravityTransport.mapTool('mcp__baocode__session_new', const {}, '').name,
        'mcp__baocode__session_new',
      );
      expect(
        AntigravityTransport.mapTool('session_new', const {}, '').name,
        'mcp__baocode__session_new',
      );
      expect(
        AntigravityTransport.mapTool(
          'custom_tool',
          const {},
          '',
          serverName: 'baocode',
        ).name,
        'mcp__baocode__custom_tool',
      );
      expect(
        AntigravityTransport.mapTool(
          'call_mcp_tool',
          {
            'ServerName': '"baocode"',
            'ToolName': '"baocode:session_new"',
            'Arguments': const <String, Object?>{'text': 'hi'},
          },
          '',
        ).name,
        'mcp__baocode__session_new',
      );
    });

    test('ClaudeTranslator + SessionLinks recognize normalized mcp__baocode__session_new', () {
      final mapped = AntigravityTransport.mapTool(
        'call_mcp_tool',
        {
          'ServerName': '"baocode"',
          'ToolName': '"session_new"',
          'Arguments': '{"text":"check build"}',
        },
        'Started: sess-link-1 in app.',
      );

      final itemsById = <String, ChatItem>{};
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: (event) {
          if (event is ItemUpserted) {
            itemsById[event.id] = event.item;
          }
        },
        nextSeq: () => ++seq,
      );

      translator.translate({
        'type': 'assistant',
        'message': {
          'id': 'm1',
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'tu-1',
              'name': mapped.name,
              'input': mapped.input,
            },
          ],
        },
      });
      translator.translate({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'tu-1',
              'content': 'Started: sess-link-1 in app.',
              'is_error': false,
            },
          ],
        },
      });

      final toolItem = itemsById.values.whereType<ToolCallItem>().single;
      expect(toolItem.tool, 'session_new');
      expect(isSessionTool(toolItem.tool), isTrue);
      expect(sessionIdsOf(toolItem), ['sess-link-1']);
    });
  });

  group('AntigravityTransport F4 permissions, hooks, plans & control parity', () {
    test('AntigravityModels.of gates bare default on @antigravity-cli prefix', () {
      expect(AntigravityModels.of('default'), isNull);
      expect(AntigravityModels.isAntigravityModel('default'), isFalse);
      expect(AntigravityModels.of('@antigravity-cli/default'), isNotNull);
      expect(
        AntigravityModels.isAntigravityModel('@antigravity-cli/default'),
        isTrue,
      );
      expect(
        AntigravityModels.cliModelIdOf('default'),
        AntigravityModels.current.first.effectiveCliModel,
      );
    });

    test('buildCliArguments maps every permissionMode accurately', () {
      List<String> argsFor(String mode) => AntigravityTransport.buildCliArguments(
        model: 'gemini-3.8-flash',
        effort: 'high',
        permissionMode: mode,
        maxContextTokens: 256000,
      );

      expect(argsFor('acceptEdits'), contains('--mode=accept-edits'));
      expect(argsFor('acceptEdits'), isNot(contains('--dangerously-skip-permissions')));

      expect(argsFor('auto'), contains('--mode=auto'));
      expect(argsFor('auto'), isNot(contains('--dangerously-skip-permissions')));

      expect(argsFor('plan'), contains('--mode=plan'));
      expect(argsFor('plan'), isNot(contains('--dangerously-skip-permissions')));

      final planWithAutoApprove = AntigravityTransport.buildCliArguments(
        model: 'gemini-3.8-flash',
        effort: 'high',
        permissionMode: 'plan',
        autoApproveInPlan: true,
        maxContextTokens: 256000,
      );
      expect(planWithAutoApprove, contains('--mode=plan'));
      expect(planWithAutoApprove, contains('--dangerously-skip-permissions'));

      expect(argsFor('bypassPermissions'), contains('--dangerously-skip-permissions'));
      expect(argsFor('bypassPermissions').any((a) => a.startsWith('--mode=')), isFalse);

      for (final mode in const ['default', 'dontAsk']) {
        final args = argsFor(mode);
        expect(args.any((a) => a.startsWith('--mode=')), isFalse);
        expect(args, isNot(contains('--dangerously-skip-permissions')));
      }
    });

    test('set_permission_mode stops idle process on mode flag change and respawns on next turn', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_mode_');
      addTearDown(() => _deleteWithRetry(tmp));

      final fakeAgy = FakeCliExecutable.create(
        tmp,
        name: 'fake_agy_mode',
        dartBody: r'''
Future<void> main(List<String> args) async {
  recordEvent({'type': 'launch', 'args': args});
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-mode'}));
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'conversation_id': 'conv-mode', 'status': 'SUCCESS', 'response': 'ok'},
    }));
    await stdout.flush();
  }
}
''',
      );

      final transport = AntigravityTransport.forTesting(
        executable: fakeAgy.executablePath,
        environment: {'HOME': tmp.path},
        launch: ClaudeLaunch(cwd: tmp.path, persist: false),
      );
      addTearDown(() async {
        transport.close();
        await transport.exited;
      });

      final responses = <Map<String, Object?>>[];
      final statuses = <Map<String, Object?>>[];
      var results = 0;
      final sub = transport.messages.listen((m) {
        if (m['type'] == 'control_response') responses.add(m);
        if (m['type'] == 'system' && m['subtype'] == 'status') statuses.add(m);
        if (m['type'] == 'result') results++;
      });
      addTearDown(sub.cancel);

      transport.write({
        'type': 'user',
        'uuid': 'u1',
        'message': {'role': 'user', 'content': 'turn 1'},
      });
      while (results < 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      transport.write({
        'type': 'control_request',
        'request_id': 'mode-1',
        'request': {'subtype': 'set_permission_mode', 'mode': 'acceptEdits'},
      });
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(
        (responses.last['response'] as Map)['response'],
        {'mode': 'acceptEdits'},
      );
      expect(statuses.last['permissionMode'], 'acceptEdits');

      transport.write({
        'type': 'user',
        'uuid': 'u2',
        'message': {'role': 'user', 'content': 'turn 2'},
      });
      while (results < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final launches = fakeAgy
          .readCaptures()
          .where((e) => e['type'] == 'launch')
          .toList();
      expect(launches, hasLength(2));
      expect(
        (launches.first['args'] as List).cast<String>(),
        isNot(contains('--mode=accept-edits')),
      );
      expect(
        (launches.last['args'] as List).cast<String>(),
        contains('--mode=accept-edits'),
      );
    });

    test('WatchesEdits serializes PreToolUse -> PostToolUse/PostToolUseFailure before result even on DONE-only steps', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_hooks_');
      addTearDown(() => _deleteWithRetry(tmp));
      final editedPath = p.join(tmp.path, 'src.dart');
      final failedPath = p.join(tmp.path, 'bad.dart');
      final planPath = p.join(tmp.path, '.claude', 'plans', 'p.md');

      final fakeAgy = FakeCliExecutable.create(
        tmp,
        name: 'fake_agy_hooks',
        dartBody: '''
Future<void> main(List<String> args) async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-hooks'}));
    stdout.writeln(jsonEncode({
      'event': 'step_update',
      'step_update': {
        'step_index': 1,
        'step_type': 'tool',
        'state': 'DONE',
        'tool_info': {
          'name': 'edit_file',
          'parameters': {'Path': ${jsonEncode(jsonEncode(editedPath))}, 'Target': '"a"', 'Replacement': '"b"'},
          'output': 'ok',
        },
      },
    }));
    stdout.writeln(jsonEncode({
      'event': 'step_update',
      'step_update': {
        'step_index': 2,
        'step_type': 'tool',
        'state': 'ERROR',
        'tool_info': {
          'name': 'write_file',
          'parameters': {'Path': ${jsonEncode(jsonEncode(failedPath))}, 'Content': '"x"'},
          'error': 'Permission denied',
        },
      },
    }));
    stdout.writeln(jsonEncode({
      'event': 'step_update',
      'step_update': {
        'step_index': 3,
        'step_type': 'tool',
        'state': 'DONE',
        'tool_info': {
          'name': 'write_file',
          'parameters': {'Path': ${jsonEncode(jsonEncode(planPath))}, 'Content': '"# Plan"'},
          'output': 'ok',
        },
      },
    }));
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'conversation_id': 'conv-hooks', 'status': 'SUCCESS', 'response': 'done'},
    }));
    await stdout.flush();
  }
}
''',
      );

      final transport = AntigravityTransport.forTesting(
        executable: fakeAgy.executablePath,
        environment: {'HOME': tmp.path},
        launch: ClaudeLaunch(cwd: tmp.path, persist: false),
      );
      addTearDown(() async {
        transport.close();
        await transport.exited;
      });

      final events = <String>[];
      final initDone = Completer<void>();
      final turnDone = Completer<void>();
      final sub = transport.messages.listen((m) {
        if (m['type'] == 'control_response' &&
            (m['response'] as Map)['request_id'] == 'init-1' &&
            !initDone.isCompleted) {
          initDone.complete();
        }
        if (m['type'] == 'control_request') {
          final req = m['request'] as Map;
          if (req['subtype'] == 'hook_callback') {
            final input = req['input'] as Map;
            final toolInput = input['tool_input'] as Map;
            events.add(
              '${input['hook_event_name']}:${req['callback_id']}:${toolInput['file_path']}',
            );
            Future<void>.delayed(const Duration(milliseconds: 15), () {
              transport.write({
                'type': 'control_response',
                'response': {
                  'subtype': 'success',
                  'request_id': m['request_id'],
                  'response': const <String, Object?>{},
                },
              });
            });
          }
        }
        if (m['type'] == 'result') {
          events.add('result');
          if (!turnDone.isCompleted) turnDone.complete();
        }
      });
      addTearDown(sub.cancel);

      transport.write({
        'type': 'control_request',
        'request_id': 'init-1',
        'request': {
          'subtype': 'initialize',
          'hooks': {
            'PreToolUse': [
              {
                'matcher': 'Edit|Write|MultiEdit|NotebookEdit',
                'hookCallbackIds': ['cb-pre'],
              },
            ],
            'PostToolUse': [
              {
                'matcher': 'Edit|Write|MultiEdit|NotebookEdit',
                'hookCallbackIds': ['cb-post'],
              },
            ],
            'PostToolUseFailure': [
              {
                'matcher': 'Edit|Write|MultiEdit|NotebookEdit',
                'hookCallbackIds': ['cb-fail'],
              },
            ],
          },
        },
      });
      await initDone.future;

      transport.write({
        'type': 'user',
        'uuid': 'u1',
        'message': {'role': 'user', 'content': 'go'},
      });
      await turnDone.future.timeout(const Duration(seconds: 5));

      expect(events, [
        'PreToolUse:cb-pre:$editedPath',
        'PostToolUse:cb-post:$editedPath',
        'PreToolUse:cb-pre:$failedPath',
        'PostToolUseFailure:cb-fail:$failedPath',
        'result',
      ]);
    });

    test('StartsPlans maps exit_plan_mode, synthesizes ExitPlanMode for implementation_plan.md, and normalizes native exit_plan_mode', () async {
      final mappedExit = AntigravityTransport.mapTool(
        'exit_plan_mode',
        {'Path': '"/repo/plans/p.md"', 'Plan': '"# P"'},
        'done',
      );
      expect(mappedExit.name, 'ExitPlanMode');
      expect(mappedExit.input, {'planFilePath': '/repo/plans/p.md', 'plan': '# P'});
      expect(
        AntigravityTransport.mapTool('enter_plan_mode', const {}, '').name,
        'EnterPlanMode',
      );

      final tmp = await Directory.systemTemp.createTemp('agy_f4_plan_');
      addTearDown(() => _deleteWithRetry(tmp));
      final implPlan = p.join(tmp.path, 'implementation_plan.md');

      final fakeAgy = FakeCliExecutable.create(
        tmp,
        name: 'fake_agy_plan',
        dartBody: '''
Future<void> main(List<String> args) async {
  var turn = 0;
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    turn++;
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-plan'}));
    if (turn == 1) {
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 1,
          'step_type': 'tool',
          'state': 'DONE',
          'tool_info': {
            'name': 'write_file',
            'parameters': {'Path': ${jsonEncode(jsonEncode(implPlan))}, 'Content': '"# Impl Plan\\n1. Step"'},
            'output': 'Wrote plan',
          },
        },
      }));
    } else {
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 2,
          'step_type': 'tool',
          'state': 'DONE',
          'tool_info': {
            'name': 'exit_plan_mode',
            'parameters': {'Path': ${jsonEncode(jsonEncode(implPlan))}, 'Plan': '"# Impl Plan v2"'},
            'output': 'Exited plan mode',
          },
        },
      }));
    }
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'conversation_id': 'conv-plan', 'status': 'SUCCESS', 'response': 'ready'},
    }));
    await stdout.flush();
  }
}
''',
      );

      final kernel = ClaudeCodeKernel(
        KernelRegistry.antigravity,
        KernelContext(cwd: tmp.path),
        start: (launch) async => AntigravityTransport.forTesting(
          executable: fakeAgy.executablePath,
          environment: {'HOME': tmp.path},
          launch: launch,
        ),
      );
      addTearDown(kernel.dispose);

      final items = <ChatItem>[];
      var turnsEnded = 0;
      final sub = kernel.events.listen((e) {
        if (e is ItemUpserted) items.add(e.item);
        if (e is TurnEnded) turnsEnded++;
      });
      addTearDown(sub.cancel);

      kernel.mode.select('plan');
      kernel.send(const KernelTurn(id: 'p1', text: 'plan it'));
      while (turnsEnded < 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final plan1 = items.whereType<PlanItem>().last;
      expect(plan1.path, implPlan);
      expect(plan1.status, PlanStatus.awaiting);

      // Native exit_plan_mode in plan mode also keeps awaiting status (not auto-approved).
      kernel.send(const KernelTurn(id: 'p2', text: 'refine plan'));
      while (turnsEnded < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final plan2 = items.whereType<PlanItem>().last;
      expect(plan2.status, PlanStatus.awaiting);
    });

    test('file_suggestions respects .gitignore without .git, excludes build dirs, and supports fuzzy queries', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_files_');
      addTearDown(() => tmp.delete(recursive: true));
      File(p.join(tmp.path, '.gitignore')).writeAsStringSync('secret/\n*.tmp\n');
      File(p.join(tmp.path, 'lib', 'widget_box.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('class WidgetBox {}');
      File(p.join(tmp.path, 'secret', 'key.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('hidden');
      File(p.join(tmp.path, 'notes.tmp')).writeAsStringSync('tmp');

      final transport = AntigravityTransport.forTesting(
        executable: 'agy',
        environment: {'HOME': tmp.path},
        launch: ClaudeLaunch(cwd: tmp.path, persist: false),
      );
      addTearDown(transport.close);

      final responses = <String, Map<String, Object?>>{};
      final sub = transport.messages.listen((m) {
        if (m['type'] == 'control_response') {
          final r = m['response'] as Map;
          responses[r['request_id'] as String] =
              (r['response'] as Map).cast<String, Object?>();
        }
      });
      addTearDown(sub.cancel);

      transport.write({
        'type': 'control_request',
        'request_id': 'fs-1',
        'request': {'subtype': 'file_suggestions', 'query': 'wbox'},
      });
      while (!responses.containsKey('fs-1')) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final suggestions = (responses['fs-1']!['suggestions'] as List)
          .cast<Map>()
          .map((e) => e['path'] as String)
          .toList();
      expect(suggestions, contains('lib/widget_box.dart'));
      expect(suggestions, isNot(contains('secret/key.txt')));
      expect(suggestions, isNot(contains('notes.tmp')));
    });

    test('MCP controls (mcp_status, mcp_toggle, mcp_reconnect, mcp_authenticate) & apply_flag_settings work end-to-end', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_mcp_');
      addTearDown(() => _deleteWithRetry(tmp));
      final homeDir = Directory(p.join(tmp.path, 'home'))..createSync();
      final projDir = Directory(p.join(tmp.path, 'proj'))..createSync();

      const testSdkTool = 'agy_f4_sdk_probe_tool';
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: testSdkTool,
          description: 'F4 SDK tool',
          inputSchema: const {'type': 'object'},
          run: (_, _) async => 'ok',
        ),
      );
      addTearDown(() => ClaudeSdkTools.unregister(testSdkTool));

      final fakeMcpScript = File(p.join(tmp.path, 'fake_mcp.dart'))
        ..writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final msg = jsonDecode(line) as Map<String, Object?>;
    final id = msg['id'];
    if (msg['method'] == 'initialize') {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {'serverInfo': {'name': 'fake-mcp', 'version': '2.1.0'}},
      }));
    } else if (msg['method'] == 'tools/list') {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'tools': [{'name': 'ping_tool', 'description': 'Ping'}]
        },
      }));
      await stdout.flush();
      break;
    }
    await stdout.flush();
  }
}
''');

      File(p.join(projDir.path, '.mcp.json')).writeAsStringSync(
        jsonEncode({
          'mcpServers': {
            'live-stdio': {
              'command': resolveDartExecutable(),
              'args': [fakeMcpScript.path],
            },
          },
        }),
      );

      final transport = AntigravityTransport.forTesting(
        executable: 'agy',
        environment: {'HOME': homeDir.path},
        launch: ClaudeLaunch(
          cwd: projDir.path,
          sdkServers: const [ClaudeSdkTools.server],
          persist: false,
        ),
      );
      addTearDown(transport.close);

      final responses = <String, Map<String, Object?>>{};
      final sub = transport.messages.listen((m) {
        if (m['type'] == 'control_response') {
          final r = m['response'] as Map;
          responses[r['request_id'] as String] =
              (r['response'] as Map).cast<String, Object?>();
        }
      });
      addTearDown(sub.cancel);

      Future<Map<String, Object?>> req(
        String id,
        String subtype, [
        Map<String, Object?> fields = const {},
      ]) async {
        transport.write({
          'type': 'control_request',
          'request_id': id,
          'request': {'subtype': subtype, ...fields},
        });
        while (!responses.containsKey(id)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return responses[id]!;
      }

      final st1 = await req('m1', 'mcp_status');
      final list1 = (st1['mcpServers'] as List).cast<Map>();
      final sdkEntry = list1.firstWhere((e) => e['name'] == 'baocode');
      expect(sdkEntry['status'], 'connected');
      expect(sdkEntry['scope'], 'sdk');
      expect(
        (sdkEntry['tools'] as List).cast<Map>().map((t) => t['name']),
        contains(testSdkTool),
      );

      final extEntry = list1.firstWhere((e) => e['name'] == 'live-stdio');
      expect(extEntry['status'], 'connected');
      expect(extEntry['scope'], 'project');
      expect(
        (extEntry['tools'] as List).cast<Map>().map((t) => t['name']),
        contains('ping_tool'),
      );

      await req('m2', 'mcp_toggle', {'serverName': 'live-stdio', 'enabled': false});
      final st2 = await req('m3', 'mcp_status');
      final disabledExt = (st2['mcpServers'] as List)
          .cast<Map>()
          .firstWhere((e) => e['name'] == 'live-stdio');
      expect(disabledExt['status'], 'disabled');

      await req('m4', 'mcp_toggle', {'serverName': 'live-stdio', 'enabled': true});
      await req('m5', 'mcp_reconnect', {'serverName': 'live-stdio'});
      final st3 = await req('m6', 'mcp_status');
      final reenabledExt = (st3['mcpServers'] as List)
          .cast<Map>()
          .firstWhere((e) => e['name'] == 'live-stdio');
      expect(reenabledExt['status'], 'connected');

      expect(
        await req('m7', 'mcp_authenticate', {'serverName': 'live-stdio'}),
        isEmpty,
      );

      // Generalize apply_flag_settings deny rules to external MCP servers too.
      await req('m8', 'apply_flag_settings', {
        'settings': {
          'permissions': {
            'deny': ['mcp__live-stdio'],
          },
        },
      });
      final st4 = await req('m9', 'mcp_status');
      expect(
        (st4['mcpServers'] as List)
            .cast<Map>()
            .firstWhere((e) => e['name'] == 'live-stdio')['status'],
        'disabled',
      );
    });

    test('get_usage + AntigravityAccounts honor ClaudeEnvironment and map quota windows', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_usage_');
      addTearDown(() => _deleteWithRetry(tmp));
      final homeDir = Directory(p.join(tmp.path, 'home'))..createSync();
      final projDir = Directory(p.join(tmp.path, 'proj'))..createSync();
      final accDir = Directory(
        p.join(homeDir.path, '.ayte', 'antigravity_accounts', 'accounts'),
      )..createSync(recursive: true);
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      File(p.join(accDir.path, 'acc-1.json')).writeAsStringSync(
        jsonEncode({
          'id': 'acc-1',
          'email': 'u@example.com',
          'token': {
            'access_token': 't',
            'refresh_token': '1//r',
            'expires_in': 3600,
            'expiry_timestamp': nowSec + 3600,
          },
          'created_at': nowSec,
          'last_used': nowSec,
          'quota': {
            'last_updated': nowSec,
            'subscription_tier': 'ULTRA',
            'quota_groups': [
              {
                'display_name': 'Gemini Models',
                'buckets': [
                  {
                    'bucket_id': 'gemini-5h',
                    'window': '5h',
                    'remaining_fraction': 0.75,
                    'reset_time': '2026-11-22T18:00:00Z',
                    'display_name': '5h',
                  },
                ],
              },
            ],
          },
        }),
      );

      final fakeAgy = FakeCliExecutable.create(
        tmp,
        name: 'fake_agy_usage',
        dartBody: r'''
Future<void> main(List<String> args) async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
  }
}
''',
      );

      ClaudeCodeKernel.forgetAccount();
      addTearDown(ClaudeCodeKernel.forgetAccount);
      ClaudeEnvironment.use({'HOME': homeDir.path});
      addTearDown(() => ClaudeEnvironment.use(null));

      final kernel = ClaudeCodeKernel(
        KernelRegistry.antigravity,
        KernelContext(cwd: projDir.path),
        start: (launch) async => AntigravityTransport.forTesting(
          executable: fakeAgy.executablePath,
          environment: {'HOME': homeDir.path},
          launch: launch,
        ),
      );
      addTearDown(kernel.dispose);

      await kernel.refreshUsage();
      expect(kernel.accountLimits, hasLength(1));
      expect(kernel.accountLimits.single.label, 'Gemini Models (5h)');
      expect(kernel.accountLimits.single.utilization, closeTo(0.25, 0.001));
      expect(AntigravityTransport.buildUsagePayload(null), {
        'rate_limits_available': false,
      });
    });

    test('honest rewind_*, stop_task, background_tasks & real get_hooks_listing', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_ctrl_');
      addTearDown(() => tmp.delete(recursive: true));
      final homeDir = Directory(p.join(tmp.path, 'home'))..createSync();
      final projDir = Directory(p.join(tmp.path, 'proj'))..createSync();

      File(p.join(homeDir.path, '.gemini', 'config', 'hooks.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'hooks': {
              'Stop': [
                {
                  'matcher': '',
                  'hooks': [
                    {'type': 'command', 'command': 'echo done'},
                  ],
                },
              ],
            },
          }),
        );
      File(p.join(projDir.path, '.agents', 'hooks.local.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{not valid json');

      final transport = AntigravityTransport.forTesting(
        executable: 'agy',
        environment: {'HOME': homeDir.path},
        launch: ClaudeLaunch(cwd: projDir.path, persist: false),
      );
      addTearDown(transport.close);

      final fullResponses = <String, Map<String, Object?>>{};
      final sub = transport.messages.listen((m) {
        if (m['type'] == 'control_response') {
          final r = (m['response'] as Map).cast<String, Object?>();
          fullResponses[r['request_id'] as String] = r;
        }
      });
      addTearDown(sub.cancel);

      Future<Map<String, Object?>> sendCtrl(String id, String subtype) async {
        transport.write({
          'type': 'control_request',
          'request_id': id,
          'request': {'subtype': subtype},
        });
        while (!fullResponses.containsKey(id)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return fullResponses[id]!;
      }

      final r1 = await sendCtrl('c1', 'rewind_conversation');
      expect((r1['response'] as Map)['rewound'], isFalse);

      final r2 = await sendCtrl('c2', 'rewind_files');
      expect((r2['response'] as Map)['canRewind'], isFalse);

      final r3 = await sendCtrl('c3', 'stop_task');
      expect(r3['subtype'], 'error');

      final r4 = await sendCtrl('c4', 'background_tasks');
      expect(r4['subtype'], 'error');

      final r5 = await sendCtrl('c5', 'get_hooks_listing');
      expect(r5['subtype'], 'success');
      final hooks = ((r5['response'] as Map)['hooks'] as List).cast<Map>();
      expect(hooks, hasLength(1));
      expect(hooks.single, {
        'event': 'Stop',
        'matcher': '',
        'source': 'user',
        'type': 'command',
        'commandText': 'echo done',
      });
    });

    test('syncAntigravityTranscriptIfNeeded and readBrainContextTokens tolerate malformed UTF-8 & corrupt JSON lines', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_utf8_');
      addTearDown(() => tmp.delete(recursive: true));
      final homeDir = Directory(p.join(tmp.path, 'home'))..createSync();
      final projDir = Directory(p.join(tmp.path, 'proj'))..createSync();
      const sid = '11111111-aaaa-4111-8111-222222222222';
      final transcriptFile = File(
        p.join(
          homeDir.path,
          '.gemini',
          'antigravity-cli',
          'brain',
          sid,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
      )..createSync(recursive: true);

      final valid1 = utf8.encode(
        '${jsonEncode({'type': 'USER_INPUT', 'content': 'hello'})}\n',
      );
      final badUtf8 = <int>[0xFF, 0xFE, 0x0A];
      final badJson = utf8.encode('{corrupt\n');
      final valid2 = utf8.encode(
        '${jsonEncode({
          'type': 'PLANNER_RESPONSE',
          'content': 'world',
          'input_tokens': 1200,
          'output_tokens': 300,
          'cache_read_tokens': 200,
        })}\n',
      );
      transcriptFile.writeAsBytesSync([
        ...valid1,
        ...badUtf8,
        ...badJson,
        ...valid2,
      ]);

      final tokens = AntigravityTransport.readBrainContextTokens(
        sid,
        home: homeDir.path,
      );
      expect(tokens, isNotNull);
      expect(tokens!.inputTokens, 1200);
      expect(tokens.cacheReadTokens, 200);
      expect(tokens.outputTokens, 300);
      expect(tokens.contextTokens, 1700);

      final syncedPath = syncAntigravityTranscriptIfNeeded(
        cwd: projDir.path,
        sessionId: sid,
        paths: AgentPaths(home: homeDir.path, configDir: p.join(homeDir.path, '.ayte')),
      );
      expect(syncedPath, isNotNull);
      final syncedText = File(syncedPath!).readAsStringSync();
      expect(syncedText, contains('hello'));
      expect(syncedText, contains('world'));
      expect(syncedText, contains('"input_tokens":1200'));
      expect(syncedText, contains('"cache_read_input_tokens":200'));
    });

    test('cancel_async_message removes queued turns, rejects executing/unknown turns, and /clear resets state + temp images', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_queue_clear_');
      addTearDown(() => _deleteWithRetry(tmp));
      final prevDataDir = DataDirectory.current;
      DataDirectory.current = DataDirectory(p.join(tmp.path, 'app_data'));
      addTearDown(() => DataDirectory.current = prevDataDir);

      final sigFile = File(p.join(tmp.path, 'go.sig'));
      final fakeAgy = FakeCliExecutable.create(
        tmp,
        name: 'fake_agy_queue_clear',
        dartBody: '''
Future<void> main(List<String> args) async {
  var turn = 0;
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    turn++;
    recordEvent({'type': 'stdin', 'turn': turn, 'line': line});
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-qc-\$turn'}));
    await stdout.flush();
    if (turn == 1) {
      final sig = File(${jsonEncode(sigFile.path)});
      for (var i = 0; i < 200 && !sig.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'conversation_id': 'conv-qc-\$turn', 'status': 'SUCCESS', 'response': 'ok \$turn'},
    }));
    await stdout.flush();
  }
}
''',
      );

      final transport = AntigravityTransport.forTesting(
        executable: fakeAgy.executablePath,
        environment: {'HOME': tmp.path},
        launch: ClaudeLaunch(cwd: tmp.path, persist: false),
      );
      addTearDown(() {
        if (!sigFile.existsSync()) sigFile.writeAsStringSync('go');
        transport.close();
      });

      final responses = <String, Map<String, Object?>>{};
      final lifecycle = <Map<String, Object?>>[];
      final sessionStates = <String>[];
      var resultCount = 0;
      final sub = transport.messages.listen((m) {
        if (m['type'] == 'control_response') {
          final r = m['response'] as Map;
          responses[r['request_id'] as String] =
              (r['response'] as Map).cast<String, Object?>();
        }
        if (m['type'] == 'command_lifecycle') lifecycle.add(m);
        if (m['type'] == 'system' && m['subtype'] == 'session_state_changed') {
          sessionStates.add('${m['state']}');
        }
        if (m['type'] == 'result') resultCount++;
      });
      addTearDown(sub.cancel);

      const pngBase64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
      transport.write({
        'type': 'user',
        'uuid': 'turn-exec',
        'message': {
          'role': 'user',
          'content': [
            {
              'type': 'image',
              'source': {'type': 'base64', 'media_type': 'image/png', 'data': pngBase64},
            },
            {'type': 'text', 'text': 'turn 1'},
          ],
        },
      });
      while (fakeAgy.stdinCaptures().isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final agyImgDir = Directory(p.join(DataDirectory.current.cacheDir, 'agy-img'));
      expect(agyImgDir.existsSync(), isTrue);

      transport.write({
        'type': 'user',
        'uuid': 'turn-queued',
        'message': {'role': 'user', 'content': 'SHOULD_NOT_RUN'},
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));

      Future<Map<String, Object?>> cancel(String reqId, String uuid) async {
        transport.write({
          'type': 'control_request',
          'request_id': reqId,
          'request': {'subtype': 'cancel_async_message', 'message_uuid': uuid},
        });
        while (!responses.containsKey(reqId)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return responses[reqId]!;
      }

      expect(await cancel('k1', 'turn-exec'), {'cancelled': false});
      expect(await cancel('k2', 'unknown-uuid'), {'cancelled': false});
      expect(await cancel('k3', 'turn-queued'), {'cancelled': true});
      expect(
        lifecycle.any(
          (e) => e['command_uuid'] == 'turn-queued' && e['state'] == 'cancelled',
        ),
        isTrue,
      );

      sigFile.writeAsStringSync('go');
      while (resultCount < 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      transport.write({
        'type': 'user',
        'uuid': 'turn-clear',
        'message': {'role': 'user', 'content': '/clear'},
      });
      while (resultCount < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(sessionStates.last, 'idle');
      expect(
        agyImgDir.listSync().whereType<Directory>(),
        isEmpty,
        reason: '/clear must remove per-session temp image directories',
      );
      expect(
        jsonEncode(fakeAgy.stdinCaptures()),
        isNot(contains('SHOULD_NOT_RUN')),
      );
    });

    test('temp image directory close() race across 35 iterations leaves zero leaked agy-img directories', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_img_race_');
      addTearDown(() => _deleteWithRetry(tmp));
      final prevDataDir = DataDirectory.current;
      DataDirectory.current = DataDirectory(p.join(tmp.path, 'app_data'));
      addTearDown(() => DataDirectory.current = prevDataDir);

      const pngBase64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

      for (var i = 0; i < 35; i++) {
        final transport = AntigravityTransport.forTesting(
          executable: 'agy',
          environment: {'HOME': tmp.path},
          launch: ClaudeLaunch(cwd: tmp.path, persist: false),
        );
        transport.write({
          'type': 'user',
          'uuid': 'race-$i',
          'message': {
            'role': 'user',
            'content': [
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': pngBase64,
                },
              },
              {'type': 'text', 'text': 'race $i'},
            ],
          },
        });
        if (i % 3 == 1) {
          await Future<void>.delayed(Duration.zero);
        } else if (i % 3 == 2) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        transport.close();
        await transport.exited;
      }

      final agyImgDir = Directory(
        p.join(DataDirectory.current.cacheDir, 'agy-img'),
      );
      final leaked = agyImgDir.existsSync()
          ? agyImgDir.listSync().whereType<Directory>().toList()
          : const <Directory>[];
      expect(
        leaked,
        isEmpty,
        reason: 'close() race during image writes must leak 0 agy-img dirs',
      );
    });

    test('WatchesEdits interrupt() mid-PreToolUse skips queued PostToolUse immediately without 12s stall and preserves hooks on next turn', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_hook_int_');
      addTearDown(() => _deleteWithRetry(tmp));
      final editedPath = p.join(tmp.path, 'src.dart');

      final fakeAgy = FakeCliExecutable.create(
        tmp,
        name: 'fake_agy_hook_int',
        dartBody: '''
Future<void> main(List<String> args) async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-hook-int'}));
    stdout.writeln(jsonEncode({
      'event': 'step_update',
      'step_update': {
        'step_index': 1,
        'step_type': 'tool',
        'state': 'DONE',
        'tool_info': {
          'name': 'edit_file',
          'parameters': {'Path': ${jsonEncode(jsonEncode(editedPath))}, 'Target': '"a"', 'Replacement': '"b"'},
          'output': 'ok',
        },
      },
    }));
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'conversation_id': 'conv-hook-int', 'status': 'SUCCESS', 'response': 'done'},
    }));
    await stdout.flush();
  }
}
''',
      );

      final transport = AntigravityTransport.forTesting(
        executable: fakeAgy.executablePath,
        environment: {'HOME': tmp.path},
        launch: ClaudeLaunch(cwd: tmp.path, persist: false),
      );
      addTearDown(() async {
        transport.close();
        await transport.exited;
      });

      final initDone = Completer<void>();
      final firstPreArrived = Completer<void>();
      var turnNumber = 1;
      var turn1Results = 0;
      var turn2Results = 0;
      final postInterruptTurn1Hooks = <String>[];
      final turn2Hooks = <String>[];
      var interruptedTurn1 = false;

      final sub = transport.messages.listen((m) {
        if (m['type'] == 'control_response' &&
            (m['response'] as Map)['request_id'] == 'init-1' &&
            !initDone.isCompleted) {
          initDone.complete();
        }
        if (m['type'] == 'control_request') {
          final req = m['request'] as Map;
          if (req['subtype'] == 'hook_callback') {
            final input = req['input'] as Map;
            final label = '${input['hook_event_name']}:${req['callback_id']}';
            if (turnNumber == 1) {
              if (!firstPreArrived.isCompleted) {
                firstPreArrived.complete();
              } else if (interruptedTurn1) {
                postInterruptTurn1Hooks.add(label);
              }
            } else {
              turn2Hooks.add(label);
              transport.write({
                'type': 'control_response',
                'response': {
                  'subtype': 'success',
                  'request_id': m['request_id'],
                  'response': const <String, Object?>{},
                },
              });
            }
          }
        }
        if (m['type'] == 'result') {
          if (turnNumber == 1) {
            turn1Results++;
          } else {
            turn2Results++;
          }
        }
      });
      addTearDown(sub.cancel);

      transport.write({
        'type': 'control_request',
        'request_id': 'init-1',
        'request': {
          'subtype': 'initialize',
          'hooks': {
            'PreToolUse': [
              {
                'matcher': 'Edit|Write|MultiEdit|NotebookEdit',
                'hookCallbackIds': ['cb-pre-1', 'cb-pre-2'],
              },
            ],
            'PostToolUse': [
              {
                'matcher': 'Edit|Write|MultiEdit|NotebookEdit',
                'hookCallbackIds': ['cb-post'],
              },
            ],
          },
        },
      });
      await initDone.future;

      final sw = Stopwatch()..start();
      transport.write({
        'type': 'user',
        'uuid': 'u1',
        'message': {'role': 'user', 'content': 'turn 1'},
      });
      await firstPreArrived.future.timeout(const Duration(seconds: 5));

      interruptedTurn1 = true;
      transport.write({
        'type': 'control_request',
        'request_id': 'int-1',
        'request': {'subtype': 'interrupt'},
      });

      while (turn1Results < 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(2000));
      expect(postInterruptTurn1Hooks, isEmpty);

      // Next turn after interrupt still fires all edit hooks normally.
      turnNumber = 2;
      transport.write({
        'type': 'user',
        'uuid': 'u2',
        'message': {'role': 'user', 'content': 'turn 2'},
      });
      while (turn2Results < 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(turn2Hooks, [
        'PreToolUse:cb-pre-1',
        'PreToolUse:cb-pre-2',
        'PostToolUse:cb-post',
      ]);
    });

    test('mcp_toggle handles synchronous and asynchronous ExtensionSwitches.save throws without crashing or dropping control_response', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_mcpsave_');
      addTearDown(() => _deleteWithRetry(tmp));
      final prevSave = ExtensionSwitches.save;
      addTearDown(() => ExtensionSwitches.save = prevSave);

      final transport = AntigravityTransport.forTesting(
        executable: 'agy',
        environment: {'HOME': tmp.path},
        launch: ClaudeLaunch(cwd: tmp.path, persist: false),
      );
      addTearDown(transport.close);

      final responses = <String, Map<String, Object?>>{};
      final sub = transport.messages.listen((m) {
        if (m['type'] == 'control_response') {
          final r = (m['response'] as Map).cast<String, Object?>();
          responses[r['request_id'] as String] = r;
        }
      });
      addTearDown(sub.cancel);

      ExtensionSwitches.save = (_) => throw StateError('sync save failure');
      transport.write({
        'type': 'control_request',
        'request_id': 'toggle-sync',
        'request': {
          'subtype': 'mcp_toggle',
          'serverName': 'ext-srv',
          'enabled': false,
        },
      });
      while (!responses.containsKey('toggle-sync')) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(responses['toggle-sync']!['subtype'], 'success');

      ExtensionSwitches.save = (_) async =>
          throw StateError('async save failure');
      transport.write({
        'type': 'control_request',
        'request_id': 'toggle-async',
        'request': {
          'subtype': 'mcp_toggle',
          'serverName': 'ext-srv',
          'enabled': true,
        },
      });
      while (!responses.containsKey('toggle-async')) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(responses['toggle-async']!['subtype'], 'success');
    });

    test('readBrainContextTokens and syncAntigravityTranscriptIfNeeded tolerate type-corrupt and truncated JSON lines', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_typecorrupt_');
      addTearDown(() => tmp.delete(recursive: true));
      final homeDir = Directory(p.join(tmp.path, 'home'))..createSync();
      final projDir = Directory(p.join(tmp.path, 'proj'))..createSync();
      const sid = '22222222-bbbb-4222-8222-333333333333';
      final transcriptFile = File(
        p.join(
          homeDir.path,
          '.gemini',
          'antigravity-cli',
          'brain',
          sid,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
      )..createSync(recursive: true);

      transcriptFile.writeAsStringSync(
        [
          jsonEncode({'type': 'USER_INPUT', 'content': 'first prompt'}),
          jsonEncode({
            'type': 'PLANNER_RESPONSE',
            'content': 'valid answer',
            'input_tokens': 1000,
            'output_tokens': 250,
            'cache_read_tokens': 100,
          }),
          jsonEncode({
            'type': 'PLANNER_RESPONSE',
            'content': 'bad types',
            'input_tokens': 'not-a-num',
            'output_tokens': true,
            'tool_calls': [
              {'name': 123, 'args': 'not-a-map'},
            ],
          }),
          jsonEncode({'type': 123, 'created_at': 456}),
          '{"type":"PLANNER_RESPONSE","input_tokens":',
        ].join('\n'),
      );

      final tokens = AntigravityTransport.readBrainContextTokens(
        sid,
        home: homeDir.path,
      );
      expect(tokens, isNotNull);
      expect(tokens!.inputTokens, 1000);
      expect(tokens.cacheReadTokens, 100);
      expect(tokens.outputTokens, 250);
      expect(tokens.contextTokens, 1350);

      final syncedPath = syncAntigravityTranscriptIfNeeded(
        cwd: projDir.path,
        sessionId: sid,
        paths: AgentPaths(
          home: homeDir.path,
          configDir: p.join(homeDir.path, '.ayte'),
        ),
      );
      expect(syncedPath, isNotNull);
      final syncedText = File(syncedPath!).readAsStringSync();
      expect(syncedText, contains('first prompt'));
      expect(syncedText, contains('valid answer'));
    });

    test('WatchesEdits fires symmetric Pre/Post hooks for implementation_plan.md in non-plan mode and skips both in plan mode', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_impl_hooks_');
      addTearDown(() => _deleteWithRetry(tmp));
      final implPlan = p.join(tmp.path, 'implementation_plan.md');
      final srcFile = p.join(tmp.path, 'src.dart');

      final fakeAgy = FakeCliExecutable.create(
        tmp,
        name: 'fake_agy_impl_hooks',
        dartBody: '''
Future<void> main(List<String> args) async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-impl'}));
    stdout.writeln(jsonEncode({
      'event': 'step_update',
      'step_update': {
        'step_index': 1,
        'step_type': 'tool',
        'state': 'DONE',
        'tool_info': {
          'name': 'write_file',
          'parameters': {'Path': ${jsonEncode(jsonEncode(implPlan))}, 'Content': '"# Plan"'},
          'output': 'ok',
        },
      },
    }));
    stdout.writeln(jsonEncode({
      'event': 'step_update',
      'step_update': {
        'step_index': 2,
        'step_type': 'tool',
        'state': 'ERROR',
        'tool_info': {
          'name': 'edit_file',
          'parameters': {'Path': ${jsonEncode(jsonEncode(implPlan))}, 'Target': '"a"', 'Replacement': '"b"'},
          'error': 'conflict',
        },
      },
    }));
    stdout.writeln(jsonEncode({
      'event': 'step_update',
      'step_update': {
        'step_index': 3,
        'step_type': 'tool',
        'state': 'DONE',
        'tool_info': {
          'name': 'edit_file',
          'parameters': {'Path': ${jsonEncode(jsonEncode(srcFile))}, 'Target': '"x"', 'Replacement': '"y"'},
          'output': 'ok',
        },
      },
    }));
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'conversation_id': 'conv-impl', 'status': 'SUCCESS', 'response': 'done'},
    }));
    await stdout.flush();
  }
}
''',
      );

      Future<List<String>> runHooksInMode(String permissionMode) async {
        final transport = AntigravityTransport.forTesting(
          executable: fakeAgy.executablePath,
          environment: {'HOME': tmp.path},
          launch: ClaudeLaunch(
            cwd: tmp.path,
            permissionMode: permissionMode,
            persist: false,
          ),
        );
        try {
          final events = <String>[];
          final initDone = Completer<void>();
          final turnDone = Completer<void>();
          final sub = transport.messages.listen((m) {
            if (m['type'] == 'control_response' &&
                (m['response'] as Map)['request_id'] == 'init-1' &&
                !initDone.isCompleted) {
              initDone.complete();
            }
            if (m['type'] == 'control_request') {
              final req = m['request'] as Map;
              if (req['subtype'] == 'hook_callback') {
                final input = req['input'] as Map;
                final toolInput = input['tool_input'] as Map;
                events.add(
                  '${input['hook_event_name']}:${p.basename(toolInput['file_path'] as String)}',
                );
                transport.write({
                  'type': 'control_response',
                  'response': {
                    'subtype': 'success',
                    'request_id': m['request_id'],
                    'response': const <String, Object?>{},
                  },
                });
              }
            }
            if (m['type'] == 'result') {
              events.add('result');
              if (!turnDone.isCompleted) turnDone.complete();
            }
          });
          transport.write({
            'type': 'control_request',
            'request_id': 'init-1',
            'request': {
              'subtype': 'initialize',
              'hooks': {
                'PreToolUse': [
                  {
                    'matcher': 'Edit|Write|MultiEdit|NotebookEdit',
                    'hookCallbackIds': ['cb-pre'],
                  },
                ],
                'PostToolUse': [
                  {
                    'matcher': 'Edit|Write|MultiEdit|NotebookEdit',
                    'hookCallbackIds': ['cb-post'],
                  },
                ],
                'PostToolUseFailure': [
                  {
                    'matcher': 'Edit|Write|MultiEdit|NotebookEdit',
                    'hookCallbackIds': ['cb-fail'],
                  },
                ],
              },
            },
          });
          await initDone.future;
          transport.write({
            'type': 'user',
            'uuid': 'u-$permissionMode',
            'message': {'role': 'user', 'content': 'go'},
          });
          await turnDone.future.timeout(const Duration(seconds: 5));
          await sub.cancel();
          return events;
        } finally {
          transport.close();
          await transport.exited;
        }
      }

      expect(await runHooksInMode('default'), [
        'PreToolUse:implementation_plan.md',
        'PostToolUse:implementation_plan.md',
        'PreToolUse:implementation_plan.md',
        'PostToolUseFailure:implementation_plan.md',
        'PreToolUse:src.dart',
        'PostToolUse:src.dart',
        'result',
      ]);

      expect(await runHooksInMode('plan'), [
        'PreToolUse:src.dart',
        'PostToolUse:src.dart',
        'result',
      ]);
    });

    test('set_permission_mode rejects invalid or unknown modes without mutating state', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_invalid_mode_');
      addTearDown(() => tmp.delete(recursive: true));

      final transport = AntigravityTransport.forTesting(
        executable: 'agy',
        environment: {'HOME': tmp.path},
        launch: ClaudeLaunch(cwd: tmp.path, persist: false),
      );
      addTearDown(transport.close);

      final responses = <String, Map<String, Object?>>{};
      final statuses = <Map<String, Object?>>[];
      final sub = transport.messages.listen((m) {
        if (m['type'] == 'control_response') {
          final r = (m['response'] as Map).cast<String, Object?>();
          responses[r['request_id'] as String] = r;
        }
        if (m['type'] == 'system' && m['subtype'] == 'status') {
          statuses.add(m);
        }
      });
      addTearDown(sub.cancel);

      Future<Map<String, Object?>> sendMode(String id, Object? mode) async {
        transport.write({
          'type': 'control_request',
          'request_id': id,
          'request': {'subtype': 'set_permission_mode', 'mode': mode},
        });
        while (!responses.containsKey(id)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return responses[id]!;
      }

      final ok = await sendMode('m-ok', 'acceptEdits');
      expect(ok['subtype'], 'success');
      expect((ok['response'] as Map)['mode'], 'acceptEdits');
      expect(statuses, hasLength(1));

      for (final (id, bad) in const [
        ('m-bad-1', 'totally_invalid_mode'),
        ('m-bad-2', '   '),
        ('m-bad-3', null),
      ]) {
        final err = await sendMode(id, bad);
        expect(err['subtype'], 'error');
        expect(err['error'], isA<String>());
      }

      expect(statuses, hasLength(1));
    });

    test('StartsPlans does not synthesize ExitPlanMode when RUNNING plan write fails with ERROR, while preserving RUNNING->DONE and prior valid plan writes', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_f4_plan_err_');
      addTearDown(() => _deleteWithRetry(tmp));
      final implPlan = p.join(tmp.path, 'implementation_plan.md');

      final fakeAgy = FakeCliExecutable.create(
        tmp,
        name: 'fake_agy_plan_err',
        dartBody: '''
Future<void> main(List<String> args) async {
  var turn = 0;
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    turn++;
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-plan-err'}));
    if (turn == 1) {
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 1,
          'step_type': 'tool',
          'state': 'RUNNING',
          'tool_info': {
            'name': 'write_file',
            'parameters': {'Path': ${jsonEncode(jsonEncode(implPlan))}, 'Content': '"# Failed Plan"'},
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 1,
          'step_type': 'tool',
          'state': 'ERROR',
          'tool_info': {
            'name': 'write_file',
            'parameters': {'Path': ${jsonEncode(jsonEncode(implPlan))}, 'Content': '"# Failed Plan"'},
            'error': 'disk full',
          },
        },
      }));
    } else if (turn == 2) {
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 2,
          'step_type': 'tool',
          'state': 'RUNNING',
          'tool_info': {
            'name': 'write_file',
            'parameters': {'Path': ${jsonEncode(jsonEncode(implPlan))}, 'Content': '"# Valid Plan"'},
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 2,
          'step_type': 'tool',
          'state': 'DONE',
          'tool_info': {
            'name': 'write_file',
            'parameters': {'Path': ${jsonEncode(jsonEncode(implPlan))}, 'Content': '"# Valid Plan"'},
            'output': 'Wrote plan',
          },
        },
      }));
    } else {
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 3,
          'step_type': 'tool',
          'state': 'RUNNING',
          'tool_info': {
            'name': 'write_file',
            'parameters': {'Path': ${jsonEncode(jsonEncode(implPlan))}, 'Content': '"# First Plan"'},
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 3,
          'step_type': 'tool',
          'state': 'DONE',
          'tool_info': {
            'name': 'write_file',
            'parameters': {'Path': ${jsonEncode(jsonEncode(implPlan))}, 'Content': '"# First Plan"'},
            'output': 'Wrote plan',
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 4,
          'step_type': 'tool',
          'state': 'RUNNING',
          'tool_info': {
            'name': 'edit_file',
            'parameters': {'Path': ${jsonEncode(jsonEncode(implPlan))}, 'Target': '"a"', 'Replacement': '"b"'},
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 4,
          'step_type': 'tool',
          'state': 'ERROR',
          'tool_info': {
            'name': 'edit_file',
            'parameters': {'Path': ${jsonEncode(jsonEncode(implPlan))}, 'Target': '"a"', 'Replacement': '"b"'},
            'error': 'conflict',
          },
        },
      }));
    }
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'conversation_id': 'conv-plan-err', 'status': 'SUCCESS', 'response': 'done'},
    }));
    await stdout.flush();
  }
}
''',
      );

      final transport = AntigravityTransport.forTesting(
        executable: fakeAgy.executablePath,
        environment: {'HOME': tmp.path},
        launch: ClaudeLaunch(
          cwd: tmp.path,
          permissionMode: 'plan',
          persist: false,
        ),
      );
      addTearDown(() async {
        transport.close();
        await transport.exited;
      });

      final turnToolUses = <List<Map<String, Object?>>>[];
      var currentToolUses = <Map<String, Object?>>[];
      Completer<void>? turnDone;
      final sub = transport.messages.listen((m) {
        if (m['type'] == 'assistant') {
          final msg = m['message'] as Map;
          final content = (msg['content'] as List).cast<Map>();
          for (final block in content) {
            if (block['type'] == 'tool_use') {
              currentToolUses.add(block.cast<String, Object?>());
            }
          }
        } else if (m['type'] == 'result') {
          turnToolUses.add(currentToolUses);
          currentToolUses = [];
          turnDone?.complete();
        }
      });
      addTearDown(sub.cancel);

      Future<List<Map<String, Object?>>> runTurn(String id, String text) async {
        turnDone = Completer<void>();
        transport.write({
          'type': 'user',
          'uuid': id,
          'message': {'role': 'user', 'content': text},
        });
        await turnDone!.future.timeout(const Duration(seconds: 5));
        return turnToolUses.last;
      }

      // Turn 1: RUNNING -> ERROR write_file to implementation_plan.md must NOT synthesize ExitPlanMode.
      final t1Tools = await runTurn('t1', 'fail plan write');
      expect(t1Tools.map((t) => t['name']).toList(), ['Write']);

      // Turn 2: RUNNING -> DONE write_file to implementation_plan.md MUST synthesize ExitPlanMode.
      final t2Tools = await runTurn('t2', 'succeed plan write');
      expect(t2Tools.map((t) => t['name']).toList(), ['Write', 'ExitPlanMode']);
      expect(t2Tools.last['input'], {
        'planFilePath': implPlan,
        'plan': '# Valid Plan',
      });

      // Turn 3: Step 3 DONE write_file followed by Step 4 RUNNING -> ERROR edit_file
      // must keep Step 3's valid plan and still synthesize ExitPlanMode with '# First Plan'.
      final t3Tools = await runTurn('t3', 'valid then failed edit');
      expect(t3Tools.map((t) => t['name']).toList(), [
        'Write',
        'Edit',
        'ExitPlanMode',
      ]);
      expect(t3Tools.last['input'], {
        'planFilePath': implPlan,
        'plan': '# First Plan',
      });
    });

    test('close() racing mid-setup or mid-Process.start() does not leak child processes or session artifacts', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_close_race_unit_');
      addTearDown(() => _deleteWithRetry(tmp));

      final pidLog = File(p.join(tmp.path, 'spawned_pids.log'));
      final fakeAgy = FakeCliExecutable.create(
        tmp,
        name: 'fake_agy_close_race_unit',
        dartBody: '''
Future<void> main(List<String> args) async {
  File(${jsonEncode(pidLog.path)}).writeAsStringSync('\$pid\\n', mode: FileMode.append, flush: true);
  await stdin.transform(utf8.decoder).drain<void>();
}
''',
      );

      for (final delayMs in const [0, 1, 3, 6, 12]) {
        final tr = AntigravityTransport.forTesting(
          executable: fakeAgy.executablePath,
          environment: {'HOME': tmp.path, 'USERPROFILE': tmp.path},
          launch: ClaudeLaunch(
            cwd: tmp.path,
            persist: false,
            instructions: 'Race test instructions',
          ),
        );
        tr.write({
          'type': 'user',
          'uuid': 'u-race-$delayMs',
          'message': {'role': 'user', 'content': 'hello'},
        });
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        tr.close();
        await tr.exited.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(tr.sdkBridgeForTesting, isNull);
        expect(tr.sessionConfigDirForTesting, isNull);
      }

      if (pidLog.existsSync()) {
        for (final line in pidLog.readAsLinesSync()) {
          final spawnedPid = int.tryParse(line.trim());
          if (spawnedPid == null) continue;
          if (Platform.isWindows) {
            final check = Process.runSync('tasklist', [
              '/FI',
              'PID eq $spawnedPid',
              '/NH',
            ]);
            expect(
              '${check.stdout}',
              isNot(contains('$spawnedPid')),
              reason: 'Child PID $spawnedPid must not remain alive after close()',
            );
          } else {
            final alive = Process.killPid(spawnedPid, ProcessSignal.sigcont);
            expect(alive, isFalse);
          }
        }
      }
    });

    test('LocalAntigravity resolves Windows Path/Home case-insensitively and prefers explicit PATH over fallback home dirs', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_cli_path_unit_');
      addTearDown(() => _deleteWithRetry(tmp));

      final explicitBin = Directory(p.join(tmp.path, 'explicit_bin'))
        ..createSync(recursive: true);
      final homeDir = Directory(p.join(tmp.path, 'home'))
        ..createSync(recursive: true);
      final geminiBin = Directory(p.join(homeDir.path, '.gemini', 'bin'))
        ..createSync(recursive: true);

      final explicitExe = File(p.join(explicitBin.path, 'agy.exe'))
        ..writeAsStringSync('');
      final homeExe = File(p.join(geminiBin.path, 'agy.exe'))
        ..writeAsStringSync('');
      final explicitPosixExe = File(p.join(explicitBin.path, 'agy'))
        ..writeAsStringSync('');
      final homePosixExe = File(p.join(geminiBin.path, 'agy'))
        ..writeAsStringSync('');

      final candidates = LocalAntigravity.candidatesForTesting({
        'Path': explicitBin.path,
        'UserProfile': homeDir.path,
      }, forceWindows: true);
      expect(candidates.first, p.windows.join(explicitBin.path, 'agy.exe'));
      expect(
        candidates,
        contains(p.windows.join(homeDir.path, '.gemini', 'bin', 'agy.exe')),
      );

      // Explicit empty Path must not fall back to host PATH.
      final homeOnlyCandidates = LocalAntigravity.candidatesForTesting({
        'Path': '',
        'Home': homeDir.path,
      }, forceWindows: true);
      expect(
        homeOnlyCandidates.first,
        p.windows.join(homeDir.path, '.gemini', 'bin', 'agy.exe'),
      );
      expect(
        LocalAntigravity.candidatesForTesting({
          'Path': '',
          'Home': '',
          'UserProfile': '',
        }, forceWindows: true),
        isEmpty,
      );

      if (Platform.isWindows) {
        expect(
          LocalAntigravity.findExecutableForTesting({
            'Path': explicitBin.path,
            'UserProfile': homeDir.path,
          }, forceWindows: true),
          explicitExe.path,
        );
        expect(
          LocalAntigravity.findExecutableForTesting({
            'Path': '',
            'Home': homeDir.path,
          }, forceWindows: true),
          homeExe.path,
        );
      } else {
        expect(
          LocalAntigravity.findExecutableForTesting({
            'PATH': explicitBin.path,
            'HOME': homeDir.path,
          }),
          explicitPosixExe.path,
        );
        expect(
          LocalAntigravity.findExecutableForTesting({
            'PATH': '',
            'HOME': homeDir.path,
          }),
          homePosixExe.path,
        );
      }
      expect(
        LocalAntigravity.findExecutableForTesting({
          'Path': '',
          'Home': '',
          'UserProfile': '',
        }, forceWindows: true),
        isNull,
      );
    });

    test(
      'close() and stopAll() kill Windows child/grandchild trees and defer exited until process and dir locks release',
      () async {
        final tmp = await Directory.systemTemp.createTemp('agy_tree_kill_unit_');
        addTearDown(() => _deleteWithRetry(tmp));

        final dartExe = resolveDartExecutable();
        final lockedCwd = Directory(p.join(tmp.path, 'locked_cwd'))
          ..createSync(recursive: true);
        final lockFilePath = p.join(lockedCwd.path, 'held.lock');
        final gcPidFile = File(p.join(tmp.path, 'gc.pid'));
        final sleeper = File(p.join(tmp.path, 'sleeper.dart'))
          ..writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final lockPath = args.first;
  final raf = File(lockPath).openSync(mode: FileMode.write);
  raf.writeStringSync('locked');
  File(${jsonEncode(gcPidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await Future<void>.delayed(const Duration(seconds: 30));
  raf.closeSync();
}
''');

        final parentSrc = File(p.join(tmp.path, 'fake_agy_tree.dart'))
          ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  final lockPath = Platform.environment['AGY_LOCK_FILE'] ?? '';
  await Process.start(${jsonEncode(dartExe)}, [${jsonEncode(sleeper.path)}, lockPath]);
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-tree-1'}));
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'conversation_id': 'conv-tree-1', 'status': 'SUCCESS', 'response': 'ok'},
    }));
    await stdout.flush();
  }
}
''');

        final String exePath;
        if (Platform.isWindows) {
          final compiled = p.join(tmp.path, 'fake_agy_tree.exe');
          final compileRes = Process.runSync(dartExe, [
            'compile',
            'exe',
            parentSrc.path,
            '-o',
            compiled,
          ]);
          expect(compileRes.exitCode, 0, reason: '${compileRes.stderr}');
          exePath = compiled;
        } else {
          final sh = File(p.join(tmp.path, 'fake_agy_tree.sh'))
            ..writeAsStringSync(
              '#!/bin/sh\nexec "$dartExe" "${parentSrc.path}" "\$@"\n',
            );
          Process.runSync('chmod', ['+x', sh.path]);
          exePath = sh.path;
        }

        addTearDown(() async {
          if (gcPidFile.existsSync()) {
            final pidVal = int.tryParse(gcPidFile.readAsStringSync().trim());
            if (pidVal != null) _killPidTree(pidVal);
          }
          await AntigravityTransport.stopAll();
        });

        final tr = AntigravityTransport.forTesting(
          executable: exePath,
          environment: {
            'HOME': tmp.path,
            'USERPROFILE': tmp.path,
            'AGY_LOCK_FILE': lockFilePath,
          },
          launch: ClaudeLaunch(cwd: lockedCwd.path, persist: false),
        );
        final done = Completer<void>();
        final sub = tr.messages.listen((m) {
          if (m['type'] == 'result' && !done.isCompleted) {
            done.complete();
          }
        });
        addTearDown(() => sub.cancel());

        tr.write({
          'type': 'user',
          'uuid': 'u-tree-1',
          'message': {'role': 'user', 'content': 'hi'},
        });
        await done.future.timeout(const Duration(seconds: 10));
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!gcPidFile.existsSync() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(gcPidFile.existsSync(), isTrue);
        final gcPid = int.parse(gcPidFile.readAsStringSync().trim());
        expect(_isPidAlive(gcPid), isTrue);

        tr.close();
        await tr.exited.timeout(const Duration(seconds: 5));
        expect(_isPidAlive(gcPid), isFalse);
        lockedCwd.deleteSync(recursive: true);
        expect(lockedCwd.existsSync(), isFalse);

        // Also verify stopAll() awaits an in-flight stopProcessForTesting() before returning.
        gcPidFile.deleteSync();
        final lockedCwd2 = Directory(p.join(tmp.path, 'locked_cwd_2'))
          ..createSync(recursive: true);
        final lockFilePath2 = p.join(lockedCwd2.path, 'held.lock');
        final tr2 = AntigravityTransport.forTesting(
          executable: exePath,
          environment: {
            'HOME': tmp.path,
            'USERPROFILE': tmp.path,
            'AGY_LOCK_FILE': lockFilePath2,
          },
          launch: ClaudeLaunch(cwd: lockedCwd2.path, persist: false),
        );
        final done2 = Completer<void>();
        final sub2 = tr2.messages.listen((m) {
          if (m['type'] == 'result' && !done2.isCompleted) {
            done2.complete();
          }
        });
        addTearDown(() => sub2.cancel());

        tr2.write({
          'type': 'user',
          'uuid': 'u-tree-2',
          'message': {'role': 'user', 'content': 'hi2'},
        });
        await done2.future.timeout(const Duration(seconds: 10));
        final deadline2 = DateTime.now().add(const Duration(seconds: 5));
        while (!gcPidFile.existsSync() && DateTime.now().isBefore(deadline2)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(gcPidFile.existsSync(), isTrue);
        final gcPid2 = int.parse(gcPidFile.readAsStringSync().trim());
        expect(_isPidAlive(gcPid2), isTrue);

        unawaited(tr2.stopProcessForTesting());
        await AntigravityTransport.stopAll();
        expect(_isPidAlive(gcPid2), isFalse);
      },
    );

    testWidgets(
      'close() and stopAll() on never-started AntigravityTransport complete inside FakeAsync without pending timers',
      (tester) async {
        final tr = AntigravityTransport.forTesting(
          executable: 'agy',
          launch: ClaudeLaunch(cwd: Directory.current.path, persist: false),
        );
        tr.close();
        await tr.exited;
        await AntigravityTransport.stopAll();
        await tester.pump();
      },
    );

    test(
      'plan mode preserves --dangerously-skip-permissions with autoModeDuringPlan, responds to useAutoModeDuringPlan toggles, and adds agy-img via --add-dir',
      () async {
        final tmp = await Directory.systemTemp.createTemp('agy_plan_bypass_');
        addTearDown(() => _deleteWithRetry(tmp));
        final prevDataDir = DataDirectory.current;
        DataDirectory.current = DataDirectory(p.join(tmp.path, 'app_data'));
        addTearDown(() => DataDirectory.current = prevDataDir);

        final fakeAgy = FakeCliExecutable.create(
          tmp,
          name: 'fake_agy_plan_bypass',
          dartBody: r'''
Future<void> main(List<String> args) async {
  recordEvent({'type': 'launch', 'args': args});
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-plan-bypass'}));
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'conversation_id': 'conv-plan-bypass', 'status': 'SUCCESS', 'response': 'ok'},
    }));
    await stdout.flush();
  }
}
''',
        );

        final transport = AntigravityTransport.forTesting(
          executable: fakeAgy.executablePath,
          environment: {'HOME': tmp.path},
          launch: ClaudeLaunch(
            cwd: tmp.path,
            permissionMode: 'bypassPermissions',
            autoModeDuringPlan: true,
            persist: false,
          ),
        );
        addTearDown(() async {
          transport.close();
          await transport.exited;
        });

        var results = 0;
        final sub = transport.messages.listen((m) {
          if (m['type'] == 'result') results++;
        });
        addTearDown(sub.cancel);

        // Switch into Plan mode before turn 1 (same order as ClaudeCodeKernel).
        transport.write({
          'type': 'control_request',
          'request_id': 'm1',
          'request': {'subtype': 'set_permission_mode', 'mode': 'plan'},
        });
        transport.write({
          'type': 'user',
          'uuid': 'u1',
          'message': {'role': 'user', 'content': 'plan with full access'},
        });
        while (results < 1) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        // Toggle useAutoModeDuringPlan -> false while still in plan mode.
        transport.write({
          'type': 'control_request',
          'request_id': 'f1',
          'request': {
            'subtype': 'apply_flag_settings',
            'settings': {'useAutoModeDuringPlan': false},
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 40));
        transport.write({
          'type': 'user',
          'uuid': 'u2',
          'message': {'role': 'user', 'content': 'plan without auto approve'},
        });
        while (results < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        // Toggle useAutoModeDuringPlan -> true while still in plan mode.
        transport.write({
          'type': 'control_request',
          'request_id': 'f2',
          'request': {
            'subtype': 'apply_flag_settings',
            'settings': {'useAutoModeDuringPlan': true},
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 40));
        transport.write({
          'type': 'user',
          'uuid': 'u3',
          'message': {'role': 'user', 'content': 'plan with auto approve again'},
        });
        while (results < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        final launches = fakeAgy
            .readCaptures()
            .where((e) => e['type'] == 'launch')
            .map((e) => (e['args'] as List).cast<String>())
            .toList();
        expect(launches, hasLength(3));

        final expectedImgRoot = p.join(DataDirectory.current.cacheDir, 'agy-img');
        expect(launches[0], contains('--mode=plan'));
        expect(launches[0], contains('--dangerously-skip-permissions'));
        expect(launches[0], contains('--add-dir=$expectedImgRoot'));

        expect(launches[1], contains('--mode=plan'));
        expect(launches[1], isNot(contains('--dangerously-skip-permissions')));
        expect(launches[1], contains('--add-dir=$expectedImgRoot'));

        expect(launches[2], contains('--mode=plan'));
        expect(launches[2], contains('--dangerously-skip-permissions'));
      },
    );

    test(
      'surfaces explicit notice when non-interactive permission denial aborts turn after prelude text, and stays quiet when model recovers',
      () async {
        final tmp = await Directory.systemTemp.createTemp('agy_perm_abort_');
        addTearDown(() => _deleteWithRetry(tmp));

        final fakeAgy = FakeCliExecutable.create(
          tmp,
          name: 'fake_agy_perm_abort',
          dartBody: r'''
Future<void> main(List<String> args) async {
  var turn = 0;
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    turn++;
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-perm'}));
    if (turn == 1) {
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 1,
          'step_type': 'agent_response',
          'state': 'DONE',
          'text_delta': 'I will inspect Swagger first.',
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 2,
          'step_type': 'tool',
          'state': 'ERROR',
          'tool_info': {
            'name': 'run_command',
            'parameters': {'CommandLine': '"curl http://example.com"'},
            'error': 'permission check failed for unsandboxed "curl http://example.com": user denied permission',
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'result',
        'result': {
          'conversation_id': 'conv-perm',
          'status': 'SUCCESS',
          'response': '',
        },
      }));
    } else {
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 3,
          'step_type': 'agent_response',
          'state': 'DONE',
          'text_delta': 'Checking file.',
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 4,
          'step_type': 'tool',
          'state': 'ERROR',
          'tool_info': {
            'name': 'read_file',
            'parameters': {'Path': '"/secret"'},
            'error': 'permission check failed for read_file "/secret": user denied permission',
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 5,
          'step_type': 'agent_response',
          'state': 'DONE',
          'text_delta': 'No problem, moving on without reading /secret.',
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'result',
        'result': {
          'conversation_id': 'conv-perm',
          'status': 'SUCCESS',
          'response': '',
        },
      }));
    }
    await stdout.flush();
  }
}
''',
        );

        final transport = AntigravityTransport.forTesting(
          executable: fakeAgy.executablePath,
          environment: {'HOME': tmp.path},
          launch: ClaudeLaunch(cwd: tmp.path, persist: false),
        );
        addTearDown(() async {
          transport.close();
          await transport.exited;
        });

        final emitted = <Map<String, Object?>>[];
        var results = 0;
        final sub = transport.messages.listen((m) {
          emitted.add(m);
          if (m['type'] == 'result') results++;
        });
        addTearDown(sub.cancel);

        transport.write({
          'type': 'user',
          'uuid': 't1',
          'message': {'role': 'user', 'content': 'turn 1'},
        });
        while (results < 1) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        final abortMsgs = emitted
            .where((m) => m['type'] == 'assistant' && '${m['uuid']}'.startsWith('agy-perm-abort-'))
            .toList();
        expect(abortMsgs, hasLength(1));
        final abortContent =
            (((abortMsgs.single['message'] as Map)['content'] as List).first as Map)['text']
                as String;
        expect(abortContent, contains('permission check failed'));

        transport.write({
          'type': 'user',
          'uuid': 't2',
          'message': {'role': 'user', 'content': 'turn 2'},
        });
        while (results < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        final abortMsgsAfterTurn2 = emitted
            .where((m) => m['type'] == 'assistant' && '${m['uuid']}'.startsWith('agy-perm-abort-'))
            .toList();
        expect(
          abortMsgsAfterTurn2,
          hasLength(1),
          reason: 'No abort notice when model already responded after tool denial',
        );
      },
    );

    test(
      'ClaudeCodeKernel with Full access + Plan mode launches agy with both --mode=plan and --dangerously-skip-permissions and no invalid Read() settings',
      () async {
        final tmp = await Directory.systemTemp.createTemp('agy_kernel_plan_');
        addTearDown(() => _deleteWithRetry(tmp));
        final prevDataDir = DataDirectory.current;
        DataDirectory.current = DataDirectory(p.join(tmp.path, 'app_data'));
        addTearDown(() => DataDirectory.current = prevDataDir);

        final fakeAgy = FakeCliExecutable.create(
          tmp,
          name: 'fake_agy_kernel_plan',
          dartBody: r'''
Future<void> main(List<String> args) async {
  recordEvent({'type': 'launch', 'args': args});
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-kp'}));
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'conversation_id': 'conv-kp', 'status': 'SUCCESS', 'response': 'planned'},
    }));
    await stdout.flush();
  }
}
''',
        );

        final kernel = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(cwd: tmp.path),
          start: (launch) async => AntigravityTransport.forTesting(
            executable: fakeAgy.executablePath,
            environment: {'HOME': tmp.path},
            launch: launch,
          ),
        );
        addTearDown(kernel.dispose);

        var turnsEnded = 0;
        final sub = kernel.events.listen((e) {
          if (e is TurnEnded) turnsEnded++;
        });
        addTearDown(sub.cancel);

        kernel.permission.select('bypassPermissions');
        kernel.mode.select('plan');
        kernel.send(const KernelTurn(id: 'kp1', text: 'design the plan'));
        while (turnsEnded < 1) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        final launches = fakeAgy
            .readCaptures()
            .where((e) => e['type'] == 'launch')
            .map((e) => (e['args'] as List).cast<String>())
            .toList();
        expect(launches, hasLength(1));
        final args = launches.single;
        expect(args, contains('--mode=plan'));
        expect(args, contains('--dangerously-skip-permissions'));
        expect(
          args.where((a) => a.startsWith('--settings=') && a.contains('Read(')),
          isEmpty,
        );
        expect(
          args,
          contains('--add-dir=${p.join(DataDirectory.current.cacheDir, 'agy-img')}'),
        );
      },
    );

    test(
      'high-cache turns do not emit false compact_boundary and real compaction preserves cache_read_tokens in post_tokens',
      () async {
        final tmp = await Directory.systemTemp.createTemp('agy_ctx_cache_');
        addTearDown(() => _deleteWithRetry(tmp));

        final brainFile = File(
          p.join(
            tmp.path,
            '.gemini',
            'antigravity-cli',
            'brain',
            'conv-ctx',
            '.system_generated',
            'logs',
            'transcript.jsonl',
          ),
        );

        final fakeAgy = FakeCliExecutable.create(
          tmp,
          name: 'fake_agy_ctx_cache',
          dartBody: '''
Future<void> main(List<String> args) async {
  var turn = 0;
  final brain = File(${jsonEncode(brainFile.path)});
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    turn++;
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-ctx'}));
    brain.parent.createSync(recursive: true);
    if (turn == 1) {
      // High-cache normal turn: input_tokens (13829) < cache_read_tokens (492125).
      brain.writeAsStringSync(
        "\${jsonEncode({'type': 'PLANNER_RESPONSE', 'input_tokens': 13829, 'cache_read_tokens': 492125, 'output_tokens': 202})}\\n",
      );
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 1,
          'step_type': 'agent_response',
          'state': 'DONE',
          'text_delta': 'turn 1 answer',
          'usage': {
            'input_tokens': 13829,
            'cache_read_tokens': 492125,
            'output_tokens': 202,
          },
        },
      }));
    } else if (turn == 2) {
      // Another high-cache normal turn that grows slightly; must NOT false-compact.
      brain.writeAsStringSync(
        "\${jsonEncode({'type': 'PLANNER_RESPONSE', 'input_tokens': 4100, 'cache_read_tokens': 505955, 'output_tokens': 400})}\\n",
        mode: FileMode.append,
      );
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 2,
          'step_type': 'agent_response',
          'state': 'DONE',
          'text_delta': 'turn 2 answer',
          'usage': {
            'input_tokens': 4100,
            'cache_read_tokens': 505955,
            'output_tokens': 400,
          },
        },
      }));
    } else {
      // Real auto-compaction: drops from ~510K down to 36403 (2975 + 30911 + 2517).
      brain.writeAsStringSync(
        "\${jsonEncode({'type': 'PLANNER_RESPONSE', 'input_tokens': 2975, 'cache_read_tokens': 30911, 'output_tokens': 2517})}\\n",
        mode: FileMode.append,
      );
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 3,
          'step_type': 'agent_response',
          'state': 'DONE',
          'text_delta': 'turn 3 post-compact answer',
          'usage': {
            'input_tokens': 2975,
            'cache_read_tokens': 30911,
            'output_tokens': 2517,
          },
        },
      }));
    }
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'conversation_id': 'conv-ctx', 'status': 'SUCCESS', 'response': 'ok'},
    }));
    await stdout.flush();
  }
}
''',
        );

        final transport = AntigravityTransport.forTesting(
          executable: fakeAgy.executablePath,
          environment: {'HOME': tmp.path},
          launch: ClaudeLaunch(cwd: tmp.path, persist: false),
        );
        addTearDown(() async {
          transport.close();
          await transport.exited;
        });

        final compacts = <Map<String, Object?>>[];
        final responses = <String, Map<String, Object?>>{};
        var idleCount = 0;
        final sub = transport.messages.listen((m) {
          if (m['type'] == 'system' && m['subtype'] == 'compact_boundary') {
            compacts.add(m);
          } else if (m['type'] == 'system' &&
              m['subtype'] == 'session_state_changed' &&
              m['state'] == 'idle') {
            idleCount++;
          } else if (m['type'] == 'control_response') {
            final r = (m['response'] as Map).cast<String, Object?>();
            responses[r['request_id'] as String] =
                (r['response'] as Map).cast<String, Object?>();
          }
        });
        addTearDown(sub.cancel);

        Future<Map<String, Object?>> queryContext(String reqId) async {
          transport.write({
            'type': 'control_request',
            'request_id': reqId,
            'request': {'subtype': 'get_context_usage'},
          });
          while (!responses.containsKey(reqId)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          return responses[reqId]!;
        }

        // Turn 1: 13829 + 492125 + 202 = 506156, no compaction.
        transport.write({
          'type': 'user',
          'uuid': 'u1',
          'message': {'role': 'user', 'content': 'turn 1'},
        });
        while (idleCount < 1) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(compacts, isEmpty);
        expect((await queryContext('c1'))['totalTokens'], 506156);

        // Turn 2: 4100 + 505955 + 400 = 510455, still NO false compaction.
        transport.write({
          'type': 'user',
          'uuid': 'u2',
          'message': {'role': 'user', 'content': 'turn 2'},
        });
        while (idleCount < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(compacts, isEmpty);
        expect((await queryContext('c2'))['totalTokens'], 510455);

        // Turn 3: Real compaction drops to 2975 + 30911 + 2517 = 36403 (NOT 5492).
        transport.write({
          'type': 'user',
          'uuid': 'u3',
          'message': {'role': 'user', 'content': 'turn 3'},
        });
        while (idleCount < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(compacts, hasLength(1));
        final meta = compacts.single['compact_metadata'] as Map;
        expect(meta['trigger'], 'auto');
        expect(meta['pre_tokens'], 510455);
        expect(meta['post_tokens'], 36403);
        expect((await queryContext('c3'))['totalTokens'], 36403);
      },
    );
  });
}

bool _isPidAlive(int pid) {
  if (Platform.isWindows) {
    final res = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return RegExp('(?:^|\\s)$pid(?:\\s|\$)', multiLine: true)
        .hasMatch('${res.stdout}');
  }
  return Process.killPid(pid, ProcessSignal.sigcont);
}

void _killPidTree(int pid) {
  if (Platform.isWindows) {
    Process.runSync('taskkill', ['/PID', '$pid', '/T', '/F']);
  } else {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
}

class _RealHttpOverrides extends HttpOverrides {
  HttpClient newRealClient() => super.createHttpClient(null);
}

Future<void> _deleteWithRetry(Directory dir) async {
  for (var i = 0; i < 10; i++) {
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
