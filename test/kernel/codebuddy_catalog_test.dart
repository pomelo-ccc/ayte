import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart' show AgentPaths;
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_catalog.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_storage_io.dart';
import 'package:baocode/kernel/claude_code/mock_claude_code_transport.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_catalog.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_cli.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/remote/remote_claude.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String homeDir;
  late String claudeConfigDir;
  late String projectDir;

  void writeFile(String path, String content) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  String nativeSessionPath(String id, {String? cwd}) {
    final dirName = CodeBuddyCatalog.encodeProjectDirName(cwd ?? projectDir);
    return p.join(homeDir, '.codebuddy', 'projects', dirName, '$id.jsonl');
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('codebuddy_catalog_test_');
    homeDir = p.join(temp.path, 'home');
    claudeConfigDir = p.join(homeDir, '.ayte');
    projectDir = p.join(temp.path, 'angular21');
    Directory(homeDir).createSync(recursive: true);
    Directory(claudeConfigDir).createSync(recursive: true);
    Directory(projectDir).createSync(recursive: true);
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  CodeBuddyCatalog makeCatalog() => CodeBuddyCatalog(
    claude: ClaudeCatalog(
      local: ClaudeStorage(
        configDir: claudeConfigDir,
        cacheFile: p.join(temp.path, 'cache.json'),
      ),
    ),
    homeDir: homeDir,
    paths: AgentPaths(home: homeDir, configDir: claudeConfigDir),
  );

  group('CodeBuddyCatalog session discovery & persistence', () {
    test('discovers native ~/.codebuddy/projects sessions and preserves custom title', () async {
      final s1 = '01a215ae-c8b6-7bf1-ad62-9fb94b0b2d27';
      final s2 = '01a1f6e5-02cd-7efb-ae0c-92f521c99a31';

      writeFile(
        nativeSessionPath(s1),
        [
          jsonEncode({
            'id': 'u1',
            'timestamp': 1795660105960,
            'type': 'message',
            'role': 'user',
            'content': [
              {
                'type': 'input_text',
                'text':
                    '<system-reminder>Reply suggestions are on: test</system-reminder>',
              },
              {'type': 'input_text', 'text': '帮我排查登录问题'},
            ],
            '__codebuddyLocal': {'sensitiveUserInputReviewed': true},
            'sessionId': s1,
            'cwd': projectDir,
          }),
          jsonEncode({
            'id': 'a1',
            'timestamp': 1795660110000,
            'type': 'message',
            'role': 'assistant',
            'providerData': {'model': 'deepseek-v4.1-flash'},
            'content': [
              {'type': 'output_text', 'text': '好的，我来排查。'},
            ],
            'sessionId': s1,
            'cwd': projectDir,
          }),
        ].join('\n'),
      );

      writeFile(
        nativeSessionPath(s2),
        [
          jsonEncode({
            'id': 'u2',
            'timestamp': 1795143566083,
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': '启动'},
            ],
            'sessionId': s2,
            'cwd': projectDir,
          }),
          jsonEncode({
            'type': 'custom-title',
            'customTitle': '启动本地 PLM 服务',
            'sessionId': s2,
          }),
        ].join('\n'),
      );

      // Unrelated Claude Code session in ~/.ayte/projects must NOT be claimed.
      final claudeDir = p.join(
        claudeConfigDir,
        'projects',
        '-${CodeBuddyCatalog.encodeProjectDirName(projectDir)}',
      );
      writeFile(
        p.join(claudeDir, 'claude-only-1.jsonl'),
        [
          jsonEncode({
            'type': 'user',
            'uuid': 'cl-u1',
            'cwd': projectDir,
            'message': {'role': 'user', 'content': 'Claude prompt'},
          }),
          jsonEncode({
            'type': 'assistant',
            'uuid': 'cl-a1',
            'cwd': projectDir,
            'message': {
              'role': 'assistant',
              'model': 'claude-sonnet-4-6',
              'content': [
                {'type': 'text', 'text': 'hi'},
              ],
            },
          }),
        ].join('\n'),
      );

      final catalog = makeCatalog();
      final projects = await catalog.projects();
      expect(projects, hasLength(1));
      expect(projects.single.path, p.normalize(projectDir));

      final byId = {for (final s in projects.single.sessions) s.id: s};
      expect(byId.keys, unorderedEquals([s1, s2]));
      expect(byId[s1]!.title, '帮我排查登录问题');
      expect(byId[s1]!.path, nativeSessionPath(s1));
      expect(byId[s2]!.title, '启动本地 PLM 服务');

      // sessionsIn returns matching project's sessions.
      final listed = await catalog.sessionsIn(projectDir);
      expect(listed.map((s) => s.id), unorderedEquals([s1, s2]));

      // inferJsonlKernelId recognizes native CodeBuddy transcripts.
      expect(
        AntigravityCatalog.inferJsonlKernelId(nativeSessionPath(s1)),
        codebuddyBuiltinProviderId,
      );
    });

    test('translates native CodeBuddy JSONL messages, reasoning, tools, and paging', () async {
      final sid = '01a215ae-0000-7000-8000-000000000001';
      final path = nativeSessionPath(sid);
      writeFile(
        path,
        [
          jsonEncode({
            'id': 'u1',
            'timestamp': 1795660100000,
            'type': 'message',
            'role': 'user',
            'content': [
              {
                'type': 'input_text',
                'text': '<system-reminder>hidden</system-reminder>',
              },
              {'type': 'input_text', 'text': '第一轮问题'},
            ],
            'sessionId': sid,
            'cwd': projectDir,
          }),
          jsonEncode({
            'id': 'r1',
            'timestamp': 1795660101000,
            'type': 'reasoning',
            'providerData': {
              'messageId': 'm1',
              'model': 'deepseek-v4.1-flash',
            },
            'rawContent': [
              {'type': 'reasoning_text', 'text': '先检查目录结构'},
            ],
          }),
          jsonEncode({
            'id': 'fc1',
            'timestamp': 1795660102000,
            'type': 'function_call',
            'providerData': {
              'messageId': 'm1',
              'model': 'deepseek-v4.1-flash',
            },
            'callId': 'call_1',
            'name': 'Bash',
            'arguments': '{"command":"ls"}',
          }),
          jsonEncode({
            'id': 'fr1',
            'timestamp': 1795660103000,
            'type': 'function_call_result',
            'name': 'Bash',
            'callId': 'call_1',
            'status': 'completed',
            'output': {'type': 'text', 'text': 'README.md'},
          }),
          jsonEncode({
            'id': 'a1',
            'timestamp': 1795660104000,
            'type': 'message',
            'role': 'assistant',
            'providerData': {
              'messageId': 'm2',
              'model': 'deepseek-v4.1-flash',
            },
            'content': [
              {'type': 'output_text', 'text': '第一轮回答'},
            ],
          }),
          jsonEncode({
            'id': 'u2',
            'timestamp': 1795660200000,
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': '第二轮问题'},
            ],
          }),
          jsonEncode({
            'id': 'a2',
            'timestamp': 1795660205000,
            'type': 'message',
            'role': 'assistant',
            'providerData': {
              'messageId': 'm3',
              'model': 'deepseek-v4.1-flash',
            },
            'content': [
              {'type': 'output_text', 'text': '第二轮回答'},
            ],
          }),
        ].join('\n'),
      );

      final record = SessionRecord(
        id: sid,
        title: '第一轮问题',
        updatedAt: DateTime(2026, 11, 26),
        cwd: projectDir,
        path: path,
      );
      expect(CodeBuddyCatalog.isNativeCodeBuddyJsonl(path), isTrue);

      final all = await ClaudeStorage.read(record);
      expect(all, hasLength(7));
      expect(all[0]['type'], 'user');
      expect((all[0]['message'] as Map)['content'], '第一轮问题');

      expect(all[1]['type'], 'assistant');
      expect(
        ((all[1]['message'] as Map)['content'] as List).single,
        {'type': 'thinking', 'thinking': '先检查目录结构'},
      );
      expect((all[1]['message'] as Map)['model'], 'deepseek-v4.1-flash');

      expect(all[2]['type'], 'assistant');
      expect(
        ((all[2]['message'] as Map)['content'] as List).single,
        {
          'type': 'tool_use',
          'id': 'call_1',
          'name': 'Bash',
          'input': {'command': 'ls'},
        },
      );

      expect(all[3]['type'], 'user');
      expect(
        ((all[3]['message'] as Map)['content'] as List).single,
        {
          'type': 'tool_result',
          'tool_use_id': 'call_1',
          'content': 'README.md',
        },
      );

      expect(all[4]['type'], 'assistant');
      expect(
        ((all[4]['message'] as Map)['content'] as List).single,
        {'type': 'text', 'text': '第一轮回答'},
      );

      // Paging fetches the latest turn first, then earlier turn via `before`.
      final page1 = await ClaudeStorage.readPage(record, turns: 1);
      expect(page1.entries.map((e) => e['uuid']), ['u2', 'a2']);
      expect(page1.earlier, 'u2');

      final page2 = await ClaudeStorage.readPage(
        record,
        turns: 1,
        before: page1.earlier,
      );
      expect(page2.entries.map((e) => e['uuid']), ['u1', 'r1', 'fc1', 'fr1', 'a1']);
      expect(page2.earlier, isNull);
    });

    test('survives Workspace reopen and cleans up on delete', () async {
      final sid = '01a215ae-0000-7000-8000-000000000099';
      final path = nativeSessionPath(sid);
      writeFile(
        path,
        [
          jsonEncode({
            'id': 'u1',
            'timestamp': 1795660300000,
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': '重启后不能消失的 CodeBuddy 会话'},
            ],
            'sessionId': sid,
            'cwd': projectDir,
          }),
        ].join('\n'),
      );
      final siblingDir = Directory(p.join(p.dirname(path), sid))
        ..createSync(recursive: true);

      final catalog = makeCatalog();
      final emptyClaudeCatalog = ClaudeCatalog(
        local: ClaudeStorage(
          configDir: claudeConfigDir,
          cacheFile: p.join(temp.path, 'cache2.json'),
        ),
      );
      late final KernelDescriptor cbKernel;
      cbKernel = KernelDescriptor(
        id: codebuddyBuiltinProviderId,
        label: 'CodeBuddy',
        icon: Icons.auto_awesome_rounded,
        description: 'CodeBuddy',
        catalog: catalog,
        create: (context) => ClaudeCodeKernel(
          cbKernel,
          context,
          start: MockClaudeCodeTransport.start,
          readHistory: ClaudeStorage.read,
          readHistoryPage: ClaudeStorage.readPage,
        ),
      );
      late final KernelDescriptor claudeKernel;
      claudeKernel = KernelDescriptor(
        id: claudeCodeKernelId,
        label: 'Claude Code',
        icon: Icons.terminal_rounded,
        description: 'Claude Code',
        catalog: emptyClaudeCatalog,
        create: (context) => ClaudeCodeKernel(
          claudeKernel,
          context,
          start: MockClaudeCodeTransport.start,
        ),
      );

      final workspace = Workspace(
        kernels: [cbKernel, claudeKernel],
        preferences: MemoryPreferenceStore(),
      );
      addTearDown(workspace.dispose);
      await workspace.load();

      final restored = workspace.threads
          .where((t) => t.record?.id == sid)
          .firstOrNull;
      expect(restored, isNotNull);
      expect(restored!.kernel.id, codebuddyBuiltinProviderId);
      expect(restored.title, '重启后不能消失的 CodeBuddy 会话');

      await catalog.delete(sid);
      expect(File(path).existsSync(), isFalse);
      expect(siblingDir.existsSync(), isFalse);
    });
  });
}
