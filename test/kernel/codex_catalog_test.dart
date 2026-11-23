import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late CodexCatalog catalog;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('codex_catalog_test_');
    catalog = CodexCatalog(codexHome: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  File writeRollout(
    String relPath,
    List<Object> lines,
  ) {
    final file = File(p.join(tempDir.path, 'sessions', relPath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${lines.map((l) => l is String ? l : jsonEncode(l)).join('\n')}\n',
    );
    return file;
  }

  test('normalizeWindowsPath strips \\\\?\\ and \\\\?\\UNC\\ prefixes', () {
    expect(
      CodexCatalog.normalizeWindowsPath(r'\\?\C:\Users\ASUS\Proj\'),
      r'C:\Users\ASUS\Proj',
    );
    expect(
      CodexCatalog.normalizeWindowsPath(r'\\?\UNC\nas\share\repo\'),
      r'\\nas\share\repo',
    );
    expect(
      CodexCatalog.normalizeWindowsPath('//?/UNC/nas/share/repo/'),
      r'\\nas\share\repo',
    );
    expect(
      CodexCatalog.normalizeWindowsPath(r'\\nas\share\repo\'),
      r'\\nas\share\repo',
    );
    expect(
      CodexCatalog.normalizeWindowsPath('C:/Users/ASUS/Proj/'),
      r'C:\Users\ASUS\Proj',
    );
  });

  test('projects() and sessionsIn() parse rollout files, strip \\\\?\\, and apply session_index titles', () async {
    final projA = p.join(tempDir.path, 'ProjA');
    final projB = p.join(tempDir.path, 'ProjB');
    final rawWinProjA = Platform.isWindows ? '\\\\?\\$projA\\' : projA;

    writeRollout('2026/11/20/rollout-2026-11-20T10-00-00-sess_1.jsonl', [
      {
        'timestamp': '2026-11-20T10:00:00Z',
        'type': 'session_meta',
        'payload': {
          'id': 'sess_1',
          'cwd': rawWinProjA,
          'timestamp': '2026-11-20T10:00:00Z',
        },
      },
      {
        'timestamp': '2026-11-20T10:00:01Z',
        'type': 'response_item',
        'payload': {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': '<environment_context>ignore me</environment_context>'},
          ],
        },
      },
      {
        'timestamp': '2026-11-20T10:00:02Z',
        'type': 'event_msg',
        'payload': {
          'type': 'user_message',
          'message': 'Fix Windows shim launching',
        },
      },
      'NOT VALID JSON LINE',
    ]);

    writeRollout('2026/11/21/rollout-2026-11-21T12-00-00-sess_2.jsonl', [
      {
        'timestamp': '2026-11-21T12:00:00Z',
        'type': 'session_meta',
        'payload': {
          'id': 'sess_2',
          'cwd': projA,
          'timestamp': '2026-11-21T12:00:00Z',
        },
      },
      {
        'timestamp': '2026-11-21T12:00:05Z',
        'type': 'event_msg',
        'payload': {
          'type': 'user_message',
          'message': '<agent-message from="Lead">Inspect repo</agent-message>',
        },
      },
    ]);

    writeRollout('2026/11/19/rollout-2026-11-19T08-00-00-sess_3.jsonl', [
      {
        'timestamp': '2026-11-19T08:00:00Z',
        'type': 'session_meta',
        'payload': {
          'id': 'sess_3',
          'cwd': projB,
        },
      },
      {
        'timestamp': '2026-11-19T08:01:00Z',
        'type': 'event_msg',
        'payload': {'type': 'user_message', 'message': 'Old prompt'},
      },
    ]);

    File(p.join(tempDir.path, 'session_index.jsonl')).writeAsStringSync(
      '${jsonEncode({'id': 'sess_1', 'thread_name': 'Custom Title 1', 'updated_at': '2026-11-22T09:00:00Z'})}\n'
      'bad-line\n',
    );

    final results = await Future.wait([catalog.projects(), catalog.projects()]);
    final projects = results.first;
    expect(projects, hasLength(2));
    expect(projects.first.path, projA);
    expect(projects.first.sessions.map((s) => s.id), ['sess_1', 'sess_2']);
    expect(projects.first.sessions[0].title, 'Custom Title 1');
    expect(projects.first.sessions[1].title, 'Inspect repo');

    final inA = await catalog.sessionsIn(projA);
    expect(inA.map((s) => s.id), ['sess_1', 'sess_2']);
    if (Platform.isWindows) {
      final inALower = await catalog.sessionsIn(projA.toLowerCase());
      expect(inALower.map((s) => s.id), ['sess_1', 'sess_2']);
    }
  });

  test('delete() validates id, deletes .jsonl and .jsonl.zst, and prunes session_index.jsonl', () async {
    await expectLater(catalog.delete('../escape'), throwsArgumentError);
    await expectLater(catalog.delete(''), throwsArgumentError);

    final f1 = writeRollout('2026/11/20/rollout-2026-11-20T10-00-00-del_1.jsonl', [
      {
        'type': 'session_meta',
        'payload': {'id': 'del_1', 'cwd': tempDir.path},
      },
    ]);
    final f2 = File(p.join(tempDir.path, 'sessions', '2026', '11', '20', 'rollout-2026-11-20T10-00-00-del_1.jsonl.zst'))
      ..writeAsStringSync('zst');
    final fKeep = writeRollout('2026/11/20/rollout-2026-11-20T11-00-00-keep_1.jsonl', [
      {
        'type': 'session_meta',
        'payload': {'id': 'keep_1', 'cwd': tempDir.path},
      },
    ]);
    final fSuffixSibling = writeRollout(
      '2026/11/20/rollout-2026-11-20T11-00-00-other-del_1.jsonl',
      [
        {
          'type': 'session_meta',
          'payload': {'id': 'other-del_1', 'cwd': tempDir.path},
        },
      ],
    );
    final idx = File(p.join(tempDir.path, 'session_index.jsonl'))
      ..writeAsStringSync(
        '${jsonEncode({'id': 'del_1', 'thread_name': 'Delete Me'})}\n'
        '${jsonEncode({'id': 'keep_1', 'thread_name': 'Keep Me'})}\n',
      );

    await catalog.delete('del_1');
    expect(f1.existsSync(), isFalse);
    expect(f2.existsSync(), isFalse);
    expect(fKeep.existsSync(), isTrue);
    expect(fSuffixSibling.existsSync(), isTrue);
    final idxLines = idx.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
    expect(idxLines, hasLength(1));
    expect(jsonDecode(idxLines.single)['id'], 'keep_1');
  });

  test('T2.5: delete() matches non-canonical rollout files even with leading malformed JSON lines', () async {
    final target = writeRollout('2026/11/22/custom-rollout-a.jsonl', [
      'CORRUPT LINE 1',
      '{not valid json',
      {
        'type': 'session_meta',
        'payload': {'id': 'del_corrupt_1', 'cwd': tempDir.path},
      },
      {
        'type': 'event_msg',
        'payload': {'type': 'user_message', 'message': 'Delete me'},
      },
    ]);
    final other = writeRollout('2026/11/22/custom-rollout-b.jsonl', [
      'CORRUPT LINE 1',
      {
        'type': 'session_meta',
        'payload': {'id': 'keep_corrupt_2', 'cwd': tempDir.path},
      },
    ]);

    final listedBefore = await catalog.sessionsIn(tempDir.path);
    expect(listedBefore.map((s) => s.id), containsAll(['del_corrupt_1', 'keep_corrupt_2']));

    await catalog.delete('del_corrupt_1');
    expect(target.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
  });

  test('session_index.jsonl preserves title with latest updated_at even when entries are out of order', () async {
    final proj = p.join(tempDir.path, 'ProjOrder');
    writeRollout('2026/11/22/rollout-2026-11-22T10-00-00-sess_ord.jsonl', [
      {
        'timestamp': '2026-11-22T10:00:00Z',
        'type': 'session_meta',
        'payload': {'id': 'sess_ord', 'cwd': proj},
      },
      {
        'timestamp': '2026-11-22T10:00:01Z',
        'type': 'event_msg',
        'payload': {'type': 'user_message', 'message': 'fallback'},
      },
    ]);
    File(p.join(tempDir.path, 'session_index.jsonl')).writeAsStringSync(
      '${jsonEncode({'id': 'sess_ord', 'thread_name': 'Newer Title', 'updated_at': '2026-11-22T12:00:00Z'})}\n'
      '${jsonEncode({'id': 'sess_ord', 'thread_name': 'Older Title', 'updated_at': '2026-11-22T10:00:00Z'})}\n',
    );

    final sessions = await catalog.sessionsIn(proj);
    expect(sessions.single.title, 'Newer Title');
  });

  test('noteSessionTitle() appends custom title and readRolloutPage() paginates turns cleanly', () async {
    await catalog.noteSessionTitle('sess_p', 'Renamed Session');
    final lines = <Object>[
      {
        'type': 'session_meta',
        'payload': {'id': 'sess_p', 'cwd': tempDir.path},
      },
      {
        'type': 'turn_context',
        'payload': {'model': 'gpt-5.5', 'effort': 'high'},
      },
    ];
    for (var i = 1; i <= 12; i++) {
      lines.addAll([
        {
          'type': 'event_msg',
          'payload': {'type': 'user_message', 'message': 'turn $i'},
        },
        {
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'turn $i'},
            ],
          },
        },
        if (i == 12)
          {
            'type': 'response_item',
            'payload': {
              'type': 'local_shell_call',
              'call_id': 'cmd-12',
              'action': {'command': 'echo ok'},
            },
          },
        if (i == 12)
          {
            'type': 'response_item',
            'payload': {
              'type': 'local_shell_call_output',
              'call_id': 'cmd-12',
              'output': 'ok',
            },
          },
        {
          'type': 'event_msg',
          'payload': {'type': 'agent_message', 'message': 'reply $i'},
        },
      ]);
    }
    final file = writeRollout('2026/11/22/rollout-2026-11-22T09-00-00-sess_p.jsonl', lines);

    final page1 = await CodexCatalog.readRolloutPage(file.path, turns: 10);
    expect(page1.turns, hasLength(10));
    expect(page1.earlierBeforeTurn, 2);
    expect(page1.model, 'gpt-5.5');
    expect(page1.effort, 'high');
    // Deduplicated user message (only 1 userMessage in turn 12)
    final turn12Items = page1.turns.last.items;
    expect(turn12Items.where((m) => m['type'] == 'userMessage'), hasLength(1));
    expect(
      turn12Items.where((m) => m['type'] == 'commandExecution').single['aggregatedOutput'],
      'ok',
    );

    final page2 = await CodexCatalog.readRolloutPage(
      file.path,
      turns: 10,
      beforeTurn: page1.earlierBeforeTurn,
    );
    expect(page2.turns, hasLength(2));
    expect(page2.earlierBeforeTurn, isNull);

    final sessions = await catalog.sessionsIn(tempDir.path);
    expect(sessions.single.title, 'Renamed Session');
  });

  test('resolveHome() and CodexModels.loadLocalCatalog() fall back empty CODEX_HOME to <HOME|USERPROFILE>/.codex and handle mixed-case Windows env', () {
    final fakeHome = Directory(p.join(tempDir.path, 'home_fallback'))
      ..createSync(recursive: true);
    final dotCodex = Directory(p.join(fakeHome.path, '.codex'))
      ..createSync(recursive: true);
    File(p.join(dotCodex.path, 'models_cache.json')).writeAsStringSync(
      jsonEncode({
        'models': [
          {
            'slug': 'gpt-5.4-custom',
            'display_name': 'GPT 5.4 Custom',
            'description': 'From fallback .codex',
          },
        ],
      }),
    );

    // Empty codexHome + empty CODEX_HOME falls back to <HOME>/.codex.
    expect(
      CodexCatalog(
        codexHome: '',
        environment: {'CODEX_HOME': '', 'HOME': fakeHome.path},
      ).resolveHome(),
      dotCodex.path,
    );
    expect(
      CodexCatalog(
        codexHome: '   ',
        environment: {'CODEX_HOME': '   ', 'USERPROFILE': fakeHome.path},
      ).resolveHome(),
      dotCodex.path,
    );

    // Mixed-case Windows env keys.
    expect(
      CodexCatalog.resolveHomeFromEnv(
        {'Codex_Home': '', 'Home': r'C:\Users\MixedHome'},
        codexHome: '',
        forceWindows: true,
      ),
      r'C:\Users\MixedHome\.codex',
    );
    expect(
      CodexCatalog.resolveHomeFromEnv(
        {'Codex_Home': r'D:\CustomCodex', 'Home': r'C:\Users\MixedHome'},
        forceWindows: true,
      ),
      r'D:\CustomCodex',
    );

    // Explicit blank HOME + USERPROFILE returns '' instead of CWD-relative '.codex'.
    expect(
      CodexCatalog.resolveHomeFromEnv(
        {'CODEX_HOME': '', 'HOME': '', 'USERPROFILE': ''},
      ),
      '',
    );

    final loaded = CodexModels.loadLocalCatalog(
      codexHome: '',
      environment: {'CODEX_HOME': '', 'HOME': fakeHome.path},
    );
    expect(loaded.models.map((m) => m.id), ['gpt-5.4-custom']);

    final blankLoaded = CodexModels.loadLocalCatalog(
      codexHome: '',
      environment: {'CODEX_HOME': '', 'HOME': '', 'USERPROFILE': ''},
    );
    expect(
      blankLoaded.models.map((m) => m.id),
      CodexModels.fallback.map((m) => m.id),
    );
  });
}
