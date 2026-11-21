import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:baocode/chat/panels/context_usage_panel.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_cli.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/models/model_providers.dart';

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

    test('convertAgyUsage separates uncached input from cache_read_tokens', () {
      final converted = AntigravityTransport.convertAgyUsage(const {
        'input_tokens': 148793,
        'output_tokens': 2811,
        'thinking_tokens': 412,
        'cache_read_tokens': 144783,
        'total_tokens': 151604,
      });
      expect(converted, isNotNull);
      expect(converted!.contextTokens, 151604);
      expect(converted.usage['input_tokens'], 4010);
      expect(converted.usage['cache_read_input_tokens'], 144783);
      expect(converted.usage['output_tokens'], 2811);
    });

    test('buildContextCategories maps cleanly to ContextUsagePanel parts', () {
      final cats = AntigravityTransport.buildContextCategories(151604, 512000);
      expect(cats.length, 4);
      expect(ContextUsagePanel.partOf('${cats[0]['name']}'), 'system');
      expect(ContextUsagePanel.partOf('${cats[1]['name']}'), 'tools');
      expect(ContextUsagePanel.partOf('${cats[2]['name']}'), 'messages');
      final usedSum =
          (cats[0]['tokens'] as int) +
          (cats[1]['tokens'] as int) +
          (cats[2]['tokens'] as int);
      expect(usedSum, 151604);
      expect(cats[3]['tokens'], 512000 - 151604);
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
}
