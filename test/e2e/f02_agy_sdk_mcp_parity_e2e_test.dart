import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/commit_attribution.dart';
import 'package:baocode/kernel/extension_switches.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/e2e_env.dart';
import 'helpers/e2e_waiters.dart';
import 'helpers/fake_cli_harness.dart';
import 'helpers/mcp_http_probe.dart';

/// Dart child script for fake `agy` that captures CLI args, env, referenced
/// config files, and stdin lines, and if a loopback HTTP MCP server endpoint
/// (`http://127.0.0.1:...`) is discovered, executes real JSON-RPC calls against it.
const _fakeAgyMcpProbeBody = r'''
Map<String, String> _discoverMcpEndpoint(
  List<String> args,
  Map<String, String> env,
  Map<String, String> configFiles,
) {
  final mcpEnvValues = <String>[
    for (final entry in env.entries)
      if (entry.key.toUpperCase().contains('MCP') ||
          entry.key.toUpperCase().contains('BAOCODE'))
        entry.value,
  ];
  final sources = <String>[
    ...args,
    ...mcpEnvValues,
    ...configFiles.values,
  ];
  final urlRegex = RegExp("https?://127\\.0\\.0\\.1:\\d+[^\\s\"']+");
  final bearerRegex = RegExp(r'Bearer\s+([A-Za-z0-9._~+/=-]+)');
  String? foundUrl;
  String? foundToken;
  for (final src in sources) {
    foundUrl ??= urlRegex.firstMatch(src)?[0];
    foundToken ??= bearerRegex.firstMatch(src)?[1];
  }
  return {
    if (foundUrl != null) 'url': foundUrl,
    if (foundToken != null) 'token': foundToken,
  };
}

Map<String, String> _readConfigFiles(List<String> args, Map<String, String> env) {
  final out = <String, String>{};
  void tryFile(String candidate) {
    final trimmed = candidate.trim();
    if (trimmed.isEmpty || trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return;
    }
    final f = File(trimmed);
    if (f.existsSync()) {
      try {
        out[trimmed] = f.readAsStringSync();
      } on Object {}
    }
  }

  void tryDir(String candidate) {
    final trimmed = candidate.trim();
    if (trimmed.isEmpty) return;
    final dir = Directory(trimmed);
    if (!dir.existsSync()) return;
    final sep = Platform.pathSeparator;
    tryFile('$trimmed${sep}AGENTS.md');
    tryFile('$trimmed$sep.mcp.json');
    tryFile('${trimmed}${sep}mcp_config.json');
    tryFile('$trimmed$sep.agents${sep}mcp_config.json');
  }

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--mcp-config=')) {
      tryFile(a.substring('--mcp-config='.length));
    } else if (a == '--mcp-config' && i + 1 < args.length) {
      tryFile(args[i + 1]);
    } else if (a.startsWith('--settings=')) {
      tryFile(a.substring('--settings='.length));
    } else if (a == '--settings' && i + 1 < args.length) {
      tryFile(args[i + 1]);
    } else if (a.startsWith('--add-dir=')) {
      tryDir(a.substring('--add-dir='.length));
    } else if (a == '--add-dir' && i + 1 < args.length) {
      tryDir(args[i + 1]);
    }
  }
  for (final k in const ['AYTE_MCP_CONFIG', 'MCP_CONFIG', 'AGY_MCP_CONFIG']) {
    if (env[k] case final path?) tryFile(path);
  }
  return out;
}

Future<Map<String, Object?>> _postJsonRpc(
  String url,
  String? token,
  Map<String, Object?> body,
) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..findProxy = (_) => 'DIRECT';
  try {
    final req = await client
        .postUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 12));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
    if (token != null && token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    req.write(jsonEncode(body));
    final resp = await req.close().timeout(const Duration(seconds: 12));
    final raw = await utf8.decoder
        .bind(resp)
        .join()
        .timeout(const Duration(seconds: 12));
    Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException {}
    return {
      'statusCode': resp.statusCode,
      'raw': raw,
      if (parsed != null) 'json': parsed,
    };
  } on Object catch (error, stack) {
    recordEvent({
      'type': 'mcp_rpc_error',
      'method': body['method'],
      'url': url,
      'error': '$error',
      'stack': '$stack',
    });
    return {
      'error': '$error',
      'errorType': '${error.runtimeType}',
      'method': body['method'],
    };
  } finally {
    client.close(force: true);
  }
}

Future<bool> _waitForInitAck(String? ackPath, String mode) async {
  if (ackPath == null || ackPath.isEmpty) return true;
  final ackFile = File(ackPath);
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ackFile.existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      recordEvent({
        'type': 'init_ack_timeout',
        'mode': mode,
        'path': ackPath,
      });
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return true;
}

Future<void> main(List<String> args) async {
  final env = Map<String, String>.from(Platform.environment);
  final configFiles = _readConfigFiles(args, env);
  final discovered = _discoverMcpEndpoint(args, env, configFiles);
  recordEvent({
    'type': 'launch',
    'args': args,
    'env': env,
    'configFiles': configFiles,
    'mcp': discovered,
  });

  final mode = env['FAKE_AGY_MODE'] ?? 'basic';
  final keepAlive = env['FAKE_AGY_KEEP_ALIVE'] == '1';
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  try {
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      recordEvent({'type': 'stdin', 'line': line});
      final url = discovered['url'];
      final token = discovered['token'];

      if (mode == 'pre_init_then_post_init') {
        Map<String, Object?>? preInitResp;
        Map<String, Object?>? postInitResp;
        if (url != null) {
          await _postJsonRpc(url, token, {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': {'protocolVersion': '2024-11-05'},
          });
          preInitResp = await _postJsonRpc(url, token, {
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {'name': 'probe_ctx', 'arguments': {'phase': 'pre'}},
          });
        }
        stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-late-bound'}));
        await stdout.flush();
        final acked = await _waitForInitAck(env['FAKE_AGY_INIT_ACK_FILE'], mode);
        if (url != null && acked) {
          postInitResp = await _postJsonRpc(url, token, {
            'jsonrpc': '2.0',
            'id': 3,
            'method': 'tools/call',
            'params': {'name': 'probe_ctx', 'arguments': {'phase': 'post'}},
          });
        }
        recordEvent({
          'type': 'mcp_probe',
          'pre': preInitResp,
          'post': postInitResp,
          if (!acked) 'initAckTimedOut': true,
        });
        stdout.writeln(jsonEncode({
          'event': 'result',
          'result': {
            'conversation_id': 'conv-late-bound',
            'status': 'SUCCESS',
            'response': 'done',
          },
        }));
        await stdout.flush();
        continue;
      }

      if (mode == 'hold_tool_call') {
        stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-hold'}));
        await stdout.flush();
        if (url != null) {
          unawaited(_postJsonRpc(url, token, {
            'jsonrpc': '2.0',
            'id': 10,
            'method': 'tools/call',
            'params': {'name': 'slow_wait', 'arguments': {}},
          }).then((r) {
            recordEvent({'type': 'slow_call_done', 'resp': r});
          }).catchError((Object e) {
            recordEvent({'type': 'slow_call_error', 'error': '$e'});
          }));
        }
        // Keep process alive until stdin closes / transport closes.
        continue;
      }

      stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-f2-1'}));
      await stdout.flush();
      if (mode == 'mcp_roundtrip') {
        if (url == null) {
          recordEvent({
            'type': 'mcp_url_missing',
            'mode': mode,
            'discovered': discovered,
            'args': args,
          });
        } else {
          final acked = await _waitForInitAck(env['FAKE_AGY_INIT_ACK_FILE'], mode);
          if (!acked) {
            recordEvent({
              'type': 'mcp_probe',
              'initAckTimedOut': true,
            });
          } else {
            final initResp = await _postJsonRpc(url, token, {
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'initialize',
              'params': {'protocolVersion': '2024-11-05'},
            });
            final listResp = await _postJsonRpc(url, token, {
              'jsonrpc': '2.0',
              'id': 2,
              'method': 'tools/list',
              'params': {},
            });
            final callResp = await _postJsonRpc(url, token, {
              'jsonrpc': '2.0',
              'id': 3,
              'method': 'tools/call',
              'params': {'name': 'echo_f2', 'arguments': {'msg': 'ping'}},
            });
            recordEvent({
              'type': 'mcp_probe',
              'initialize': initResp,
              'toolsList': listResp,
              'toolsCall': callResp,
            });
          }
        }
      }
      if (!keepAlive) {
        stdout.writeln(jsonEncode({
          'event': 'result',
          'result': {
            'conversation_id': 'conv-f2-1',
            'status': 'SUCCESS',
            'response': 'ok',
          },
        }));
        await stdout.flush();
      }
    }
  } on Object catch (error, stack) {
    recordEvent({
      'type': 'child_error',
      'mode': mode,
      'error': '$error',
      'stack': '$stack',
    });
    stderr.writeln('fake_agy child error ($mode): $error\n$stack');
    await stderr.flush();
    rethrow;
  }
}
''';

void main() {
  var initAckSeq = 0;

  Future<({List<Map<String, Object?>> messages, Map<String, Object?>? launch})>
  runSingleTurn({
    required E2eSandbox sandbox,
    required FakeCliExecutable fakeAgy,
    required ClaudeLaunch launch,
    Map<String, String> extraEnv = const {},
    String prompt = 'hello',
    bool closeOnResult = true,
    bool expectSuccess = true,
  }) async {
    final initAckFile = File(
      p.join(sandbox.rootDir.path, 'init_ack_${++initAckSeq}.sig'),
    );
    final transport = AntigravityTransport.forTesting(
      executable: fakeAgy.executablePath,
      environment: {
        'FAKE_AGY_INIT_ACK_FILE': initAckFile.path,
        ...sandbox.processEnv,
        ...extraEnv,
      },
      launch: launch,
    );
    final messages = <Map<String, Object?>>[];
    final gotResult = Completer<void>();
    Map<String, Object?>? resultMsg;
    final sub = transport.messages.listen((msg) {
      messages.add(msg);
      if (msg['type'] == 'system' &&
          msg['subtype'] == 'init' &&
          msg['session_id'] is String &&
          (msg['session_id'] as String).isNotEmpty) {
        if (!initAckFile.existsSync()) {
          initAckFile.writeAsStringSync(
            msg['session_id'] as String,
            flush: true,
          );
        }
      }
      if (msg['type'] == 'result' && !gotResult.isCompleted) {
        resultMsg = msg;
        gotResult.complete();
      }
    });

    transport.write({
      'type': 'user',
      'uuid': 'turn-1',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': prompt},
        ],
      },
    });

    try {
      await gotResult.future.timeout(const Duration(seconds: 25));
    } on TimeoutException {
      transport.close();
      await sub.cancel();
      fail(
        'runSingleTurn timed out after 25s.\n'
        'Messages: $messages\n'
        'Captures: ${fakeAgy.readCaptures()}',
      );
    }
    if (closeOnResult) {
      transport.close();
      await transport.exited.timeout(const Duration(seconds: 5));
    } else {
      sandbox.onDispose(() {
        transport.close();
      });
    }
    await sub.cancel();
    if (expectSuccess && resultMsg?['is_error'] == true) {
      fail(
        'runSingleTurn received error result: $resultMsg\n'
        'Messages: $messages\n'
        'Captures: ${fakeAgy.readCaptures()}',
      );
    }
    return (messages: messages, launch: fakeAgy.firstLaunchCapture());
  }

  group('F2 Tier 1 — Loopback SDK MCP Bridge & agy Launch Parity', () {
    test(
      'F2-T1-01: AntigravityTransport exposes loopback HTTP baocode MCP server and initialize returns instructions',
      () async {
        final sandbox = E2eSandbox.create(realHttp: true);
        sandbox.registerSdkTool(
          ClaudeSdkTool(
            name: 'echo_f2',
            description: 'Echoes text',
            inputSchema: const {'type': 'object', 'properties': {}},
            run: (input, call) async => 'echo:${input['msg']}',
          ),
        );
        sandbox.instructSdkFeature('f2_feature', 'Use echo_f2 for testing.');

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f2_01',
          dartBody: _fakeAgyMcpProbeBody,
        );
        final res = await runSingleTurn(
          sandbox: sandbox,
          fakeAgy: fakeAgy,
          extraEnv: const {'FAKE_AGY_MODE': 'mcp_roundtrip'},
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            sdkServers: const ['baocode'],
          ),
        );

        final mcp = res.launch?['mcp'] as Map<String, Object?>?;
        expect(
          mcp?['url'],
          isNotNull,
          reason:
              'AntigravityTransport must pass a loopback HTTP MCP server URL to agy when launch.sdkServers includes baocode',
        );
        final probe = fakeAgy
            .readCaptures()
            .where((e) => e['type'] == 'mcp_probe')
            .firstOrNull;
        final initResp = probe?['initialize'] as Map<String, Object?>?;
        expect(initResp?['error'], isNull, reason: 'initialize RPC error: $initResp');
        expect(initResp?['statusCode'], 200);
        final initResult =
            (initResp?['json'] as Map?)?['result'] as Map<String, Object?>?;
        expect(
          (initResult?['serverInfo'] as Map?)?['name'],
          'baocode',
        );
        expect(initResult?['capabilities'], contains('tools'));
        expect(
          initResult?['instructions'],
          contains('Use echo_f2 for testing.'),
        );
      },
    );

    test(
      'F2-T1-02: tools/list and tools/call pass cwd and bound conversation_id to ClaudeSdkCall',
      () async {
        final sandbox = E2eSandbox.create(realHttp: true);
        ClaudeSdkCall? seenCall;
        sandbox.registerSdkTool(
          ClaudeSdkTool(
            name: 'echo_f2',
            description: 'Echoes text',
            inputSchema: const {
              'type': 'object',
              'properties': {
                'msg': {'type': 'string'},
              },
            },
            run: (input, call) async {
              seenCall = call;
              return 'pong:${input['msg']}';
            },
          ),
        );

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f2_02',
          dartBody: _fakeAgyMcpProbeBody,
        );
        final res = await runSingleTurn(
          sandbox: sandbox,
          fakeAgy: fakeAgy,
          extraEnv: const {'FAKE_AGY_MODE': 'mcp_roundtrip'},
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            sdkServers: const ['baocode'],
          ),
        );

        final captures = fakeAgy.readCaptures();
        final mcp = res.launch?['mcp'] as Map<String, Object?>?;
        expect(
          mcp?['url'],
          isNotNull,
          reason:
              'Expected loopback MCP URL in launch capture: ${res.launch}; captures=$captures',
        );

        final probe = captures
            .where((e) => e['type'] == 'mcp_probe')
            .firstOrNull;
        expect(
          probe,
          isNotNull,
          reason:
              'Expected fake agy to discover and probe loopback MCP URL; captures=$captures; messages=${res.messages}',
        );
        expect(
          (probe!['initialize'] as Map?)?['error'],
          isNull,
          reason: 'initialize RPC error: ${probe['initialize']}',
        );
        expect(
          (probe['toolsList'] as Map?)?['error'],
          isNull,
          reason: 'tools/list RPC error: ${probe['toolsList']}',
        );
        expect(
          (probe['toolsCall'] as Map?)?['error'],
          isNull,
          reason: 'tools/call RPC error: ${probe['toolsCall']}',
        );
        final listJson =
            (probe['toolsList'] as Map?)?['json'] as Map<String, Object?>?;
        final tools = ((listJson?['result'] as Map?)?['tools'] as List? ?? [])
            .whereType<Map>()
            .map((t) => t['name'])
            .toList();
        expect(tools, contains('echo_f2'));

        final callJson =
            (probe['toolsCall'] as Map?)?['json'] as Map<String, Object?>?;
        final content =
            ((callJson?['result'] as Map?)?['content'] as List? ?? []);
        expect(
          content.any((b) => b is Map && b['text'] == 'pong:ping'),
          isTrue,
        );
        expect(seenCall?.cwd, sandbox.projectDir.path);
        expect(seenCall?.sessionId, 'conv-f2-1');
      },
    );

    test(
      'F2-T1-03: launch.instructions and ownPrompt are delivered to agy',
      () async {
        final sandbox = E2eSandbox.create();
        final fakeAgy1 = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f2_03a',
          dartBody: _fakeAgyMcpProbeBody,
        );
        await runSingleTurn(
          sandbox: sandbox,
          fakeAgy: fakeAgy1,
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            instructions: 'PROJECT_RULE_ALPHA',
            ownPrompt: false,
          ),
        );
        final payload1 = jsonEncode(fakeAgy1.readCaptures());
        expect(
          payload1,
          contains('PROJECT_RULE_ALPHA'),
          reason:
              'AntigravityTransport must forward launch.instructions to agy',
        );

        final fakeAgy2 = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f2_03b',
          dartBody: _fakeAgyMcpProbeBody,
        );
        await runSingleTurn(
          sandbox: sandbox,
          fakeAgy: fakeAgy2,
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            instructions: 'BOT_ONLY_PROMPT',
            ownPrompt: true,
          ),
        );
        final payload2 = jsonEncode(fakeAgy2.readCaptures());
        expect(payload2, contains('BOT_ONLY_PROMPT'));
        expect(
          payload2,
          isNot(contains(ClaudeLaunch.appendedSystemPrompt)),
          reason:
              'When launch.ownPrompt is true, default appendedSystemPrompt must not be injected',
        );
      },
    );

    test(
      'F2-T1-04: launch.tools, userServers, allowed, readable and attribution reach agy',
      () async {
        final sandbox = E2eSandbox.create();
        final extraDir = Directory(p.join(sandbox.rootDir.path, 'readable_dir'))
          ..createSync(recursive: true);

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f2_04',
          dartBody: _fakeAgyMcpProbeBody,
        );
        await runSingleTurn(
          sandbox: sandbox,
          fakeAgy: fakeAgy,
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            tools: const ['Read', 'Grep'],
            userServers: false,
            allowed: const ['WebFetch'],
            readable: [extraDir.path],
            attribution: CommitAttribution.baocode,
          ),
        );

        final launchCapture = fakeAgy.firstLaunchCapture();
        expect(launchCapture, isNotNull);
        final configFiles =
            (launchCapture!['configFiles'] as Map?)?.cast<String, Object?>() ??
            const {};
        final agentsMd =
            configFiles.entries
                .where((e) => e.key.endsWith('AGENTS.md'))
                .map((e) => e.value as String?)
                .firstOrNull ??
            '';
        expect(
          agentsMd,
          contains('Restrict built-in tools to: Read, Grep.'),
          reason: 'launch.tools restriction must be written verbatim to AGENTS.md',
        );
        expect(
          agentsMd,
          contains('Do not invoke user-configured MCP servers outside `baocode`.'),
          reason: 'userServers: false directive must reach agy AGENTS.md',
        );
        expect(
          agentsMd,
          contains('Co-Authored-By: Ayte <noreply@ayte.dev>'),
          reason: 'launch.attribution trailer must be written to AGENTS.md',
        );

        final args =
            (launchCapture['args'] as List?)?.whereType<String>().toList() ??
            const <String>[];
        final settingsArg = args.firstWhere(
          (a) => a.startsWith('--settings='),
          orElse: () => '',
        );
        expect(settingsArg, isNotEmpty, reason: '--settings flag must be passed');
        final settings =
            (jsonDecode(settingsArg.substring('--settings='.length)) as Map)
                .cast<String, Object?>();
        final permissions =
            (settings['permissions'] as Map?)?.cast<String, Object?>() ??
            const {};
        final allow =
            (permissions['allow'] as List?)?.whereType<String>().toList() ??
            const <String>[];
        final deny =
            (permissions['deny'] as List?)?.whereType<String>().toList() ??
            const <String>[];
        expect(allow, contains('WebFetch'));
        expect(allow, contains(ClaudeLaunch.readRule(p.normalize(extraDir.path))));
        expect(deny, containsAll(const ['run_command', 'edit_file']));
      },
    );

    test(
      'F2-T1-05: ExtensionSwitches disabledServers, disabledTools and disabledSkills are enforced',
      () async {
        final sandbox = E2eSandbox.create(realHttp: true);
        sandbox.registerSdkTool(
          ClaudeSdkTool(
            name: 'echo_f2',
            description: 'Echoes input for F2 switches check',
            inputSchema: const {'type': 'object', 'properties': {}},
            run: (input, call) async => 'ok',
          ),
        );

        final sk1Dir = Directory(
          p.join(sandbox.projectDir.path, '.agents', 'skills', 'sk1'),
        )..createSync(recursive: true);
        File(p.join(sk1Dir.path, 'SKILL.md')).writeAsStringSync(
          '---\nname: sk1\ndescription: Disabled test skill\n---\nBody',
        );
        final sk2Dir = Directory(
          p.join(sandbox.projectDir.path, '.agents', 'skills', 'sk2'),
        )..createSync(recursive: true);
        File(p.join(sk2Dir.path, 'SKILL.md')).writeAsStringSync(
          '---\nname: sk2\ndescription: Enabled test skill\n---\nBody',
        );

        // Verify disabledSkills end-to-end through ClaudeCodeKernel.commands + AntigravityTransport.
        ExtensionSwitches.current = () =>
            const ExtensionSwitches(disabledSkills: {'sk1'});
        final fakeAgyKernel = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f2_05_kernel',
          dartBody: _fakeAgyMcpProbeBody,
        );
        final kernel = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => AntigravityTransport.forTesting(
            executable: fakeAgyKernel.executablePath,
            environment: sandbox.processEnv,
            launch: launch,
          ),
        );
        sandbox.onDispose(kernel.dispose);
        final kernelDone = Completer<void>();
        final kernelSub = kernel.events.listen((e) {
          if (e is TurnEnded && !kernelDone.isCompleted) kernelDone.complete();
        });
        sandbox.onDispose(() => unawaited(kernelSub.cancel()));
        kernel.send(const KernelTurn(id: 't-skills', text: 'check skills'));
        await kernelDone.future.timeout(const Duration(seconds: 10));
        expect(
          kernel.commands.any((c) => c.name == 'sk2'),
          isTrue,
          reason: 'Enabled skill sk2 must appear in Antigravity kernel commands',
        );
        expect(
          kernel.commands.any((c) => c.name == 'sk1'),
          isFalse,
          reason: 'Disabled skill sk1 must be excluded from Antigravity kernel commands',
        );

        // Verify --settings deny rules + live HTTP AyteSdkMcpBridge enforcement for disabledTools.
        final transportA = AntigravityTransport.forTesting(
          executable: fakeAgyKernel.executablePath,
          environment: sandbox.processEnv,
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            sdkServers: const ['baocode'],
            switches: const ExtensionSwitches(
              disabledServers: {'blocked_srv'},
              disabledTools: {
                'baocode': {'echo_f2'},
                'srv2': {'bad_tool'},
              },
              disabledSkills: {'sk1'},
            ),
          ),
        );
        sandbox.onDispose(transportA.close);
        await transportA.prepareSessionArtifactsForTesting();
        final bridgeA = transportA.sdkBridgeForTesting!;
        final probeA = McpHttpProbe(bridgeA.endpointUri, bearerToken: bridgeA.token);
        final listA = await probeA.toolsList();
        expect(listA.statusCode, 200);
        final toolNamesA =
            ((listA.json?['result'] as Map?)?['tools'] as List? ?? [])
                .whereType<Map>()
                .map((t) => t['name'])
                .toList();
        expect(
          toolNamesA,
          isNot(contains('echo_f2')),
          reason: 'disabledTools must omit echo_f2 from bridge tools/list',
        );
        final callA = await probeA.toolsCall('echo_f2');
        expect(callA.statusCode, 200);
        expect(
          (callA.json?['result'] as Map?)?['isError'],
          isTrue,
          reason: 'disabledTools must reject tools/call for echo_f2',
        );

        // Verify disabledServers: {'baocode'} blocks bridge over HTTP and clears mcp_config.json.
        final transportB = AntigravityTransport.forTesting(
          executable: fakeAgyKernel.executablePath,
          environment: sandbox.processEnv,
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            sdkServers: const ['baocode'],
            switches: const ExtensionSwitches(disabledServers: {'baocode'}),
          ),
        );
        sandbox.onDispose(transportB.close);
        await transportB.prepareSessionArtifactsForTesting();
        final bridgeB = transportB.sdkBridgeForTesting!;
        final probeB = McpHttpProbe(bridgeB.endpointUri, bearerToken: bridgeB.token);
        final listB = await probeB.toolsList();
        expect(listB.statusCode, 200);
        expect(
          ((listB.json?['result'] as Map?)?['tools'] as List? ?? []),
          isEmpty,
          reason: 'disabledServers: {baocode} must return empty tools/list',
        );
        final callB = await probeB.toolsCall('echo_f2');
        expect(callB.statusCode, 200);
        expect((callB.json?['result'] as Map?)?['isError'], isTrue);
        final mcpConfigB = File(
          p.join(
            transportB.sessionConfigDirForTesting!.path,
            '.agents',
            'mcp_config.json',
          ),
        );
        if (mcpConfigB.existsSync()) {
          final parsed = jsonDecode(mcpConfigB.readAsStringSync()) as Map;
          expect((parsed['mcpServers'] as Map?) ?? const {}, isEmpty);
        }

        // Also verify --settings deny rules reach agy CLI args.
        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f2_05',
          dartBody: _fakeAgyMcpProbeBody,
        );
        await runSingleTurn(
          sandbox: sandbox,
          fakeAgy: fakeAgy,
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            switches: const ExtensionSwitches(
              disabledServers: {'blocked_srv'},
              disabledTools: {
                'srv2': {'bad_tool'},
              },
              disabledSkills: {'sk1'},
            ),
          ),
        );

        final allText = jsonEncode(fakeAgy.readCaptures());
        expect(
          allText,
          contains('mcp__blocked_srv'),
          reason: 'ExtensionSwitches disabledServers deny rules must reach agy',
        );
        expect(allText, contains('mcp__srv2__bad_tool'));
      },
    );
  });

  group('F2 Tier 2 — Loopback Bridge Security, Correlation & Lifecycle', () {
    test(
      'F2-T2-01: missing or wrong Bearer token is rejected with HTTP 401 without running tool',
      () async {
        final sandbox = E2eSandbox.create(realHttp: true);
        var ran = false;
        sandbox.registerSdkTool(
          ClaudeSdkTool(
            name: 'guarded_f2',
            description: 'Should not run without valid auth',
            inputSchema: const {'type': 'object', 'properties': {}},
            run: (input, call) async {
              ran = true;
              return 'secret';
            },
          ),
        );

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f2_t2_01',
          dartBody: _fakeAgyMcpProbeBody,
        );
        final transport = AntigravityTransport.forTesting(
          executable: fakeAgy.executablePath,
          environment: {
            ...sandbox.processEnv,
            'FAKE_AGY_KEEP_ALIVE': '1',
          },
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            sdkServers: const ['baocode'],
          ),
        );
        sandbox.onDispose(transport.close);
        transport.write({
          'type': 'user',
          'uuid': 't1',
          'message': {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'hello'},
            ],
          },
        });
        await waitUntil(() => fakeAgy.firstLaunchCapture() != null);
        final mcp = fakeAgy.firstLaunchCapture()!['mcp'] as Map<String, Object?>?;
        final rawUrl = mcp?['url'] as String?;
        expect(
          rawUrl,
          isNotNull,
          reason:
              'Loopback MCP endpoint URL must be passed to agy (received: ${fakeAgy.firstLaunchCapture()})',
        );

        final probe = McpHttpProbe(
          Uri.parse(rawUrl!),
          bearerToken: mcp?['token'] as String?,
        );
        final noAuth = await probe.toolsCall('guarded_f2', const {}, null, true);
        expect(noAuth.statusCode, 401);

        final badAuth = await probe.toolsCall(
          'guarded_f2',
          const {},
          'wrong-token-value',
        );
        expect(badAuth.statusCode, 401);
        expect(ran, isFalse);
      },
    );

    test(
      'F2-T2-02: tools/call before init conversation_id resolves caller and binds after init',
      () async {
        final sandbox = E2eSandbox.create(realHttp: true);
        final phases =
            <({String? phase, String? sessionId, String? turnId, String cwd})>[];
        sandbox.registerSdkTool(
          ClaudeSdkTool(
            name: 'probe_ctx',
            description: 'Captures call context',
            inputSchema: const {'type': 'object', 'properties': {}},
            run: (input, call) async {
              phases.add((
                phase: input['phase'] as String?,
                sessionId: call.sessionId,
                turnId: call.turnId,
                cwd: call.cwd,
              ));
              return 'ok';
            },
          ),
        );

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f2_t2_02',
          dartBody: _fakeAgyMcpProbeBody,
        );
        await runSingleTurn(
          sandbox: sandbox,
          fakeAgy: fakeAgy,
          extraEnv: const {'FAKE_AGY_MODE': 'pre_init_then_post_init'},
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            sdkServers: const ['baocode'],
          ),
        );

        expect(
          phases,
          hasLength(2),
          reason: 'Both pre-init and post-init MCP tool calls must succeed',
        );
        expect(phases[0].phase, 'pre');
        expect(phases[0].sessionId, isNull);
        expect(phases[0].turnId, 'turn-1');
        expect(phases[0].cwd, sandbox.projectDir.path);
        expect(phases[1].phase, 'post');
        expect(phases[1].sessionId, 'conv-late-bound');
        expect(phases[1].turnId, 'turn-1');
      },
    );

    test(
      'F2-T2-03: ClaudeSdkGate denial hides tool and sdkServers=[] omits baocode bridge',
      () async {
        final sandbox = E2eSandbox.create(realHttp: true);
        sandbox.registerSdkTool(
          ClaudeSdkTool(
            name: 'secret_tool',
            description: 'Gated tool',
            inputSchema: const {'type': 'object', 'properties': {}},
            run: (input, call) async => 'hidden',
          ),
        );
        ClaudeSdkTools.gate = _DenyingGate(const {'secret_tool'});

        final fakeAgyEmpty = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f2_t2_03a',
          dartBody: _fakeAgyMcpProbeBody,
        );
        await runSingleTurn(
          sandbox: sandbox,
          fakeAgy: fakeAgyEmpty,
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            sdkServers: const [],
          ),
        );
        final emptyMcp = fakeAgyEmpty.firstLaunchCapture()?['mcp'] as Map?;
        expect(emptyMcp?['url'], isNull);

        final fakeAgyGated = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f2_t2_03b',
          dartBody: _fakeAgyMcpProbeBody,
        );
        final transport = AntigravityTransport.forTesting(
          executable: fakeAgyGated.executablePath,
          environment: {
            ...sandbox.processEnv,
            'FAKE_AGY_KEEP_ALIVE': '1',
          },
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            sdkServers: const ['baocode'],
          ),
        );
        sandbox.onDispose(transport.close);
        transport.write({
          'type': 'user',
          'uuid': 't1',
          'message': {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'hi'},
            ],
          },
        });
        await waitUntil(() => fakeAgyGated.firstLaunchCapture() != null);
        final mcp = fakeAgyGated.firstLaunchCapture()!['mcp'] as Map?;
        final url = mcp?['url'] as String?;
        expect(
          url,
          isNotNull,
          reason: 'Bridge endpoint must be provided when sdkServers=[baocode]',
        );

        final probe = McpHttpProbe(
          Uri.parse(url!),
          bearerToken: mcp?['token'] as String?,
        );
        final listResp = await probe.toolsList();
        expect(listResp.statusCode, 200);
        final listed =
            ((listResp.json?['result'] as Map?)?['tools'] as List? ?? [])
                .whereType<Map>()
                .map((t) => t['name'])
                .toList();
        expect(listed, isNot(contains('secret_tool')));

        final callResp = await probe.toolsCall('secret_tool');
        expect(callResp.statusCode, 200);
        expect((callResp.json?['result'] as Map?)?['isError'], isTrue);
      },
    );

    test(
      'F2-T2-04: malformed JSON, unknown JSON-RPC method and GET HTTP return clean error responses',
      () async {
        final sandbox = E2eSandbox.create(realHttp: true);
        sandbox.registerSdkTool(
          ClaudeSdkTool(
            name: 'ping_tool',
            description: 'Ping',
            inputSchema: const {'type': 'object', 'properties': {}},
            run: (input, call) async => 'pong',
          ),
        );

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f2_t2_04',
          dartBody: _fakeAgyMcpProbeBody,
        );
        final transport = AntigravityTransport.forTesting(
          executable: fakeAgy.executablePath,
          environment: {
            ...sandbox.processEnv,
            'FAKE_AGY_KEEP_ALIVE': '1',
          },
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            sdkServers: const ['baocode'],
          ),
        );
        sandbox.onDispose(transport.close);
        transport.write({
          'type': 'user',
          'uuid': 't1',
          'message': {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'hi'},
            ],
          },
        });
        await waitUntil(() => fakeAgy.firstLaunchCapture() != null);
        final mcp = fakeAgy.firstLaunchCapture()!['mcp'] as Map?;
        final url = mcp?['url'] as String?;
        expect(
          url,
          isNotNull,
          reason: 'Bridge endpoint must be provided when sdkServers=[baocode]',
        );

        final probe = McpHttpProbe(
          Uri.parse(url!),
          bearerToken: mcp?['token'] as String?,
        );
        final badJson = await probe.postRaw('{not valid json');
        expect(badJson.statusCode, anyOf(400, 200));
        if (badJson.json case final json?) {
          expect((json['error'] as Map?)?['code'], -32700);
        }

        final unknownMethod = await probe.postJsonRpc({
          'jsonrpc': '2.0',
          'id': 9,
          'method': 'unknown/foo',
        });
        expect(unknownMethod.statusCode, 200);
        expect((unknownMethod.json?['error'] as Map?)?['code'], -32601);

        final getResp = await probe.requestMethod('GET');
        expect(getResp.statusCode, HttpStatus.methodNotAllowed);
        expect(getResp.headers['allow'], contains('POST'));
      },
    );

    test(
      'F2-T2-05: closing transport cancels active SDK tool call and closes loopback socket',
      () async {
        final sandbox = E2eSandbox.create(realHttp: true);
        final toolStarted = Completer<void>();
        final toolCancelled = Completer<void>();
        sandbox.registerSdkTool(
          ClaudeSdkTool(
            name: 'slow_wait',
            description: 'Waits for cancellation',
            inputSchema: const {'type': 'object', 'properties': {}},
            run: (input, call) async {
              if (!toolStarted.isCompleted) toolStarted.complete();
              await call.cancelled;
              if (!toolCancelled.isCompleted) toolCancelled.complete();
              return 'cancelled';
            },
          ),
        );

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f2_t2_05',
          dartBody: _fakeAgyMcpProbeBody,
        );
        final kernel = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => AntigravityTransport.forTesting(
            executable: fakeAgy.executablePath,
            environment: {
              ...sandbox.processEnv,
              'FAKE_AGY_MODE': 'hold_tool_call',
            },
            launch: launch,
          ),
        );
        sandbox.onDispose(kernel.dispose);

        kernel.send(const KernelTurn(id: 'turn-1', text: 'run slow tool'));
        await waitUntil(() => fakeAgy.firstLaunchCapture() != null);
        final mcp = fakeAgy.firstLaunchCapture()!['mcp'] as Map?;
        final url = mcp?['url'] as String?;
        expect(
          url,
          isNotNull,
          reason: 'Loopback bridge must start so slow_wait can execute',
        );

        await toolStarted.future.timeout(const Duration(seconds: 5));
        kernel.dispose();

        await toolCancelled.future.timeout(const Duration(seconds: 5));
        final probe = McpHttpProbe(
          Uri.parse(url!),
          bearerToken: mcp?['token'] as String?,
        );
        await waitUntilAsync(
          () async {
            try {
              await probe.ping();
              return false;
            } on SocketException {
              return true;
            }
          },
          timeout: const Duration(seconds: 5),
          reason: 'Loopback MCP bridge socket must close after kernel.dispose()',
        );
      },
    );
  });
}

class _DenyingGate implements ClaudeSdkGate {
  const _DenyingGate(this.denied);

  final Set<String> denied;

  @override
  bool asksUser(String cwd) => true;

  @override
  bool offersTool(String cwd, String tool) => !denied.contains(tool);

  @override
  bool tellsFeature(String cwd, String feature) => true;
}
