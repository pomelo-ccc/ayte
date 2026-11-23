import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/search/claude_conversation_search.dart';
import 'package:baocode/search/conversation_search.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('conversations'));
  tearDown(() => temp.deleteSync(recursive: true));

  String line(Map<String, Object?> entry) => jsonEncode(entry);

  void session(String id, List<Map<String, Object?>> entries) {
    File(p.join(temp.path, 'projects', '-tmp-app', '$id.jsonl'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(entries.map(line).join('\n'));
  }

  Map<String, Object?> user(Object content, {bool meta = false}) => {
    'type': 'user',
    if (meta) 'isMeta': true,
    'message': {'role': 'user', 'content': content},
  };

  Map<String, Object?> assistant(List<Object?> blocks) => {
    'type': 'assistant',
    'message': {'role': 'assistant', 'content': blocks},
  };

  test('finds what was said, not tools\' output or notes', () async {
    session('s1', [
      user('How do I rotate the signing keys?'),
      assistant([
        {'type': 'thinking', 'thinking': 'secret plan'},
        {'type': 'text', 'text': 'Run the rotation script, then redeploy.'},
        {
          'type': 'tool_use',
          'name': 'Bash',
          'input': {'command': 'grep'},
        },
      ]),
      user([
        {'type': 'tool_result', 'content': 'grep output only in a tool'},
      ]),
      user('<command-name>/clear</command-name>'),
      user('caveat only in a note', meta: true),
    ]);
    session('s2', [user('Unrelated question about CSS grids')]);

    final search = ClaudeConversationSearch(configDir: temp.path);
    final hits = await search.search('ROTATION');
    expect(hits, hasLength(1));
    final hit = hits.single;
    expect(hit.sessionId, 's1');
    expect(
      hit.snippet.substring(hit.matchStart, hit.matchStart + hit.matchLength),
      'rotation',
    );
    expect(await search.search('secret plan'), isEmpty);
    expect(await search.search('grep output'), isEmpty);
    expect(await search.search('caveat'), isEmpty);
    expect(await search.search('/clear'), isEmpty);
    expect((await search.search('css')).single.sessionId, 's2');

    // A file written since is read again; one removed, forgotten.
    session('s2', [user('Now about flexbox')]);
    File(p.join(temp.path, 'projects', '-tmp-app', 's2.jsonl'))
        .setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
    expect(await search.search('css'), isEmpty);
    expect((await search.search('flexbox')).single.sessionId, 's2');
    File(p.join(temp.path, 'projects', '-tmp-app', 's1.jsonl')).deleteSync();
    expect(await search.search('rotation'), isEmpty);
  });

  test('a snippet is one line around the match, cut where it was', () {
    final text = '${'a' * 50}\nThe Needle\nis here${'b' * 200}';
    final hit = findIn('id', text, 'needle')!;
    expect(hit.snippet, startsWith('…'));
    expect(hit.snippet, endsWith('…'));
    expect(hit.snippet, isNot(contains('\n')));
    expect(
      hit.snippet.substring(hit.matchStart, hit.matchStart + hit.matchLength),
      'Needle',
    );
    expect(findIn('id', 'short', 'missing'), isNull);
  });

  test('handles malformed UTF-8, corrupt JSON lines, spaced JSON and agent-message', () async {
    final file = File(p.join(temp.path, 'projects', '-app', 'file-stem.jsonl'))
      ..parent.createSync(recursive: true);
    final goodLine1 =
        '{"sessionId" : "canonical-1", "type" : "user", "message" : {"role" : "user", "content" : "Spaced JSON query"}}';
    final corruptLine = '{"type":"user","message":{"content":"broken';
    final goodLine2 = jsonEncode({
      'sessionId': 'canonical-1',
      'type': 'user',
      'message': {
        'role': 'user',
        'content': '<agent-message from="coord" session="s0">Inter-agent handoff payload</agent-message>',
      },
    });
    final goodLine3 = jsonEncode({
      'sessionId': 'canonical-1',
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Handled resiliently'},
        ],
      },
    });
    final bytes = <int>[
      ...utf8.encode('$goodLine1\n'),
      0xFF,
      0xFE,
      0x80,
      ...utf8.encode(' bad bytes line\n'),
      ...utf8.encode('$corruptLine\n'),
      ...utf8.encode('$goodLine2\n'),
      ...utf8.encode('$goodLine3\n'),
    ];
    file.writeAsBytesSync(bytes);

    final search = ClaudeConversationSearch(configDir: temp.path);
    final spacedHits = await search.search('Spaced JSON');
    expect(spacedHits, hasLength(1));
    expect(spacedHits.single.sessionId, 'canonical-1');

    final agentHits = await search.search('handoff payload');
    expect(agentHits, hasLength(1));
    expect(agentHits.single.sessionId, 'canonical-1');
    expect(await search.search('<agent-message'), isEmpty);

    final replyHits = await search.search('resiliently');
    expect(replyHits, hasLength(1));
    expect(await search.search('broken'), isEmpty);
    expect(await search.search('   '), isEmpty);
    expect(await search.search('resiliently', limit: 0), isEmpty);
  });

  test('indexes agy native brain/, CodeBuddy, standalone Claude, and Codex rollouts with dedup', () async {
    final ayteDir = p.join(temp.path, 'ayte');
    final homeDir = p.join(temp.path, 'home');

    // 1. Standalone Claude session
    File(p.join(homeDir, '.claude', 'projects', '-proj', 'claude-1.jsonl'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${jsonEncode(user('Claude standalone question about shaders'))}\n',
      );

    // 2. Standalone CodeBuddy session
    File(p.join(homeDir, '.codebuddy', 'projects', '-proj', 'cb-1.jsonl'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${jsonEncode(assistant([{'type': 'text', 'text': 'CodeBuddy reply about telemetry'}]))}\n',
      );

    // 3. Antigravity native brain/<id>/.system_generated/logs/transcript.jsonl
    final agyTranscript = File(
      p.join(
        homeDir,
        '.gemini',
        'antigravity-cli',
        'brain',
        'agy-native-1',
        '.system_generated',
        'logs',
        'transcript.jsonl',
      ),
    )..parent.createSync(recursive: true);
    agyTranscript.writeAsStringSync([
      jsonEncode({
        'type': 'USER_INPUT',
        'content':
            '<system-reminder>ignore reminder</system-reminder>'
            '<CONVERSATION_CONTEXT>ignore context</CONVERSATION_CONTEXT>'
            '<USER_REQUEST>\nFix the Antigravity bridge timeout\n</USER_REQUEST>',
      }),
      jsonEncode({
        'type': 'USER_INPUT',
        'content': '<command-name>/clear</command-name>',
      }),
      jsonEncode({
        'type': 'PLANNER_RESPONSE',
        'thinking': 'hidden internal chain of thought',
        'tool_calls': [
          {'name': 'bash', 'args': 'secret_tool_arg'},
        ],
        'content': 'Increased the Antigravity loopback timeout.',
      }),
      jsonEncode({'type': 'EPHEMERAL_MESSAGE', 'content': 'ephemeral noise'}),
    ].join('\n'));
    // Hidden/invalid brain directory should be ignored
    File(
      p.join(
        homeDir,
        '.gemini',
        'antigravity-cli',
        'brain',
        '.hidden-brain',
        '.system_generated',
        'logs',
        'transcript.jsonl',
      ),
    )
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({'type': 'USER_INPUT', 'content': 'hidden brain secret'}),
      );

    // 4. Codex rollout under sessions/YYYY/MM/DD/
    File(
      p.join(
        homeDir,
        '.codex',
        'sessions',
        '2026',
        '11',
        '22',
        'rollout-2026-11-22T10-00-00Z-11111111-2222-3333-4444-555555555555.jsonl',
      ),
    )
      ..parent.createSync(recursive: true)
      ..writeAsStringSync([
        jsonEncode({
          'type': 'session_meta',
          'payload': {'id': 'codex-thread-99', 'cwd': r'D:\work\repo'},
        }),
        jsonEncode({
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {
                'type': 'input_text',
                'text': '<environment_context>CWD=/work</environment_context>',
              },
            ],
          },
        }),
        jsonEncode({
          'type': 'event_msg',
          'payload': {
            'type': 'user_message',
            'message':
                '<agent-message from="main">Check the Codex rollout parser</agent-message>',
          },
        }),
        jsonEncode({
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {
                'type': 'input_text',
                'text':
                    '<agent-message from="main">Check the Codex rollout parser</agent-message>',
              },
            ],
          },
        }),
        jsonEncode({
          'type': 'event_msg',
          'payload': {'type': 'agent_reasoning', 'text': 'internal reasoning'},
        }),
        jsonEncode({
          'type': 'response_item',
          'payload': {
            'type': 'local_shell_call',
            'call_id': 'c1',
            'action': {'command': 'shell_secret'},
          },
        }),
        jsonEncode({
          'type': 'event_msg',
          'payload': {
            'type': 'agent_message',
            'message': 'Codex rollout parser verified cleanly.',
          },
        }),
      ].join('\n'));

    // 5. Duplicate sessionId across ~/.ayte/projects and brain/ (newer wins)
    final olderSynced = File(
      p.join(ayteDir, 'projects', '-proj', 'agy-native-1.jsonl'),
    )..parent.createSync(recursive: true);
    olderSynced.writeAsStringSync(
      '${jsonEncode(user('Older synced copy mentioning Antigravity'))}\n',
    );
    final now = DateTime.now();
    olderSynced.setLastModifiedSync(now.subtract(const Duration(minutes: 10)));
    agyTranscript.setLastModifiedSync(now);

    final search = ClaudeConversationSearch(
      configDir: ayteDir,
      homeDir: homeDir,
    );

    expect((await search.search('shaders')).single.sessionId, 'claude-1');
    expect((await search.search('telemetry')).single.sessionId, 'cb-1');

    final agyHits = await search.search('Antigravity');
    expect(agyHits, hasLength(1));
    expect(agyHits.single.sessionId, 'agy-native-1');
    expect(agyHits.single.snippet, contains('Fix the Antigravity bridge'));
    expect(await search.search('ignore reminder'), isEmpty);
    expect(await search.search('ignore context'), isEmpty);
    expect(await search.search('hidden internal chain'), isEmpty);
    expect(await search.search('secret_tool_arg'), isEmpty);
    expect(await search.search('ephemeral noise'), isEmpty);
    expect(await search.search('hidden brain secret'), isEmpty);
    expect(await search.search('/clear'), isEmpty);

    final codexHits = await search.search('Codex rollout parser');
    expect(codexHits, hasLength(1));
    expect(codexHits.single.sessionId, 'codex-thread-99');
    expect(await search.search('environment_context'), isEmpty);
    expect(await search.search('internal reasoning'), isEmpty);
    expect(await search.search('shell_secret'), isEmpty);
  });

  test('supports Windows extended-length configDir prefix and incremental updates', () async {
    final base = p.join(temp.path, 'winroot');
    final codexFile = File(
      p.join(
        base,
        'codex',
        'sessions',
        '2026',
        '11',
        'rollout-2026-11-22T09-00-00Z-abcdef12-3456-7890-abcd-ef1234567890.jsonl',
      ),
    )..parent.createSync(recursive: true);
    codexFile.writeAsStringSync(
      '${jsonEncode({'type': 'event_msg', 'payload': {'type': 'user_message', 'message': 'Alpha milestone token'}})}\n',
    );

    final prefixedCodex = Platform.isWindows
        ? r'\\?\' + p.join(base, 'codex')
        : p.join(base, 'codex');
    final search = ClaudeConversationSearch(
      configDir: base,
      codexHome: prefixedCodex,
    );

    final initial = await search.search('Alpha milestone');
    expect(initial, hasLength(1));
    expect(initial.single.sessionId, 'abcdef12-3456-7890-abcd-ef1234567890');

    codexFile.writeAsStringSync(
      '${jsonEncode({'type': 'event_msg', 'payload': {'type': 'user_message', 'message': 'Beta milestone token'}})}\n',
    );
    codexFile.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 2)));
    expect(await search.search('Alpha milestone'), isEmpty);
    expect(
      (await search.search('Beta milestone')).single.sessionId,
      'abcdef12-3456-7890-abcd-ef1234567890',
    );
  });

  test('preserves HTML/XML in agy USER_REQUEST, skips agy thinking/tool blocks, and avoids splitting UTF-16 surrogates', () async {
    final homeDir = p.join(temp.path, 'home');
    final agyTranscript = File(
      p.join(
        homeDir,
        '.gemini',
        'antigravity-cli',
        'brain',
        'agy-html-1',
        '.system_generated',
        'logs',
        'transcript.jsonl',
      ),
    )..parent.createSync(recursive: true);
    agyTranscript.writeAsStringSync([
      // D-01: User prompt starting with HTML tag inside <USER_REQUEST>
      jsonEncode({
        'type': 'USER_INPUT',
        'content':
            '<USER_REQUEST>\n<div class="card">html_user_prompt</div>\n</USER_REQUEST>',
      }),
      // Standalone wrapper outside <USER_REQUEST> is still filtered
      jsonEncode({
        'type': 'USER_INPUT',
        'content': '<command-name>/clear</command-name>',
      }),
      // D-02: PLANNER_RESPONSE list blocks with thinking / tool_call / text
      jsonEncode({
        'type': 'PLANNER_RESPONSE',
        'content': [
          {'type': 'thinking', 'text': 'block_thinking_secret'},
          {'type': 'thought', 'text': 'block_thought_secret'},
          {'type': 'reasoning', 'text': 'block_reasoning_secret'},
          {'type': 'tool_call', 'text': 'block_tool_call_secret'},
          {'type': 'tool_use', 'text': 'block_tool_use_secret'},
          {'type': 'tool_result', 'text': 'block_tool_result_secret'},
          {'type': 'function_call', 'text': 'block_fn_call_secret'},
          {'type': 'text', 'text': 'visible_answer_text'},
          {'text': 'untyped_visible_text'},
        ],
      }),
    ].join('\n'));

    final search = ClaudeConversationSearch(
      configDir: p.join(temp.path, 'ayte'),
      homeDir: homeDir,
    );

    // D-01 assertions
    final htmlHits = await search.search('html_user_prompt');
    expect(htmlHits, hasLength(1));
    expect(htmlHits.single.sessionId, 'agy-html-1');
    expect(await search.search('/clear'), isEmpty);

    // D-02 assertions
    expect(await search.search('block_thinking_secret'), isEmpty);
    expect(await search.search('block_thought_secret'), isEmpty);
    expect(await search.search('block_reasoning_secret'), isEmpty);
    expect(await search.search('block_tool_call_secret'), isEmpty);
    expect(await search.search('block_tool_use_secret'), isEmpty);
    expect(await search.search('block_tool_result_secret'), isEmpty);
    expect(await search.search('block_fn_call_secret'), isEmpty);
    expect(await search.search('visible_answer_text'), hasLength(1));
    expect(await search.search('untyped_visible_text'), hasLength(1));

    // D-03 assertions: UTF-16 surrogate pairs straddling `from` and `to` boundaries
    void expectNoUnpairedSurrogates(String s) {
      for (var i = 0; i < s.length; i++) {
        final cu = s.codeUnitAt(i);
        if (cu >= 0xD800 && cu <= 0xDBFF) {
          expect(i + 1, lessThan(s.length), reason: 'trailing high surrogate at $i');
          final next = s.codeUnitAt(i + 1);
          expect(next, inInclusiveRange(0xDC00, 0xDFFF), reason: 'unpaired high surrogate at $i');
          i++;
        } else {
          expect(
            cu < 0xDC00 || cu > 0xDFFF,
            isTrue,
            reason: 'unpaired low surrogate at $i',
          );
        }
      }
    }

    final leadSurrogateText = '${'a' * 31}🚀${'b' * 31}MATCH_ME';
    final leadHit = findIn('id-lead', leadSurrogateText, 'MATCH_ME')!;
    expectNoUnpairedSurrogates(leadHit.snippet);
    expect(
      leadHit.snippet.substring(
        leadHit.matchStart,
        leadHit.matchStart + leadHit.matchLength,
      ),
      'MATCH_ME',
    );

    final tailSurrogateText = 'MATCH_ME${'b' * 95}🚀${'z' * 10}';
    final tailHit = findIn('id-tail', tailSurrogateText, 'MATCH_ME')!;
    expectNoUnpairedSurrogates(tailHit.snippet);
    expect(
      tailHit.snippet.substring(
        tailHit.matchStart,
        tailHit.matchStart + tailHit.matchLength,
      ),
      'MATCH_ME',
    );
  });

  test('zero-arg ClaudeConversationSearch honors ClaudeEnvironment.use overrides without leaking into explicit configDir', () async {
    final envHome = p.join(temp.path, 'env_home');
    final envAyte = p.join(temp.path, 'env_ayte');
    final envCodex = p.join(temp.path, 'env_codex');
    final isolatedConfig = p.join(temp.path, 'isolated');

    File(p.join(envAyte, 'projects', '-p', 'ayte-env.jsonl'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${jsonEncode(user('env_override_needle ayte'))}\n');
    File(p.join(envHome, '.claude', 'projects', '-p', 'claude-env.jsonl'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${jsonEncode(user('env_override_needle claude'))}\n');
    File(p.join(envHome, '.codebuddy', 'projects', '-p', 'cb-env.jsonl'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${jsonEncode(user('env_override_needle codebuddy'))}\n');
    File(
      p.join(
        envHome,
        '.gemini',
        'antigravity-cli',
        'brain',
        'agy-env',
        '.system_generated',
        'logs',
        'transcript.jsonl',
      ),
    )
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${jsonEncode({'type': 'USER_INPUT', 'content': '<USER_REQUEST>env_override_needle agy</USER_REQUEST>'})}\n',
      );
    File(
      p.join(
        envCodex,
        'sessions',
        '2026',
        '11',
        '22',
        'rollout-2026-11-22T10-00-00-cdx-env.jsonl',
      ),
    )
      ..parent.createSync(recursive: true)
      ..writeAsStringSync([
        jsonEncode({
          'type': 'session_meta',
          'payload': {'id': 'cdx-env', 'cwd': envHome},
        }),
        jsonEncode({
          'type': 'event_msg',
          'payload': {'type': 'user_message', 'message': 'env_override_needle codex'},
        }),
      ].join('\n'));
    File(p.join(isolatedConfig, 'projects', '-p', 'only-isolated.jsonl'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${jsonEncode(user('isolated_only_needle'))}\n');

    ClaudeEnvironment.use({
      'HOME': envHome,
      'USERPROFILE': envHome,
      'AYTE_SESSION_DATA_PATH': envAyte,
      'CODEX_HOME': envCodex,
    });
    addTearDown(() => ClaudeEnvironment.use(null));

    final zeroArg = ClaudeConversationSearch();
    final envHits = await zeroArg.search('env_override_needle');
    expect(
      envHits.map((h) => h.sessionId).toSet(),
      containsAll(['ayte-env', 'claude-env', 'cb-env', 'agy-env', 'cdx-env']),
    );

    final isolated = ClaudeConversationSearch(configDir: isolatedConfig);
    expect(await isolated.search('env_override_needle'), isEmpty);
    final isolatedHits = await isolated.search('isolated_only_needle');
    expect(isolatedHits.map((h) => h.sessionId).toList(), ['only-isolated']);
  });

  test('indexes real HTML/JSX user prompts across all 4 kernels while excluding CLI/system XML wrappers', () async {
    final envHome = p.join(temp.path, 'jsx_home');
    final envAyte = p.join(temp.path, 'jsx_ayte');
    final envCodex = p.join(temp.path, 'jsx_codex');

    // 1. Claude session with real HTML/JSX prompts AND CLI/system XML wrappers
    File(p.join(envHome, '.claude', 'projects', '-app', 'claude-jsx.jsonl'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync([
        jsonEncode(user('<div className="hero">HTML_JSX_CLAUDE_NEEDLE</div>')),
        jsonEncode(user('<Button onClick={save}>JSX_CLAUDE_BUTTON</Button>')),
        jsonEncode(user('<UserInfoCard /> JSX_CLAUDE_COMPONENT_NEEDLE')),
        jsonEncode(user('<command-name>/clear</command-name>')),
        jsonEncode(user('<command-message>goal</command-message>\n<command-args>CLI_WRAPPER_SECRET</command-args>')),
        jsonEncode(user('<local-command-stdout>CLI_WRAPPER_SECRET</local-command-stdout>')),
        jsonEncode(user('<local-command-stderr>CLI_WRAPPER_SECRET</local-command-stderr>')),
        jsonEncode(user('<local-command-caveat>CLI_WRAPPER_SECRET</local-command-caveat>')),
        jsonEncode(user('<system-reminder>CLI_WRAPPER_SECRET</system-reminder>')),
        jsonEncode(user('<bash-input>CLI_WRAPPER_SECRET</bash-input>')),
        jsonEncode(user('<bash-stdout>CLI_WRAPPER_SECRET</bash-stdout>')),
        jsonEncode(user('<bash-stderr>CLI_WRAPPER_SECRET</bash-stderr>')),
        jsonEncode(user('<task-notification>CLI_WRAPPER_SECRET</task-notification>')),
        jsonEncode(user('<ide_opened_file>CLI_WRAPPER_SECRET</ide_opened_file>')),
        jsonEncode(user('<ide_selection>CLI_WRAPPER_SECRET</ide_selection>')),
      ].join('\n'));

    // 2. CodeBuddy session with real JSX prompt & wrappers
    File(p.join(envHome, '.codebuddy', 'projects', '-app', 'cb-jsx.jsonl'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync([
        jsonEncode(user('<Button variant="primary">JSX_CODEBUDDY_NEEDLE</Button>')),
        jsonEncode(user('<PermissionsPanel /> JSX_CODEBUDDY_PANEL_NEEDLE')),
        jsonEncode(user('<system-reminder>CLI_WRAPPER_SECRET</system-reminder>')),
        jsonEncode(user('<local-command-caveat>CLI_WRAPPER_SECRET</local-command-caveat>')),
      ].join('\n'));

    // 3. Antigravity unwrapped USER_INPUT (no <USER_REQUEST>) & wrappers
    File(
      p.join(
        envHome,
        '.gemini',
        'antigravity-cli',
        'brain',
        'agy-jsx-raw',
        '.system_generated',
        'logs',
        'transcript.jsonl',
      ),
    )
      ..parent.createSync(recursive: true)
      ..writeAsStringSync([
        jsonEncode({
          'type': 'USER_INPUT',
          'content': '<Button>JSX_AGY_RAW_NEEDLE</Button>',
        }),
        jsonEncode({
          'type': 'USER_INPUT',
          'content': '<App /> JSX_AGY_APP_NEEDLE',
        }),
        jsonEncode({
          'type': 'USER_INPUT',
          'content': '<CONVERSATION_CONTEXT>CLI_WRAPPER_SECRET</CONVERSATION_CONTEXT>',
        }),
        jsonEncode({
          'type': 'USER_INPUT',
          'content': '<user_info>CLI_WRAPPER_SECRET</user_info>',
        }),
        jsonEncode({
          'type': 'USER_INPUT',
          'content': '<user_information>CLI_WRAPPER_SECRET</user_information>',
        }),
        jsonEncode({
          'type': 'USER_INPUT',
          'content': '<command-name>/compact</command-name>',
        }),
      ].join('\n'));

    // 4. Codex rollout with real JSX prompt & Codex/CLI wrappers
    File(
      p.join(
        envCodex,
        'sessions',
        '2026',
        '11',
        '22',
        'rollout-2026-11-22T12-00-00-cdx-jsx.jsonl',
      ),
    )
      ..parent.createSync(recursive: true)
      ..writeAsStringSync([
        jsonEncode({
          'type': 'session_meta',
          'payload': {'id': 'cdx-jsx', 'cwd': envHome},
        }),
        jsonEncode({
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': '<environment_context>CLI_WRAPPER_SECRET</environment_context>'},
            ],
          },
        }),
        jsonEncode({
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': '<INSTRUCTIONS>CLI_WRAPPER_SECRET</INSTRUCTIONS>'},
            ],
          },
        }),
        jsonEncode({
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': '<permissions instructions>CLI_WRAPPER_SECRET</permissions instructions>'},
            ],
          },
        }),
        jsonEncode({
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': '<user_instructions>CLI_WRAPPER_SECRET</user_instructions>'},
            ],
          },
        }),
        jsonEncode({
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': '<AGENTS.md instructions>CLI_WRAPPER_SECRET</AGENTS.md instructions>'},
            ],
          },
        }),
        jsonEncode({
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': '<collaboration_mode>CLI_WRAPPER_SECRET</collaboration_mode>'},
            ],
          },
        }),
        jsonEncode({
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': '<skills_instructions>CLI_WRAPPER_SECRET</skills_instructions>'},
            ],
          },
        }),
        jsonEncode({
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': '<turn_aborted>CLI_WRAPPER_SECRET</turn_aborted>'},
            ],
          },
        }),
        jsonEncode({
          'type': 'event_msg',
          'payload': {
            'type': 'user_message',
            'message': '<Button>JSX_CODEX_NEEDLE</Button>',
          },
        }),
        jsonEncode({
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': '<>JSX_CODEX_FRAGMENT_NEEDLE</>'},
            ],
          },
        }),
      ].join('\n'));

    ClaudeEnvironment.use({
      'HOME': envHome,
      'USERPROFILE': envHome,
      'AYTE_SESSION_DATA_PATH': envAyte,
      'CODEX_HOME': envCodex,
    });
    addTearDown(() => ClaudeEnvironment.use(null));

    final search = ClaudeConversationSearch();
    expect((await search.search('HTML_JSX_CLAUDE_NEEDLE')).map((h) => h.sessionId), ['claude-jsx']);
    expect((await search.search('JSX_CLAUDE_BUTTON')).map((h) => h.sessionId), ['claude-jsx']);
    expect((await search.search('JSX_CLAUDE_COMPONENT_NEEDLE')).map((h) => h.sessionId), ['claude-jsx']);
    expect((await search.search('JSX_CODEBUDDY_NEEDLE')).map((h) => h.sessionId), ['cb-jsx']);
    expect((await search.search('JSX_CODEBUDDY_PANEL_NEEDLE')).map((h) => h.sessionId), ['cb-jsx']);
    expect((await search.search('JSX_AGY_RAW_NEEDLE')).map((h) => h.sessionId), ['agy-jsx-raw']);
    expect((await search.search('JSX_AGY_APP_NEEDLE')).map((h) => h.sessionId), ['agy-jsx-raw']);
    expect((await search.search('JSX_CODEX_NEEDLE')).map((h) => h.sessionId), ['cdx-jsx']);
    expect((await search.search('JSX_CODEX_FRAGMENT_NEEDLE')).map((h) => h.sessionId), ['cdx-jsx']);

    expect(await search.search('CLI_WRAPPER_SECRET'), isEmpty);
    expect(await search.search('/clear'), isEmpty);
    expect(await search.search('/compact'), isEmpty);

    // Also verify explicit configDir mode indexes HTML/JSX prompts and drops wrappers.
    final explicitSearch = ClaudeConversationSearch(
      configDir: p.join(envHome, '.claude'),
    );
    expect((await explicitSearch.search('HTML_JSX_CLAUDE_NEEDLE')).map((h) => h.sessionId), ['claude-jsx']);
    expect(await explicitSearch.search('CLI_WRAPPER_SECRET'), isEmpty);
  });

  test('explicit homeDir without configDir isolates all kernels from ambient env overrides', () async {
    final sandboxHome = p.join(temp.path, 'sandbox_home');
    final decoyHome = p.join(temp.path, 'decoy_home');
    final decoyAyte = p.join(temp.path, 'decoy_ayte');
    final decoyClaude = p.join(temp.path, 'decoy_claude');
    final decoyCodex = p.join(temp.path, 'decoy_codex');
    final customCodex = p.join(temp.path, 'custom_codex');
    final customClaude = p.join(temp.path, 'custom_claude');
    final isolatedConfig = p.join(temp.path, 'isolated_cfg');

    void writeClaudeLike(String root, String id, String needle) {
      File(p.join(root, 'projects', '-proj', '$id.jsonl'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(user(needle)));
    }

    void writeAgy(String home, String id, String needle) {
      File(
        p.join(home, '.gemini', 'antigravity-cli', 'brain', id, '.system_generated', 'logs', 'transcript.jsonl'),
      )
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'type': 'USER_INPUT', 'content': needle}));
    }

    void writeCodex(String codexDir, String id, String needle) {
      File(p.join(codexDir, 'sessions', '2026', '11', '22', 'rollout-$id.jsonl'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync([
          jsonEncode({'type': 'session_meta', 'payload': {'id': id, 'cwd': temp.path}}),
          jsonEncode({'type': 'event_msg', 'payload': {'type': 'user_message', 'message': needle}}),
        ].join('\n'));
    }

    // Decoy roots in ambient environment.
    writeClaudeLike(decoyAyte, 'decoy-ayte', 'DECOY_NEEDLE');
    writeClaudeLike(decoyClaude, 'decoy-claude', 'DECOY_NEEDLE');
    writeClaudeLike(p.join(decoyHome, '.codebuddy'), 'decoy-cb', 'DECOY_NEEDLE');
    writeAgy(decoyHome, 'decoy-agy', 'DECOY_NEEDLE');
    writeCodex(decoyCodex, 'decoy-cdx', 'DECOY_NEEDLE');

    // Sandbox home roots.
    writeClaudeLike(p.join(sandboxHome, '.ayte'), 'sb-ayte', 'SANDBOX_HOME_NEEDLE');
    writeClaudeLike(p.join(sandboxHome, '.claude'), 'sb-claude', 'SANDBOX_HOME_NEEDLE');
    writeClaudeLike(p.join(sandboxHome, '.codebuddy'), 'sb-cb', 'SANDBOX_HOME_NEEDLE');
    writeAgy(sandboxHome, 'sb-agy', 'SANDBOX_HOME_NEEDLE');
    writeCodex(p.join(sandboxHome, '.codex'), 'sb-cdx', 'SANDBOX_HOME_NEEDLE');

    // Custom per-kernel overrides and isolated configDir.
    writeCodex(customCodex, 'cust-cdx', 'CUSTOM_CODEX_NEEDLE');
    writeClaudeLike(customClaude, 'cust-claude', 'CUSTOM_CLAUDE_NEEDLE');
    writeClaudeLike(isolatedConfig, 'iso-1', 'ISOLATED_CFG_NEEDLE');

    ClaudeEnvironment.use({
      'HOME': decoyHome,
      'USERPROFILE': decoyHome,
      'AYTE_SESSION_DATA_PATH': decoyAyte,
      'CLAUDE_CONFIG_DIR': decoyClaude,
      'CODEX_HOME': decoyCodex,
    });
    addTearDown(() => ClaudeEnvironment.use(null));

    // 1. Explicit homeDir without configDir indexes all 5 roots under sandboxHome and ignores decoy env.
    final homeOnly = ClaudeConversationSearch(homeDir: sandboxHome);
    final sandboxHits = await homeOnly.search('SANDBOX_HOME_NEEDLE');
    expect(
      sandboxHits.map((h) => h.sessionId).toSet(),
      {'sb-ayte', 'sb-claude', 'sb-cb', 'sb-agy', 'sb-cdx'},
    );
    expect(await homeOnly.search('DECOY_NEEDLE'), isEmpty);

    // 2. Explicit per-kernel overrides take priority over sandboxHome without leaking decoy env.
    final withOverrides = ClaudeConversationSearch(
      homeDir: sandboxHome,
      codexHome: customCodex,
      claudeConfigDir: customClaude,
    );
    expect((await withOverrides.search('CUSTOM_CODEX_NEEDLE')).map((h) => h.sessionId), ['cust-cdx']);
    expect((await withOverrides.search('CUSTOM_CLAUDE_NEEDLE')).map((h) => h.sessionId), ['cust-claude']);
    expect(await withOverrides.search('DECOY_NEEDLE'), isEmpty);

    // 3. Whitespace-only homeDir behaves identically to null when configDir is supplied.
    final whitespaceHome = ClaudeConversationSearch(
      configDir: isolatedConfig,
      homeDir: '   ',
    );
    expect((await whitespaceHome.search('ISOLATED_CFG_NEEDLE')).map((h) => h.sessionId), ['iso-1']);
    expect(await whitespaceHome.search('SANDBOX_HOME_NEEDLE'), isEmpty);
    expect(await whitespaceHome.search('DECOY_NEEDLE'), isEmpty);
  });

  test('resolves Windows mixed-case env vars without falling back to host user dirs on explicit blank keys', () async {
    final isoHome = p.join(temp.path, 'mixed_home');
    final customAyte = p.join(temp.path, 'mixed_ayte');
    final customClaude = p.join(temp.path, 'mixed_claude');
    final customCodex = p.join(temp.path, 'mixed_codex');
    const needle = 'mixed_case_windows_env_needle';

    File(p.join(customAyte, 'projects', '-p', 'sess-ayte.jsonl'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${jsonEncode(user('$needle ayte'))}\n');
    File(p.join(customClaude, 'projects', '-p', 'sess-claude-cfg.jsonl'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${jsonEncode(user('$needle claude_cfg'))}\n');
    File(p.join(isoHome, '.claude', 'projects', '-p', 'sess-claude-home.jsonl'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${jsonEncode(user('$needle claude_home'))}\n');
    File(p.join(isoHome, '.codebuddy', 'projects', '-p', 'sess-cb.jsonl'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${jsonEncode(user('$needle cb'))}\n');
    File(
      p.join(
        isoHome,
        '.gemini',
        'antigravity-cli',
        'brain',
        'sess-agy',
        '.system_generated',
        'logs',
        'transcript.jsonl',
      ),
    )
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${jsonEncode({'type': 'USER_INPUT', 'content': '<USER_REQUEST>$needle agy</USER_REQUEST>'})}\n',
      );
    File(
      p.join(
        customCodex,
        'sessions',
        '2026',
        '11',
        '23',
        'rollout-2026-11-23T01-00-00-sess-codex.jsonl',
      ),
    )
      ..parent.createSync(recursive: true)
      ..writeAsStringSync([
        jsonEncode({
          'type': 'session_meta',
          'payload': {'id': 'sess-codex', 'cwd': isoHome},
        }),
        jsonEncode({
          'type': 'event_msg',
          'payload': {'type': 'user_message', 'message': '$needle codex'},
        }),
      ].join('\n'));

    ClaudeEnvironment.use({
      'Home': isoHome,
      'UserProfile': isoHome,
      'Ayte_Session_Data_Path': customAyte,
      'Claude_Config_Dir': customClaude,
      'Codex_Home': customCodex,
    });
    addTearDown(() => ClaudeEnvironment.use(null));

    final search = ClaudeConversationSearch();
    final hits = await search.search(needle);
    expect(
      hits.map((h) => h.sessionId).toSet(),
      containsAll([
        'sess-ayte',
        'sess-claude-cfg',
        'sess-claude-home',
        'sess-cb',
        'sess-agy',
        'sess-codex',
      ]),
    );

    // Explicit blank mixed-case keys must yield zero roots and never fall back to host Platform.environment.
    ClaudeEnvironment.use({
      'Home': '',
      'UserProfile': '',
      'Ayte_Session_Data_Path': '',
      'Claude_Config_Dir': '',
      'Codex_Home': '',
    });
    final blankSearch = ClaudeConversationSearch();
    expect(await blankSearch.search(needle), isEmpty);
    expect(await blankSearch.search('a'), isEmpty);

    // Blank Codex_Home with valid Home still resolves <Home>/.codex/sessions.
    File(
      p.join(
        isoHome,
        '.codex',
        'sessions',
        '2026',
        '11',
        '23',
        'rollout-2026-11-23T01-00-00-sess-home-codex.jsonl',
      ),
    )
      ..parent.createSync(recursive: true)
      ..writeAsStringSync([
        jsonEncode({
          'type': 'session_meta',
          'payload': {'id': 'sess-home-codex', 'cwd': isoHome},
        }),
        jsonEncode({
          'type': 'event_msg',
          'payload': {'type': 'user_message', 'message': '$needle home_codex'},
        }),
      ].join('\n'));
    ClaudeEnvironment.use({
      'Home': isoHome,
      'UserProfile': isoHome,
      'Codex_Home': '',
    });
    final fallbackCodexSearch = ClaudeConversationSearch();
    expect(
      (await fallbackCodexSearch.search('home_codex')).map((h) => h.sessionId),
      ['sess-home-codex'],
    );
  });
}
