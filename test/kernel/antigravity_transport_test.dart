import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_cli.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/models/model_providers.dart';

void main() {
  group('AntigravityModels deduplication & context windows', () {
    test(
      'updateFromJson collapses 22 raw agy model variants into 9 clean families',
      () {
        const rawJson = {
          'command': {
            'data': {
              'models': [
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
          'gemini-4-carbon',
          'gemini-4-argon',
          'gemini-4-hydrogen',
          'gemini-pro-orchestrator',
          'gemini-pro-orchestrator-argon',
          'gemini-3.8-flash',
          'claude-opus-5-5',
          'claude-sonnet-5-5',
          'gpt-oss-120b',
        ]);

        expect(families.map((m) => m.label).toList(), [
          'Gemini 4 Carbon',
          'Gemini 4 Argon',
          'Gemini 4 Hydrogen',
          'Orchestrator (Carbon)',
          'Orchestrator (Argon)',
          'Gemini 3.8 Flash',
          'Claude Opus 5.5',
          'Claude Sonnet 5.5',
          'GPT-OSS 120B',
        ]);

        final hydrogen = AntigravityModels.of('gemini-4-hydrogen')!;
        expect(hydrogen.effortLevels, ['low', 'medium', 'high', 'xhigh']);
        expect(hydrogen.contextOptions, [200000, 400000, 1000000]);
        expect(hydrogen.defaultContext, 1000000);
        expect(hydrogen.effectiveCliModel, 'gemini-4-hydrogen');

        final orchestrator = AntigravityModels.of('gemini-pro-orchestrator')!;
        expect(orchestrator.effortLevels, isEmpty);
        expect(orchestrator.contextOptions, [200000, 400000, 1000000]);

        final claudeOpus = AntigravityModels.of('claude-opus-5-5')!;
        expect(claudeOpus.effortLevels, ['low', 'medium', 'high']);
        expect(claudeOpus.contextOptions, [200000, 400000, 1000000]);
        expect(claudeOpus.defaultContext, 200000);

        final gptOss = AntigravityModels.of('gpt-oss-120b')!;
        expect(gptOss.effortLevels, isEmpty);
        expect(gptOss.effectiveCliModel, 'gpt-oss-120b-medium');
        expect(gptOss.contextOptions, [64000, 128000]);
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
      'ClaudeCodeKernel exposes context window and effort submenus per Antigravity model',
      () {
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
            },
          ),
          providers: providers,
          start: (_) async => throw UnimplementedError(),
        );
        addTearDown(kernel.dispose);

        // Legacy variant ID normalized to canonical family ref + preserved effort.
        expect(kernel.model.selected, '@antigravity-cli/gemini-4-carbon');
        expect(kernel.effort.selected, 'medium');
        expect(kernel.contextSize.selected, '1000000');

        final carbonContexts = kernel.contextSize
            .optionsFor('@antigravity-cli/gemini-4-carbon')
            .map((o) => o.label)
            .toList();
        expect(carbonContexts, ['200K', '400K', '1M']);

        final gptContexts = kernel.contextSize
            .optionsFor('@antigravity-cli/gpt-oss-120b')
            .map((o) => o.label)
            .toList();
        expect(gptContexts, ['64K', '128K']);
        expect(
          kernel.effort.optionsFor('@antigravity-cli/gpt-oss-120b'),
          isEmpty,
        );

        final hydrogenEfforts = kernel.effort
            .optionsFor('@antigravity-cli/gemini-4-hydrogen')
            .map((o) => o.id)
            .toList();
        expect(hydrogenEfforts, ['low', 'medium', 'high', 'xhigh']);

        // Switching context window updates selected context immediately.
        kernel.contextSize.select(
          '@antigravity-cli/gemini-4-carbon',
          '400000',
        );
        expect(kernel.contextSize.selected, '400000');
      },
    );
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
}
