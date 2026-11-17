import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart';

import '../../chat/chat_models.dart' show ImageAttachment;
import '../../models/launch_environment.dart';
import '../../network/network_proxy_io.dart';
import '../../network/tls.dart';
import '../../usage/usage_ledger.dart';
import '../antigravity/antigravity_cli.dart';
import 'claude_core_setting.dart';
import 'claude_environment.dart';
import 'claude_haiku.dart';

/// `claude -p --model haiku`: the prompt on stdin, one JSON result on
/// stdout. No tools, MCP servers or slash commands, and no session kept;
/// run outside the project so that its CLAUDE.md is not read.
///
/// On a provider: [model] of it, [env] its environment, given as flag
/// settings in a file (it holds the key), as a session's are. [images] go
/// with the prompt, as a stream-json message, whose answer streams.
///
/// Claude's own (no [env]: not through the proxy) is kept here, as the
/// proxy keeps a provider's: under [session].
Future<String> askClaudeHaiku(
  String system,
  String prompt, {
  Future<void>? cancel,
  String? model,
  Map<String, String>? env,
  List<({String name, ImageAttachment image})> images = const [],
  ClaudeHaikuTools? tools,
  String? session,
}) async {
  void kept(String line) {
    if (env != null || !line.contains('"result"')) return;
    try {
      if (jsonDecode(line) case {'type': 'result'} && final Map result) {
        final call = claudeHaikuCall(
          result.cast<String, Object?>(),
          at: DateTime.now(),
          session: session,
        );
        if (call != null) UsageLedger.current.record(call);
      }
    } on FormatException {
      // Not a message.
    }
  }

  if (images.isNotEmpty) {
    final timer = ClaudeAnswerTimer();
    final clock = Stopwatch()..start();
    final (stderr, code) = await _run(
      system,
      // One line.
      '${claudeHaikuMessage(prompt, images)}\n',
      cancel: cancel,
      model: model,
      env: env,
      stream: true,
      message: true,
      tools: tools,
      onLine: (line) {
        timer.add(line, clock.elapsed);
        kept(line);
      },
    );
    return timer.answer(stderr, code).text;
  }
  final stdout = StringBuffer();
  final (stderr, code) = await _run(
    system,
    prompt,
    cancel: cancel,
    model: model,
    env: env,
    tools: tools,
    stream: false,
    onLine: (line) {
      stdout.writeln(line);
      kept(line);
    },
  );
  return claudeHaikuAnswer(stdout.toString(), stderr, code);
}

/// As [askClaudeHaiku], its answer streamed and timed.
Future<ClaudeTimedAnswer> timeClaudeAnswer(
  String system,
  String prompt, {
  Future<void>? cancel,
  String? model,
  Map<String, String>? env,
}) async {
  final timer = ClaudeAnswerTimer();
  final clock = Stopwatch();
  final (stderr, code) = await _run(
    system,
    prompt,
    cancel: cancel,
    model: model,
    env: env,
    stream: true,
    onStart: clock.start,
    onLine: (line) => timer.add(line, clock.elapsed),
  );
  return timer.answer(stderr, code);
}

/// Runs Claude Code, giving each line it prints to [onLine]: what it
/// wrote to stderr and exited with.
Future<(String, int)> _run(
  String system,
  String prompt, {
  required Future<void>? cancel,
  required String? model,
  required Map<String, String>? env,
  required bool stream,
  required void Function(String line) onLine,
  bool message = false,
  ClaudeHaikuTools? tools,
  void Function()? onStart,
}) async {
  if (env != null || ClaudeCore.current() == ClaudeCore.builtin) {
    return _runBuiltin(
      system,
      prompt,
      cancel: cancel,
      model: model,
      env: env,
      stream: stream,
      message: message,
      tools: tools,
      onLine: onLine,
      onStart: onStart,
    );
  }
  final cli = await LocalAntigravity.locate();
  final proxy = await NetworkProxy.instance.environment();
  final certificates = await nodeCertificatesEnvironment(cli.environment);
  final combinedPrompt = system.trim().isEmpty
      ? prompt
      : 'System instruction: $system\n\n$prompt';
  final Process process;
  try {
    process = await Process.start(
      cli.executable,
      [
        '--print',
        '--disable-slash-commands',
        '--dangerously-skip-permissions',
        '--output-format',
        'json',
        '--model',
        AntigravityModels.bareModelId(model ?? 'gemini-3.8-flash-low'),
        combinedPrompt,
      ],
      workingDirectory: switch (tools?.directory) {
        final directory? when Directory(directory).existsSync() => directory,
        _ => Directory.systemTemp.path,
      },
      environment: {
        ...cli.environment,
        ...proxy,
        ...certificates,
      },
      includeParentEnvironment: Platform.isWindows,
    );
  } on ProcessException catch (error) {
    throw ClaudeHaikuException('Antigravity CLI could not start: ${error.message}');
  }
  onStart?.call();
  unawaited(process.stdin.close().catchError((Object _) {}));
  var cancelled = false;
  unawaited(
    cancel?.then((_) {
      cancelled = true;
      process.kill();
    }),
  );
  final stdoutLines = <String>[];
  final stdout = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .forEach(stdoutLines.add);
  final stderr = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final code = await process.exitCode.timeout(
    Duration(minutes: tools == null ? 2 : 5),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      throw const ClaudeHaikuException('Antigravity CLI took too long to answer.');
    },
  );
  if (cancelled) throw const ClaudeHaikuCancelled();
  await stdout;
  for (final raw in stdoutLines) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('{')) continue;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map && decoded['response'] is String) {
        onLine(
          jsonEncode({
            'type': 'result',
            'subtype': 'success',
            'is_error': decoded['status'] == 'ERROR',
            'result': decoded['response'],
            if (decoded['usage'] is Map) 'usage': decoded['usage'],
          }),
        );
      } else {
        onLine(trimmed);
      }
    } on FormatException {
      onLine(trimmed);
    }
  }
  return (await stderr, code);
}

/// [_run] on BaoCode's own core: one turn of an engine in an isolate of its
/// own, set up as [claudeHaikuArguments] sets up the CLI, its messages
/// given to [onLine] as the CLI prints them (only its result, unless
/// [stream] or [message]).
Future<(String, int)> _runBuiltin(
  String system,
  String prompt, {
  required Future<void>? cancel,
  required String? model,
  required Map<String, String>? env,
  required bool stream,
  required bool message,
  required ClaudeHaikuTools? tools,
  required void Function(String line) onLine,
  void Function()? onStart,
}) async {
  final base = await ClaudeEnvironment.of();
  final proxy = await NetworkProxy.instance.environment();
  final environment = <String, String>{...base, ...proxy};
  if (env != null) {
    for (final name in ClaudeModelVariables.inherited) {
      environment.remove(name);
    }
  }
  environment.addAll(ClaudeEnvironment.stateDirectory(base));
  final options = EngineOptions(
    // Elsewhere than a project, unless it is to look at one.
    cwd: switch (tools?.directory) {
      final directory? when Directory(directory).existsSync() => directory,
      _ => Directory.systemTemp.resolveSymbolicLinksSync(),
    },
    model: model ?? 'haiku',
    // Nothing asked: what is not allowed is refused.
    permissionMode: 'dontAsk',
    persist: false,
    flagSettings: {
      'env': ?env,
      if (env != null && model != null)
        'availableModels': allowedModels(env, [model]),
      ...?tools?.settings,
    },
    environment: environment,
    systemPrompt: system,
    tools: tools?.tools ?? const [],
    maxTurns: tools?.maxTurns,
    strictMcpConfig: true,
    slashCommands: false,
  );
  final AgentIsolate agent;
  try {
    agent = await AgentIsolate.spawn(options, debugName: 'bao-agent-haiku');
  } on Object catch (error) {
    throw ClaudeHaikuException('The built-in core could not start: $error');
  }
  onStart?.call();
  final ended = Completer<int>();
  final subscription = agent.messages.listen(
    (line) {
      final isResult = line['type'] == 'result';
      if (stream || message || isResult) onLine(jsonEncode(line));
      if (isResult && !ended.isCompleted) {
        ended.complete(line['is_error'] == true ? 1 : 0);
      }
    },
    onDone: () {
      if (!ended.isCompleted) ended.complete(1);
    },
  );
  var cancelled = false;
  unawaited(
    cancel?.then((_) {
      cancelled = true;
      if (!ended.isCompleted) ended.complete(130);
    }),
  );
  agent.write(
    message
        ? (jsonDecode(prompt.trim()) as Map).cast<String, Object?>()
        : {
            'type': 'user',
            'message': {'role': 'user', 'content': prompt},
          },
  );
  try {
    final code = await ended.future.timeout(
      Duration(minutes: tools == null ? 2 : 5),
      onTimeout: () => throw const ClaudeHaikuException(
        'Claude Code took too long to answer.',
      ),
    );
    if (cancelled) throw const ClaudeHaikuCancelled();
    return (agent.errors.join('\n'), code);
  } finally {
    unawaited(subscription.cancel());
    agent.close();
  }
}
