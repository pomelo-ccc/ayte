import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_agent/bao_agent.dart' show AgentPaths;
import 'package:baocode/kernel/antigravity/antigravity_catalog.dart';
import 'package:baocode/kernel/claude_code/claude_storage_io.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_catalog.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/remote/remote_claude.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String home;
  late String ayteConfig;
  late String cacheFile;
  late String agyRoot;
  late String projectDir;
  late DataDirectory previousDataDir;

  void writeFile(String path, String content) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('agy_catalog_test_');
    home = p.join(temp.path, 'home');
    ayteConfig = p.join(home, '.ayte');
    cacheFile = p.join(temp.path, 'cache', 'claude-sessions.json');
    agyRoot = p.join(home, '.gemini', 'antigravity-cli');
    projectDir = p.join(temp.path, 'my-project');
    Directory(home).createSync(recursive: true);
    Directory(ayteConfig).createSync(recursive: true);
    Directory(agyRoot).createSync(recursive: true);
    Directory(projectDir).createSync(recursive: true);
    previousDataDir = DataDirectory.current;
    DataDirectory.current = DataDirectory(p.join(temp.path, 'app-data'));
  });

  tearDown(() {
    DataDirectory.current = previousDataDir;
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  AntigravityCatalog createCatalog() => AntigravityCatalog(
    claude: ClaudeCatalog(
      local: ClaudeStorage(configDir: ayteConfig, cacheFile: cacheFile),
    ),
    homeDir: home,
    paths: AgentPaths(home: home, configDir: ayteConfig),
  );

  test(
    'discovers native brain sessions via jetbox_summaries_proto.pb and strips XML wrappers',
    () async {
      const sessionId = '11111111-2222-3333-4444-555555555555';
      final workspaceUri = Uri.directory(projectDir).toString();

      final pbBytes = _encodeSummariesProto([
        (
          id: sessionId,
          title: '<CONVERSATION_CONTEXT>\nignored\n</CONVERSATION_CONTEXT>',
          seconds: 1763800000,
          workspaceUri: workspaceUri,
        ),
      ]);
      File(p.join(agyRoot, 'jetbox_summaries_proto.pb'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(pbBytes);

      final transcript = p.join(
        agyRoot,
        'brain',
        sessionId,
        '.system_generated',
        'logs',
        'transcript.jsonl',
      );
      writeFile(
        transcript,
        '${jsonEncode({
          'step_index': 0,
          'type': 'EPHEMERAL_MESSAGE',
          'created_at': '2026-11-20T10:00:00Z',
          'content': 'booting',
        })}\n'
        '${jsonEncode({
          'step_index': 1,
          'type': 'USER_INPUT',
          'created_at': '2026-11-20T10:00:01Z',
          'content': '<system-reminder>Ignore this</system-reminder>\n'
              '<CONVERSATION_CONTEXT>Ignore context</CONVERSATION_CONTEXT>\n'
              '<USER_REQUEST>\nFix catalog session attribution\nMore details\n</USER_REQUEST>',
        })}\n'
        '${jsonEncode({
          'step_index': 2,
          'type': 'PLANNER_RESPONSE',
          'created_at': '2026-11-20T10:05:30Z',
          'content': 'All fixed.',
        })}\n',
      );

      final catalog = createCatalog();
      final projects = await catalog.projects();
      expect(projects, hasLength(1));
      expect(p.equals(projects.single.path, projectDir), isTrue);

      final record = projects.single.sessions.single;
      expect(record.id, sessionId);
      expect(record.title, 'Fix catalog session attribution');
      expect(record.path, isNull);
      expect(
        record.updatedAt.toUtc(),
        DateTime.utc(2026, 11, 20, 10, 5, 30),
      );
    },
  );

  test(
    'skips empty brain dirs, subagent-only sessions, hidden dirs, and missing cwd',
    () async {
      final missingDir = p.join(temp.path, 'deleted-project');
      final missingUri = Uri.directory(missingDir).toString();
      final validUri = Uri.directory(projectDir).toString();

      File(p.join(agyRoot, 'jetbox_summaries_proto.pb'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(
          _encodeSummariesProto([
            (
              id: 'subagent-only-1',
              title: '<CONVERSATION_CONTEXT>internal</CONVERSATION_CONTEXT>',
              seconds: 1763800000,
              workspaceUri: validUri,
            ),
            (
              id: 'missing-cwd-1',
              title: 'Valid title',
              seconds: 1763800000,
              workspaceUri: missingUri,
            ),
            (
              id: 'valid-1',
              title: 'Clean PB Summary',
              seconds: 1763800000,
              workspaceUri: validUri,
            ),
          ]),
        );

      // Empty dir without transcript
      Directory(p.join(agyRoot, 'brain', 'empty-dir')).createSync(recursive: true);
      // Hidden dir
      writeFile(
        p.join(
          agyRoot,
          'brain',
          '.hidden-dir',
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '{"step_index":0,"type":"USER_INPUT","content":"Should skip"}\n',
      );
      // Subagent-only session (no USER_INPUT and dirty pb title)
      writeFile(
        p.join(
          agyRoot,
          'brain',
          'subagent-only-1',
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '{"step_index":0,"type":"EPHEMERAL_MESSAGE","created_at":"2026-11-20T10:00:00Z","content":"agent note"}\n'
        '{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-20T10:01:00Z","content":"done"}\n',
      );
      // Missing cwd
      writeFile(
        p.join(
          agyRoot,
          'brain',
          'missing-cwd-1',
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '{"step_index":0,"type":"USER_INPUT","created_at":"2026-11-20T10:00:00Z","content":"Hello"}\n',
      );
      // Valid session with image-only USER_INPUT + clean PB title fallback
      writeFile(
        p.join(
          agyRoot,
          'brain',
          'valid-1',
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '{"step_index":0,"type":"USER_INPUT","created_at":"2026-11-20T10:00:00Z","content":"<system-reminder>only tag</system-reminder>"}\n',
      );

      final catalog = createCatalog();
      final projects = await catalog.projects();
      expect(projects, hasLength(1));
      expect(projects.single.sessions.map((s) => s.id).toList(), ['valid-1']);
      expect(projects.single.sessions.single.title, 'Clean PB Summary');
    },
  );

  test(
    'claims only antigravity jsonl sessions and ignores claude-code / codebuddy-cli',
    () async {
      final projectSlug = AgentPaths.projectDirName(projectDir);
      final slugDir = p.join(ayteConfig, 'projects', projectSlug);

      // 1. Antigravity session (uuid agy- + gemini-4-neon)
      writeFile(
        p.join(slugDir, 'agy-sess-1.jsonl'),
        '${jsonEncode({
          'type': 'user',
          'uuid': 'agy-u-1',
          'cwd': projectDir,
          'sessionId': 'agy-sess-1',
          'timestamp': '2026-11-20T09:00:00Z',
          'message': {'role': 'user', 'content': 'Agy prompt'},
        })}\n'
        '${jsonEncode({
          'type': 'assistant',
          'uuid': 'agy-a-1',
          'cwd': projectDir,
          'sessionId': 'agy-sess-1',
          'timestamp': '2026-11-20T09:01:00Z',
          'message': {
            'role': 'assistant',
            'model': 'gemini-4-neon',
            'content': [
              {'type': 'text', 'text': 'Hi'},
            ],
          },
        })}\n',
      );

      // 2. Claude Code session
      writeFile(
        p.join(slugDir, 'claude-sess-1.jsonl'),
        '${jsonEncode({
          'type': 'user',
          'uuid': 'u-claude-1',
          'cwd': projectDir,
          'sessionId': 'claude-sess-1',
          'timestamp': '2026-11-20T09:02:00Z',
          'message': {'role': 'user', 'content': 'Claude prompt'},
        })}\n'
        '${jsonEncode({
          'type': 'assistant',
          'uuid': 'a-claude-1',
          'cwd': projectDir,
          'sessionId': 'claude-sess-1',
          'timestamp': '2026-11-20T09:03:00Z',
          'message': {
            'role': 'assistant',
            'model': 'claude-sonnet-4-6',
            'content': [
              {'type': 'text', 'text': 'Hi from Claude'},
            ],
          },
        })}\n',
      );

      // 3. CodeBuddy session
      writeFile(
        p.join(slugDir, 'cb-sess-1.jsonl'),
        '${jsonEncode({
          'type': 'user',
          'uuid': 'u-cb-1',
          'cwd': projectDir,
          'sessionId': 'cb-sess-1',
          'timestamp': '2026-11-20T09:04:00Z',
          'message': {'role': 'user', 'content': 'CodeBuddy prompt'},
        })}\n'
        '${jsonEncode({
          'type': 'assistant',
          'uuid': 'a-cb-1',
          'cwd': projectDir,
          'sessionId': 'cb-sess-1',
          'timestamp': '2026-11-20T09:05:00Z',
          'message': {
            'role': 'assistant',
            'model': 'hy4std',
            'content': [
              {'type': 'text', 'text': 'Hi from CodeBuddy'},
            ],
          },
        })}\n',
      );

      final catalog = createCatalog();
      final projects = await catalog.projects();
      expect(projects, hasLength(1));
      expect(
        projects.single.sessions.map((s) => s.id).toList(),
        ['agy-sess-1'],
      );
      expect(projects.single.sessions.single.path, isNotNull);
    },
  );

  test(
    'deduplicates brain and jsonl sessions preserving path and taking newer updatedAt',
    () async {
      const id = 'dedup-agy-1';
      final projectSlug = AgentPaths.projectDirName(projectDir);
      final jsonlPath = p.join(ayteConfig, 'projects', projectSlug, '$id.jsonl');

      writeFile(
        jsonlPath,
        '${jsonEncode({
          'type': 'user',
          'uuid': 'agy-u-1',
          'cwd': projectDir,
          'sessionId': id,
          'timestamp': '2026-11-20T08:00:00Z',
          'message': {'role': 'user', 'content': 'Initial prompt'},
        })}\n'
        '${jsonEncode({
          'type': 'custom-title',
          'customTitle': 'Custom Renamed Title',
          'sessionId': id,
        })}\n',
      );

      writeFile(
        p.join(
          agyRoot,
          'brain',
          id,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '${jsonEncode({
          'step_index': 0,
          'type': 'USER_INPUT',
          'created_at': '2026-11-20T08:00:00Z',
          'content': '<USER_REQUEST>Initial prompt</USER_REQUEST>',
        })}\n'
        '${jsonEncode({
          'step_index': 1,
          'type': 'PLANNER_RESPONSE',
          'created_at': '2026-11-20T12:30:00Z',
          'content': 'Continued in terminal.',
        })}\n',
      );

      final catalog = createCatalog();
      final sessions = await catalog.sessionsIn(projectDir);
      expect(sessions, hasLength(1));
      final record = sessions.single;
      expect(record.id, id);
      expect(record.path, isNotNull);
      expect(p.equals(record.path!, jsonlPath), isTrue);
      expect(record.title, 'Custom Renamed Title');
      expect(
        record.updatedAt.toUtc(),
        DateTime.utc(2026, 11, 20, 12, 30),
      );
    },
  );

  test(
    'handles path normalization, lazy sync, delete cleanup, and malformed inputs',
    () async {
      const id = 'sync-delete-1';
      const malformedId = 'malformed-brain-1';
      final uri = Uri.directory(projectDir).toString();
      File(p.join(agyRoot, 'jetbox_summaries_proto.pb'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(
          // Append valid entries + trailing truncated bytes to verify fault tolerance
          Uint8List.fromList([
            ..._encodeSummariesProto([
              (
                id: id,
                title: 'Sync me',
                seconds: 1763800000,
                workspaceUri: uri,
              ),
              (
                id: malformedId,
                title: 'Partial PB Title',
                seconds: 1763799000,
                workspaceUri: uri,
              ),
            ]),
            0x0a,
            0xff,
            0xff,
          ]),
        );

      writeFile(
        p.join(
          agyRoot,
          'brain',
          id,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '${jsonEncode({
          'step_index': 0,
          'type': 'USER_INPUT',
          'created_at': '2026-11-20T11:00:00Z',
          'content': '<USER_REQUEST>Lazy sync check</USER_REQUEST>',
        })}\n'
        '${jsonEncode({
          'step_index': 1,
          'type': 'PLANNER_RESPONSE',
          'created_at': '2026-11-20T11:01:00Z',
          'content': 'Synced reply',
        })}\n',
      );
      writeFile(
        p.join(
          agyRoot,
          'brain',
          malformedId,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        'not-json-line\n'
        '${jsonEncode({
          'step_index': 0,
          'type': 'USER_INPUT',
          'created_at': '2026-11-20T10:30:00Z',
          'content': '<USER_REQUEST>Recovered after bad line</USER_REQUEST>',
        })}\n',
      );
      writeFile(p.join(agyRoot, 'conversations', '$id.db'), 'db');
      writeFile(p.join(agyRoot, 'conversations', '$id.pb'), 'pb');

      final catalog = createCatalog();
      // Slash variation & trailing separator
      final altCwd = '${projectDir.replaceAll('\\', '/')}/';
      final sessions = await catalog.sessionsIn(altCwd);
      expect(sessions.map((s) => s.id).toList(), [id, malformedId]);
      final syncRecord = sessions.first;
      expect(syncRecord.path, isNull);
      expect(sessions.last.title, 'Recovered after bad line');

      // Lazy sync produces valid .jsonl readable by ClaudeStorage
      final syncedPath = catalog.ensureSynced(syncRecord);
      expect(syncedPath, isNotNull);
      expect(File(syncedPath!).existsSync(), isTrue);

      // Traversal IDs are rejected by delete
      expect(() => catalog.delete('../evil'), throwsArgumentError);

      // Delete cleans .jsonl, brain/<id>, and conversations/<id>.*
      await catalog.delete(id);
      expect(File(syncedPath).existsSync(), isFalse);
      expect(Directory(p.join(agyRoot, 'brain', id)).existsSync(), isFalse);
      expect(
        File(p.join(agyRoot, 'conversations', '$id.db')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(agyRoot, 'conversations', '$id.pb')).existsSync(),
        isFalse,
      );
    },
  );

  test('KernelRegistry wires AntigravityCatalog to antigravity only', () {
    expect(KernelRegistry.antigravity.catalog, isA<AntigravityCatalog>());
    expect(KernelRegistry.codebuddy.catalog, isA<CodeBuddyCatalog>());
    expect(KernelRegistry.claudeCode.catalog, isA<ClaudeCatalog>());
    expect(KernelRegistry.codex.catalog?.runtimeType.toString(), 'CodexCatalog');
  });

  test(
    'handles metadata.json cwd fallback, List USER_INPUT, UTF-16 surrogate truncation, and corrupt varints',
    () async {
      const id = 'meta-fallback-1';
      // Craft corrupt proto with huge varint length (int64 max) and huge timestamp
      final corruptProto = BytesBuilder()
        ..add(_encodeBytesField(1, _encodeBytesField(1, utf8.encode(id))))
        ..add([0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f]);
      File(p.join(agyRoot, 'jetbox_summaries_proto.pb'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(corruptProto.takeBytes());

      writeFile(
        p.join(agyRoot, 'brain', id, 'metadata.json'),
        jsonEncode({'cwd': projectDir}),
      );
      final emojiPrefix = '${'a' * 119}\u{1F680}extra';
      writeFile(
        p.join(
          agyRoot,
          'brain',
          id,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '${jsonEncode({
          'step_index': 0,
          'type': 'USER_INPUT',
          'created_at': '2026-11-20T14:00:00Z',
          'content': [
            {'type': 'text', 'text': emojiPrefix},
          ],
        })}\n',
      );

      final catalog = createCatalog();
      final sessions = await catalog.sessionsIn(projectDir);
      expect(sessions, hasLength(1));
      final title = sessions.single.title;
      expect(title.endsWith('…'), isTrue);
      // Must not leave an unpaired high surrogate before '…'
      expect(title.length, 120);
      expect(title.codeUnitAt(118), 'a'.codeUnitAt(0));
    },
  );

  test(
    'tolerates non-file URIs in pb and metadata.json without FileSystemException',
    () async {
      final validUri = Uri.directory(projectDir).toString();
      final multiWsSummary = BytesBuilder()
        ..add(_encodeStringField(1, 'Multi workspace summary'))
        ..add(
          _encodeBytesField(3, _encodeVarintField(1, 1763800000)),
        )
        ..add(
          _encodeBytesField(
            9,
            _encodeStringField(1, 'https://example.com/not-file'),
          ),
        )
        ..add(
          _encodeBytesField(
            9,
            _encodeStringField(1, validUri),
          ),
        );
      final multiWsEntry = BytesBuilder()
        ..add(_encodeStringField(1, 'valid-multi-ws'))
        ..add(_encodeBytesField(2, multiWsSummary.takeBytes()));

      final pbBytes = BytesBuilder()
        ..add(_encodeBytesField(1, multiWsEntry.takeBytes()))
        ..add(
          _encodeSummariesProto([
            (
              id: 'non-file-https',
              title: 'HTTPS entry',
              seconds: 1763800000,
              workspaceUri: 'https://example.com/not-file',
            ),
            (
              id: 'non-file-vscode',
              title: 'Remote entry',
              seconds: 1763800000,
              workspaceUri: 'vscode-remote://ssh-remote+box/home/user/repo',
            ),
          ]),
        );

      File(p.join(agyRoot, 'jetbox_summaries_proto.pb'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(pbBytes.takeBytes());

      writeFile(
        p.join(
          agyRoot,
          'brain',
          'valid-multi-ws',
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '${jsonEncode({
          'step_index': 0,
          'type': 'USER_INPUT',
          'created_at': '2026-11-20T10:00:00Z',
          'content': '<USER_REQUEST>Valid multi workspace</USER_REQUEST>',
        })}\n',
      );
      writeFile(
        p.join(agyRoot, 'brain', 'non-file-vscode', 'metadata.json'),
        jsonEncode({'cwd': 'vscode-remote://ssh-remote+box/home/user/repo'}),
      );
      writeFile(
        p.join(
          agyRoot,
          'brain',
          'non-file-vscode',
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '${jsonEncode({
          'step_index': 0,
          'type': 'USER_INPUT',
          'created_at': '2026-11-20T10:00:00Z',
          'content': '<USER_REQUEST>Remote entry</USER_REQUEST>',
        })}\n',
      );
      writeFile(
        p.join(
          agyRoot,
          'brain',
          'non-file-https',
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '${jsonEncode({
          'step_index': 0,
          'type': 'USER_INPUT',
          'created_at': '2026-11-20T10:00:00Z',
          'content': '<USER_REQUEST>HTTPS entry</USER_REQUEST>',
        })}\n',
      );

      final catalog = createCatalog();
      final projects = await catalog.projects();
      expect(projects, hasLength(1));
      expect(
        projects.single.sessions.map((s) => s.id).toList(),
        ['valid-multi-ws'],
      );
    },
  );

  test(
    'falls back from stale deleted pbCwd to existing metadata.json / transcript cwd',
    () async {
      final deletedDir = p.join(temp.path, 'deleted-old-dir');
      File(p.join(agyRoot, 'jetbox_summaries_proto.pb'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(
          _encodeSummariesProto([
            (
              id: 'stale-pb-meta',
              title: 'Stale PB with metadata',
              seconds: 1763800000,
              workspaceUri: Uri.directory(deletedDir).toString(),
            ),
            (
              id: 'stale-pb-transcript',
              title: 'Stale PB with transcript',
              seconds: 1763800000,
              workspaceUri: Uri.directory(deletedDir).toString(),
            ),
          ]),
        );

      writeFile(
        p.join(agyRoot, 'brain', 'stale-pb-meta', 'metadata.json'),
        jsonEncode({'cwd': projectDir}),
      );
      writeFile(
        p.join(
          agyRoot,
          'brain',
          'stale-pb-meta',
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '${jsonEncode({
          'step_index': 0,
          'type': 'USER_INPUT',
          'created_at': '2026-11-20T10:00:00Z',
          'content': '<USER_REQUEST>Recovered via metadata</USER_REQUEST>',
        })}\n',
      );

      writeFile(
        p.join(
          agyRoot,
          'brain',
          'stale-pb-transcript',
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '${jsonEncode({
          'step_index': 0,
          'type': 'USER_INPUT',
          'cwd': projectDir,
          'created_at': '2026-11-20T10:05:00Z',
          'content': '<USER_REQUEST>Recovered via transcript</USER_REQUEST>',
        })}\n',
      );

      final catalog = createCatalog();
      final sessions = await catalog.sessionsIn(projectDir);
      expect(
        sessions.map((s) => s.id).toSet(),
        {'stale-pb-meta', 'stale-pb-transcript'},
      );
    },
  );

  test(
    'recovers <= 256 KB transcript with malformed UTF-8 bytes and strips decoy USER_REQUEST tags inside ignored blocks',
    () async {
      const id = 'bad-utf8-small';
      const decoyId = 'decoy-xml-1';
      File(p.join(agyRoot, 'jetbox_summaries_proto.pb'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(
          _encodeSummariesProto([
            (
              id: id,
              title: '',
              seconds: 1763790000,
              workspaceUri: Uri.directory(projectDir).toString(),
            ),
            (
              id: decoyId,
              title: '',
              seconds: 1763790000,
              workspaceUri: Uri.directory(projectDir).toString(),
            ),
          ]),
        );

      final badTranscript = File(
        p.join(
          agyRoot,
          'brain',
          id,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
      )..parent.createSync(recursive: true);
      final line1 = utf8.encode(
        '${jsonEncode({
          'step_index': 0,
          'type': 'USER_INPUT',
          'created_at': '2026-11-21T08:00:00Z',
          'content': '<USER_REQUEST>Valid prompt before bad bytes</USER_REQUEST>',
        })}\n',
      );
      badTranscript.writeAsBytesSync(<int>[
        ...line1,
        0xff,
        0xfe,
        0x0a,
      ]);

      writeFile(
        p.join(
          agyRoot,
          'brain',
          decoyId,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '${jsonEncode({
          'step_index': 0,
          'type': 'USER_INPUT',
          'created_at': '2026-11-21T09:00:00Z',
          'content': '<system-reminder>Example: <USER_REQUEST>decoy</USER_REQUEST></system-reminder>\n'
              '<CONVERSATION_CONTEXT><USER_REQUEST>ctx decoy</USER_REQUEST></CONVERSATION_CONTEXT>\n'
              '<USER_REQUEST>\nReal User Task\n</USER_REQUEST>',
        })}\n',
      );

      final catalog = createCatalog();
      final sessions = await catalog.sessionsIn(projectDir);
      final byId = {for (final s in sessions) s.id: s};
      expect(byId.keys, containsAll([id, decoyId]));
      expect(byId[id]!.title, 'Valid prompt before bad bytes');
      expect(
        byId[id]!.updatedAt.toUtc(),
        DateTime.utc(2026, 11, 21, 8, 0, 0),
      );
      expect(byId[decoyId]!.title, 'Real User Task');
    },
  );

  test(
    'preserves latest created_at in > 256 KB transcripts for > 32 KB final lines and exact tail boundaries',
    () async {
      // Case A: > 256 KB transcript with > 32 KB (~40 KB) final PLANNER_RESPONSE line
      const bigLineId = 'big-tail-line';
      // Case B: > 256 KB transcript where (length - 32768) lands right after '\n'
      const boundaryId = 'exact-tail-boundary';

      File(p.join(agyRoot, 'jetbox_summaries_proto.pb'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(
          _encodeSummariesProto([
            (
              id: bigLineId,
              title: '',
              seconds: 1762041600,
              workspaceUri: Uri.directory(projectDir).toString(),
            ),
            (
              id: boundaryId,
              title: '',
              seconds: 1762041600,
              workspaceUri: Uri.directory(projectDir).toString(),
            ),
          ]),
        );

      final bigBuf = StringBuffer()
        ..writeln(
          jsonEncode({
            'step_index': 0,
            'type': 'USER_INPUT',
            'created_at': '2026-11-02T00:00:00Z',
            'content': '<USER_REQUEST>Large transcript tail</USER_REQUEST>',
          }),
        );
      final filler = 'x' * 4000;
      for (var i = 1; i <= 70; i++) {
        bigBuf.writeln(
          jsonEncode({
            'step_index': i,
            'type': 'PLANNER_RESPONSE',
            'created_at': '2026-11-02T00:01:00Z',
            'content': filler,
          }),
        );
      }
      bigBuf.writeln(
        jsonEncode({
          'step_index': 71,
          'type': 'PLANNER_RESPONSE',
          'created_at': '2026-11-22T12:00:00Z',
          'content': 'y' * 40000,
        }),
      );
      writeFile(
        p.join(
          agyRoot,
          'brain',
          bigLineId,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        bigBuf.toString(),
      );

      // Build Case B so the final line is literally the last 32768 bytes,
      // meaning byte[length - 32768 - 1] == '\n' (0x0A).
      final headPart = StringBuffer()
        ..writeln(
          jsonEncode({
            'step_index': 0,
            'type': 'USER_INPUT',
            'created_at': '2026-11-02T00:00:00Z',
            'content': '<USER_REQUEST>Exact boundary</USER_REQUEST>',
          }),
        );
      while (utf8.encode(headPart.toString()).length < 270000) {
        headPart.writeln(
          jsonEncode({
            'step_index': 1,
            'type': 'PLANNER_RESPONSE',
            'created_at': '2026-11-02T00:01:00Z',
            'content': 'p' * 2000,
          }),
        );
      }
      final baseFinalLine = jsonEncode({
        'step_index': 99,
        'type': 'PLANNER_RESPONSE',
        'created_at': '2026-11-22T15:30:00Z',
        'content': '',
      });
      // Adjust padding so (baseFinalLine with padding + '\n') == 32768 bytes
      final neededContentLen = 32768 - utf8.encode('$baseFinalLine\n').length;
      final exactTailLine = '${jsonEncode({
        'step_index': 99,
        'type': 'PLANNER_RESPONSE',
        'created_at': '2026-11-22T15:30:00Z',
        'content': 'z' * neededContentLen,
      })}\n';
      expect(utf8.encode(exactTailLine).length, 32768);
      writeFile(
        p.join(
          agyRoot,
          'brain',
          boundaryId,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '${headPart.toString()}$exactTailLine',
      );

      final catalog = createCatalog();
      final sessions = await catalog.sessionsIn(projectDir);
      final byId = {for (final s in sessions) s.id: s};
      expect(
        byId[bigLineId]!.updatedAt.toUtc(),
        DateTime.utc(2026, 11, 22, 12, 0, 0),
      );
      expect(
        byId[boundaryId]!.updatedAt.toUtc(),
        DateTime.utc(2026, 11, 22, 15, 30, 0),
      );
    },
  );

  test(
    'inferJsonlKernelId ignores literal default model without misattributing to antigravity-cli',
    () {
      final onlyDefault = p.join(temp.path, 'only-default.jsonl');
      writeFile(
        onlyDefault,
        '${jsonEncode({
          'type': 'assistant',
          'uuid': 'u-1',
          'message': {'role': 'assistant', 'model': 'default', 'content': []},
        })}\n',
      );
      expect(AntigravityCatalog.inferJsonlKernelId(onlyDefault), isNull);

      final defaultThenClaude = p.join(temp.path, 'default-then-claude.jsonl');
      writeFile(
        defaultThenClaude,
        '${jsonEncode({
          'type': 'assistant',
          'uuid': 'u-1',
          'message': {'role': 'assistant', 'model': 'default', 'content': []},
        })}\n'
        '${jsonEncode({
          'type': 'assistant',
          'uuid': 'u-2',
          'message': {
            'role': 'assistant',
            'model': 'claude-sonnet-4-6',
            'content': [],
          },
        })}\n',
      );
      expect(
        AntigravityCatalog.inferJsonlKernelId(defaultThenClaude),
        'claude-code',
      );
    },
  );

  test(
    'moveSessions relocates both jsonl and unsynced brain sessions after source removal and guards remote paths',
    () async {
      final fromDir = p.join(temp.path, 'from-proj');
      final toDir = p.join(temp.path, 'to-proj');
      Directory(fromDir).createSync(recursive: true);
      Directory(toDir).createSync(recursive: true);

      const syncedId = 'move-synced-agy';
      const unsyncedId = 'move-unsynced-brain';
      const subagentId = 'move-subagent-only';

      final fromSlug = AgentPaths.projectDirName(fromDir);
      writeFile(
        p.join(ayteConfig, 'projects', fromSlug, '$syncedId.jsonl'),
        '${jsonEncode({
          'type': 'user',
          'uuid': 'agy-move-1',
          'cwd': fromDir,
          'sessionId': syncedId,
          'timestamp': '2026-11-20T09:00:00Z',
          'message': {'role': 'user', 'content': 'Synced prompt'},
        })}\n',
      );

      File(p.join(agyRoot, 'jetbox_summaries_proto.pb'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(
          _encodeSummariesProto([
            (
              id: unsyncedId,
              title: 'Unsynced brain session',
              seconds: 1763800000,
              workspaceUri: Uri.directory(fromDir).toString(),
            ),
            (
              id: subagentId,
              title: '<CONVERSATION_CONTEXT>subagent</CONVERSATION_CONTEXT>',
              seconds: 1763800000,
              workspaceUri: Uri.directory(fromDir).toString(),
            ),
          ]),
        );

      writeFile(
        p.join(
          agyRoot,
          'brain',
          unsyncedId,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '${jsonEncode({
          'step_index': 0,
          'type': 'USER_INPUT',
          'created_at': '2026-11-20T10:00:00Z',
          'content': '<USER_REQUEST>Unsynced move prompt</USER_REQUEST>',
        })}\n'
        '${jsonEncode({
          'step_index': 1,
          'type': 'PLANNER_RESPONSE',
          'created_at': '2026-11-20T10:01:00Z',
          'content': 'Done.',
        })}\n',
      );
      writeFile(
        p.join(
          agyRoot,
          'brain',
          subagentId,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '${jsonEncode({
          'step_index': 0,
          'type': 'EPHEMERAL_MESSAGE',
          'created_at': '2026-11-20T10:00:00Z',
          'content': 'internal',
        })}\n',
      );

      // Simulate folder move: remove fromDir from disk before moveSessions
      Directory(fromDir).deleteSync(recursive: true);

      final catalog = createCatalog();
      expect(
        () => catalog.moveSessions('ssh://box/home/user/repo', toDir),
        throwsUnsupportedError,
      );
      expect(
        () => catalog.moveSessions(toDir, 'ssh://box/home/user/repo'),
        throwsUnsupportedError,
      );

      final movedCount = await catalog.moveSessions(fromDir, toDir);
      expect(movedCount, 2);

      final toSessions = await catalog.sessionsIn(toDir);
      expect(
        toSessions.map((s) => s.id).toSet(),
        {syncedId, unsyncedId},
      );
      for (final s in toSessions) {
        expect(p.equals(s.cwd, toDir), isTrue);
        expect(s.path, isNotNull);
        expect(File(s.path!).existsSync(), isTrue);
      }
      expect(await catalog.sessionsIn(fromDir), isEmpty);
    },
  );

  test(
    'moveSessions normalizes trailing and forward slashes so synced jsonl and unsynced brain sessions both relocate without stray folders',
    () async {
      final fromDir = p.join(temp.path, 'From');
      final toDir = p.join(temp.path, 'To');
      Directory(fromDir).createSync(recursive: true);
      Directory(toDir).createSync(recursive: true);

      const syncedId = 'trail-synced-agy';
      const unsyncedId = 'trail-unsynced-brain';

      final fromSlug = AgentPaths.projectDirName(fromDir);
      final toSlug = AgentPaths.projectDirName(toDir);
      writeFile(
        p.join(ayteConfig, 'projects', fromSlug, '$syncedId.jsonl'),
        '${jsonEncode({
          'type': 'user',
          'uuid': 'agy-trail-1',
          'cwd': fromDir,
          'sessionId': syncedId,
          'timestamp': '2026-11-20T09:00:00Z',
          'message': {'role': 'user', 'content': 'Trailing slash synced'},
        })}\n',
      );

      File(p.join(agyRoot, 'jetbox_summaries_proto.pb'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(
          _encodeSummariesProto([
            (
              id: unsyncedId,
              title: 'Trailing slash unsynced',
              seconds: 1763800000,
              workspaceUri: Uri.directory(fromDir).toString(),
            ),
          ]),
        );

      writeFile(
        p.join(
          agyRoot,
          'brain',
          unsyncedId,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
        '${jsonEncode({
          'step_index': 0,
          'type': 'USER_INPUT',
          'created_at': '2026-11-20T10:00:00Z',
          'content': '<USER_REQUEST>Trailing slash brain prompt</USER_REQUEST>',
        })}\n'
        '${jsonEncode({
          'step_index': 1,
          'type': 'PLANNER_RESPONSE',
          'created_at': '2026-11-20T10:01:00Z',
          'content': 'Done.',
        })}\n',
      );

      final catalog = createCatalog();
      final slashFrom = '${fromDir.replaceAll(r'\', '/')}/';
      final slashTo = '${toDir.replaceAll(r'\', '/')}/';

      final movedCount = await catalog.moveSessions(slashFrom, slashTo);
      expect(movedCount, 2);

      final toSessions = await catalog.sessionsIn(toDir);
      expect(toSessions.map((s) => s.id).toSet(), {syncedId, unsyncedId});
      for (final s in toSessions) {
        expect(p.equals(s.cwd, toDir), isTrue);
        expect(s.path, isNotNull);
        expect(File(s.path!).existsSync(), isTrue);
      }
      expect(await catalog.sessionsIn(fromDir), isEmpty);
      expect(
        Directory(p.join(ayteConfig, 'projects', '$toSlug-')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(ayteConfig, 'projects', toSlug)).existsSync(),
        isTrue,
      );
    },
  );

  test(
    'skips unsynced Ayte-bridged shadows, deleted Ayte sessions, and agy subagent workers',
    () async {
      final validUri = Uri.directory(projectDir).toString();
      final projectSlug = AgentPaths.projectDirName(projectDir);
      final slugDir = p.join(ayteConfig, 'projects', projectSlug);

      File(p.join(agyRoot, 'jetbox_summaries_proto.pb'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(
          _encodeSummariesProto([
            (
              id: 'shadow-bridge-1',
              title: '<CONVERSATION_CONTEXT>',
              seconds: 1763800001,
              workspaceUri: validUri,
            ),
            (
              id: 'deleted-ayte-1',
              title: 'Deleted Ayte Chat',
              seconds: 1763800002,
              workspaceUri: validUri,
            ),
            (
              id: 'subagent-worker-1',
              title: 'Worker task',
              seconds: 1763800003,
              workspaceUri: validUri,
            ),
            (
              id: 'kept-ayte-1',
              title: 'Kept Ayte Chat',
              seconds: 1763800004,
              workspaceUri: validUri,
            ),
            (
              id: 'native-cli-1',
              title: 'Native CLI Chat',
              seconds: 1763800005,
              workspaceUri: validUri,
            ),
          ]),
        );

      void writeBrain(String id, String content) {
        writeFile(
          p.join(
            agyRoot,
            'brain',
            id,
            '.system_generated',
            'logs',
            'transcript.jsonl',
          ),
          '${jsonEncode({
            'step_index': 0,
            'type': 'USER_INPUT',
            'created_at': '2026-11-23T06:00:00Z',
            'content': content,
          })}\n',
        );
      }

      // 1. Ayte-bridged shadow session (no .jsonl under this UUID) -> skip
      writeBrain(
        'shadow-bridge-1',
        '<USER_REQUEST>\n'
        '<CONVERSATION_CONTEXT>\n'
        'Previous turns in this session before switching to Antigravity CLI:\n'
        'User: old question\n'
        '</CONVERSATION_CONTEXT>\n\n'
        'Follow up\n'
        '</USER_REQUEST>',
      );
      // 2. Deleted Ayte session (leftover brain dir with BaoCode reminder, no .jsonl) -> skip
      writeBrain(
        'deleted-ayte-1',
        '<USER_REQUEST>\n'
        '<system-reminder>Reply suggestions are on: the user turned them on in BaoCode.</system-reminder>\n'
        'Old deleted chat\n'
        '</USER_REQUEST>',
      );
      // 3. agy subagent / run_workflow worker child session -> skip
      writeBrain(
        'subagent-worker-1',
        '<USER_REQUEST>\n'
        'Inspect UMC pages\n\n'
        'When you are done, call the finish tool with your result.\n'
        '</USER_REQUEST>',
      );
      // 4. Existing Ayte session WITH .jsonl (even with BaoCode reminder) -> keep
      writeBrain(
        'kept-ayte-1',
        '<USER_REQUEST>\n'
        '<system-reminder>Reply suggestions are on: the user turned them on in BaoCode.</system-reminder>\n'
        'Active Ayte chat\n'
        '</USER_REQUEST>',
      );
      writeFile(
        p.join(slugDir, 'kept-ayte-1.jsonl'),
        '${jsonEncode({
          'type': 'user',
          'uuid': 'agy-u-1',
          'cwd': projectDir,
          'sessionId': 'kept-ayte-1',
          'timestamp': '2026-11-23T06:00:00Z',
          'message': {'role': 'user', 'content': 'Active Ayte chat'},
        })}\n',
      );
      // 5. Legitimate standalone native agy CLI session -> keep
      writeBrain(
        'native-cli-1',
        '<USER_REQUEST>\nHelp me install atoll\n</USER_REQUEST>',
      );

      final catalog = createCatalog();
      final projects = await catalog.projects();
      expect(projects, hasLength(1));
      expect(
        projects.single.sessions.map((s) => s.id).toSet(),
        equals({'kept-ayte-1', 'native-cli-1'}),
      );
    },
  );
}

Uint8List _encodeSummariesProto(
  List<({String id, String title, int seconds, String workspaceUri})> entries,
) {
  final out = BytesBuilder();
  for (final e in entries) {
    final ts = BytesBuilder()
      ..add(_encodeVarintField(1, e.seconds));
    final ws = BytesBuilder()
      ..add(_encodeStringField(1, e.workspaceUri));
    final summary = BytesBuilder()
      ..add(_encodeStringField(1, e.title))
      ..add(_encodeBytesField(3, ts.takeBytes()))
      ..add(_encodeBytesField(9, ws.takeBytes()));
    final entry = BytesBuilder()
      ..add(_encodeStringField(1, e.id))
      ..add(_encodeBytesField(2, summary.takeBytes()));
    out.add(_encodeBytesField(1, entry.takeBytes()));
  }
  return out.takeBytes();
}

Uint8List _encodeVarintField(int fieldNumber, int value) {
  final b = BytesBuilder();
  _writeVarint(b, (fieldNumber << 3) | 0);
  _writeVarint(b, value);
  return b.takeBytes();
}

Uint8List _encodeStringField(int fieldNumber, String value) =>
    _encodeBytesField(fieldNumber, utf8.encode(value));

Uint8List _encodeBytesField(int fieldNumber, List<int> data) {
  final b = BytesBuilder();
  _writeVarint(b, (fieldNumber << 3) | 2);
  _writeVarint(b, data.length);
  b.add(data);
  return b.takeBytes();
}

void _writeVarint(BytesBuilder b, int value) {
  var v = value;
  while (v >= 0x80) {
    b.addByte((v & 0x7f) | 0x80);
    v >>>= 7;
  }
  b.addByte(v);
}
