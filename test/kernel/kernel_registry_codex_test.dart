import 'dart:io';

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_catalog.dart';
import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('KernelRegistry.codex wiring', () {
    test('wires CodexCatalog while preserving AntigravityCatalog', () {
      expect(KernelRegistry.codex.catalog, isA<CodexCatalog>());
      expect(KernelRegistry.antigravity.catalog, isA<AntigravityCatalog>());
    });

    test('forwards KernelContext (cwd & settings) into CodexKernel', () {
      final ctx = KernelContext(
        cwd: Directory.current.path,
        settings: const {'model': 'gpt-5.4', 'effort': 'high'},
      );
      final kernel = KernelRegistry.codex.create(ctx);
      addTearDown(kernel.dispose);

      expect(kernel, isA<CodexKernel>());
      final codexKernel = kernel as CodexKernel;
      expect(codexKernel.context.cwd, ctx.cwd);
      expect(codexKernel.context.settings['model'], 'gpt-5.4');
      expect(codexKernel.context.settings['effort'], 'high');
    });

    test('CodexCatalog discovers local Codex session rollout files', () async {
      final tmp = await Directory.systemTemp.createTemp('ayte-cdx-cat-');
      addTearDown(() => tmp.delete(recursive: true));

      final repoDir = Directory(p.join(tmp.path, 'repo'))..createSync();
      final codexHome = Directory(p.join(tmp.path, 'codex-home'))..createSync();
      final sessionsDir = Directory(
        p.join(codexHome.path, 'sessions', '2026', '11', '22'),
      )..createSync(recursive: true);

      final rollout = File(
        p.join(
          sessionsDir.path,
          'rollout-2026-11-22T10-00-00-01900000-0000-7000-8000-000000000001.jsonl',
        ),
      );
      rollout.writeAsStringSync(
        '{"timestamp":"2026-11-22T10:00:00Z","type":"session_meta","payload":{"id":"01900000-0000-7000-8000-000000000001","cwd":${Uri.file(repoDir.path).toString().isNotEmpty ? '"${repoDir.path.replaceAll(r'\', r'\\')}"' : '""'}}}\n'
        '{"timestamp":"2026-11-22T10:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"Inspect repo"}}\n',
      );

      final catalog = CodexCatalog(codexHome: codexHome.path);
      final sessions = await catalog.sessionsIn(repoDir.path);
      expect(sessions, hasLength(1));
      expect(sessions.single.id, '01900000-0000-7000-8000-000000000001');
    });
  });
}
