import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

void main() {
  test(
    'resuming a session without an explicit session model restores the latest '
    'assistant model from transcript history instead of global fallback',
    () async {
      final prevCore = ClaudeCore.current;
      ClaudeCore.current = () => ClaudeCore.antigravity;
      addTearDown(() => ClaudeCore.current = prevCore);

      final session = SessionRecord(
        id: 'sess-hydrogen-1',
        title: 'Test Hydrogen Session',
        updatedAt: DateTime(2026, 11, 18),
        cwd: '/tmp/proj',
      );

      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        KernelContext(
          cwd: '/tmp/proj',
          resume: session,
          settings: const {
            'model': '@antigravity-cli/gemini-4-carbon',
            'effort@@antigravity-cli/gemini-4-hydrogen': 'xhigh',
            'context@@antigravity-cli/gemini-4-hydrogen': '512000',
          },
        ),
        start: (_) async => FakeCli(),
        providers: ModelProviders.memory(providers: const []),
        readHistory: (_) async => const [
          {
            'type': 'assistant',
            'uuid': 'agy-import-sess-hydrogen-1-a-1',
            'message': {
              'role': 'assistant',
              'model': 'gemini-3.8-flash-high',
              'content': [
                {'type': 'text', 'text': 'imported'},
              ],
            },
          },
          {
            'type': 'assistant',
            'uuid': 'agy-asst-1-1',
            'message': {
              'role': 'assistant',
              'model': 'gemini-4-hydrogen',
              'content': [
                {'type': 'text', 'text': 'actual turn'},
              ],
            },
          },
        ],
      );
      addTearDown(kernel.dispose);

      await pumpEventQueue();
      expect(kernel.loadingHistory, isFalse);
      expect(kernel.model.selected, '@antigravity-cli/gemini-4-hydrogen');
      expect(kernel.effort.selected, 'xhigh');
      expect(kernel.contextSize.selected, isNull);
      expect(kernel.contextWindow, 256000);
    },
  );
}
