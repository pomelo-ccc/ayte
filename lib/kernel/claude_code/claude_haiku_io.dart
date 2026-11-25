import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart';
import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart' show ImageAttachment;
import '../../models/launch_environment.dart';
import '../../models/model_provider.dart' show parseModelRef;
import '../../network/network_proxy_io.dart';
import '../../network/tls.dart';
import '../../usage/usage_ledger.dart';
import '../antigravity/antigravity_cli.dart';
import '../codebuddy/codebuddy_accounts.dart';
import '../codebuddy/codebuddy_cli.dart';
import '../codex/codex_process_transport.dart';
import '../kernel_registry.dart' show claudeCodeKernelId, codexKernelId;
import 'claude_cli_transport.dart';
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

/// Extracts plain text blocks when [prompt] is a `claudeHaikuMessage` JSON line.
String _extractPromptText(String prompt, {required bool message}) {
  if (!message) return prompt;
  try {
    if (jsonDecode(prompt.trim()) case {
      'message': {'content': final List content},
    }) {
      final texts = [
        for (final item in content)
          if (item case {'type': 'text', 'text': final String t}) t,
      ];
      if (texts.isNotEmpty) return texts.join('\n\n');
    }
  } on FormatException {
    // Keep prompt as-is.
  }
  return prompt;
}

/// Runs the appropriate single-shot backend for [model]/[env], giving each line
/// it prints to [onLine]: what it wrote to stderr and exited with.
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
  if (env != null) {
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
  final ref = parseModelRef(model);
  if (ref?.provider == codebuddyBuiltinProviderId) {
    return _runCodeBuddy(
      system,
      prompt,
      cancel: cancel,
      model: model,
      message: message,
      tools: tools,
      onLine: onLine,
      onStart: onStart,
    );
  }
  if (ref?.provider == claudeCodeKernelId) {
    return _runClaudeCli(
      system,
      prompt,
      cancel: cancel,
      model: ref!.model,
      message: message,
      tools: tools,
      onLine: onLine,
      onStart: onStart,
    );
  }
  if (ref?.provider == codexKernelId) {
    return _runCodexCli(
      system,
      prompt,
      cancel: cancel,
      model: ref!.model,
      message: message,
      tools: tools,
      onLine: onLine,
      onStart: onStart,
    );
  }
  if (ref?.provider == antigravityBuiltinProviderId) {
    return _runAntigravity(
      system,
      prompt,
      cancel: cancel,
      model: model,
      message: message,
      tools: tools,
      onLine: onLine,
      onStart: onStart,
    );
  }
  if (ClaudeCore.current() == ClaudeCore.builtin) {
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
  return _runAntigravity(
    system,
    prompt,
    cancel: cancel,
    model: model,
    message: message,
    tools: tools,
    onLine: onLine,
    onStart: onStart,
  );
}

Future<(String, int)> _runAntigravity(
  String system,
  String prompt, {
  required Future<void>? cancel,
  required String? model,
  required bool message,
  required ClaudeHaikuTools? tools,
  required void Function(String line) onLine,
  void Function()? onStart,
}) async {
  final cli = await LocalAntigravity.locate();
  final proxy = await NetworkProxy.instance.environment();
  final certificates = await nodeCertificatesEnvironment(cli.environment);
  final effectivePrompt = _extractPromptText(prompt, message: message);
  final combinedPrompt = system.trim().isEmpty
      ? effectivePrompt
      : 'System instruction: $system\n\n$effectivePrompt';
  final parsed = AntigravityModels.parseVariant(
    model ?? 'gemini-3.8-flash-low',
  );
  final cliModel =
      parsed?.model.effectiveCliModel ??
      AntigravityModels.cliModelIdOf(model ?? 'gemini-3.8-flash');
  final cliEffort =
      parsed?.effort ??
      (parsed?.model.effortLevels.contains('low') == true ? 'low' : null);
  final childEnv = <String, String>{
    ...cli.environment,
    ...proxy,
    ...certificates,
  };
  final Process process;
  try {
    process = await Process.start(
      cli.executable,
      [
        '--disable-slash-commands',
        '--dangerously-skip-permissions',
        '--output-format=json',
        '--model=$cliModel',
        if (cliEffort != null) '--effort=$cliEffort',
        '--print=$combinedPrompt',
      ],
      workingDirectory: switch (tools?.directory) {
        final directory? when Directory(directory).existsSync() => directory,
        _ => Directory.systemTemp.path,
      },
      environment: childEnv,
      includeParentEnvironment: Platform.isWindows,
    );
  } on ProcessException catch (error) {
    throw ClaudeHaikuException(
      'Antigravity CLI could not start: ${error.message}',
    );
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

  bool emitDecoded(Object? decoded) {
    if (decoded is! Map) return false;
    if (decoded['conversation_id'] case final String convId
        when convId.isNotEmpty) {
      _cleanupEphemeralAgyConversation(convId, childEnv);
    }
    if (decoded['response'] case final String response) {
      onLine(
        jsonEncode({
          'type': 'result',
          'subtype': 'success',
          'is_error': decoded['status'] == 'ERROR',
          'result': response,
          if (decoded['usage'] is Map) 'usage': decoded['usage'],
        }),
      );
      return true;
    }
    return false;
  }

  var matched = false;
  for (final raw in stdoutLines) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('{')) continue;
    try {
      if (emitDecoded(jsonDecode(trimmed))) {
        matched = true;
      } else {
        onLine(trimmed);
      }
    } on FormatException {
      // May be multi-line JSON; handled below.
    }
  }
  if (!matched && stdoutLines.isNotEmpty) {
    final joined = stdoutLines.join('\n').trim();
    final braceStart = joined.indexOf('{');
    if (braceStart >= 0) {
      try {
        matched = emitDecoded(jsonDecode(joined.substring(braceStart)));
      } on FormatException {
        // Leave raw lines below.
      }
    }
    if (!matched) {
      for (final raw in stdoutLines) {
        onLine(raw);
      }
    }
  }
  return (await stderr, code);
}

Future<(String, int)> _runCodeBuddy(
  String system,
  String prompt, {
  required Future<void>? cancel,
  required String? model,
  required bool message,
  required ClaudeHaikuTools? tools,
  required void Function(String line) onLine,
  void Function()? onStart,
}) async {
  await CodeBuddyAccounts.instance.ensureInitialized();
  var activeAccount = CodeBuddyAccounts.instance.currentAccount;
  if (activeAccount != null) {
    activeAccount = await CodeBuddyAccounts.instance.ensureFreshAccount(
      activeAccount,
    );
  }
  final accountEnv = activeAccount?.processEnvironment() ?? const <String, String>{};
  final cli = await LocalCodeBuddy.locate();
  final proxy = await NetworkProxy.instance.environment();
  final certificates = await nodeCertificatesEnvironment(cli.environment);
  final effectivePrompt = _extractPromptText(prompt, message: message);
  final cliModel = CodeBuddyModels.cliModelIdOf(model);
  final childEnv = <String, String>{
    ...cli.environment,
    ...proxy,
    ...certificates,
    ...accountEnv,
    ...ClaudeEnvironment.stateDirectory(cli.environment),
  };
  final args = <String>[
    '-p',
    if (cliModel.isNotEmpty && cliModel != 'default') ...['--model', cliModel],
    '--output-format',
    'json',
    '--no-session-persistence',
    '--strict-mcp-config',
    '--tools',
    '',
    if (system.trim().isNotEmpty) ...['--system-prompt', system],
  ];
  final Process process;
  try {
    process = await Process.start(
      cli.executable,
      args,
      workingDirectory: switch (tools?.directory) {
        final directory? when Directory(directory).existsSync() => directory,
        _ => Directory.systemTemp.path,
      },
      environment: childEnv,
      includeParentEnvironment: Platform.isWindows,
      runInShell: cli.throughShell,
    );
  } on ProcessException catch (error) {
    throw ClaudeHaikuException('CodeBuddy CLI could not start: ${error.message}');
  }
  onStart?.call();
  try {
    process.stdin.write(effectivePrompt);
    await process.stdin.close();
  } on Object {
    // Process may have exited early; exit code & stderr will report why.
  }
  var cancelled = false;
  unawaited(
    cancel?.then((_) {
      cancelled = true;
      process.kill();
    }),
  );
  final stdout = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .forEach(onLine);
  final stderr = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final code = await process.exitCode.timeout(
    Duration(minutes: tools == null ? 2 : 5),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      throw const ClaudeHaikuException('CodeBuddy CLI took too long to answer.');
    },
  );
  if (cancelled) throw const ClaudeHaikuCancelled();
  await stdout;
  return (await stderr, code);
}

Future<(String, int)> _runClaudeCli(
  String system,
  String prompt, {
  required Future<void>? cancel,
  required String model,
  required bool message,
  required ClaudeHaikuTools? tools,
  required void Function(String line) onLine,
  void Function()? onStart,
}) async {
  final base = await ClaudeEnvironment.of();
  final proxy = await NetworkProxy.instance.environment();
  final combined = <String, String>{...base, ...proxy};
  final env = ClaudeCliTransport.enrichEnvironment(combined);
  final executable = ClaudeCliTransport.locateExecutable(env);
  if (executable == null) {
    throw const ClaudeHaikuException('未检测到 Claude Code CLI (claude)');
  }
  final effectivePrompt = _extractPromptText(prompt, message: message);
  final cliModel = model.trim();
  final args = <String>[
    '-p',
    if (cliModel.isNotEmpty && cliModel != 'default') ...['--model', cliModel],
    '--output-format',
    'json',
    '--no-session-persistence',
    '--strict-mcp-config',
    '--disable-slash-commands',
    '--tools',
    '',
    if (system.trim().isNotEmpty) ...['--system-prompt', system],
  ];
  final Process process;
  try {
    process = await Process.start(
      executable,
      args,
      workingDirectory: switch (tools?.directory) {
        final directory? when Directory(directory).existsSync() => directory,
        _ => Directory.systemTemp.path,
      },
      environment: env,
      includeParentEnvironment: false,
    );
  } on ProcessException catch (error) {
    throw ClaudeHaikuException('Claude Code CLI could not start: ${error.message}');
  }
  onStart?.call();
  try {
    process.stdin.write(effectivePrompt);
    await process.stdin.close();
  } on Object {
    // Process may have exited early; exit code & stderr will report why.
  }
  var cancelled = false;
  unawaited(
    cancel?.then((_) {
      cancelled = true;
      process.kill();
    }),
  );
  final stdout = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .forEach(onLine);
  final stderr = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final code = await process.exitCode.timeout(
    Duration(minutes: tools == null ? 2 : 5),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      throw const ClaudeHaikuException('Claude Code CLI took too long to answer.');
    },
  );
  if (cancelled) throw const ClaudeHaikuCancelled();
  await stdout;
  return (await stderr, code);
}

Future<(String, int)> _runCodexCli(
  String system,
  String prompt, {
  required Future<void>? cancel,
  required String model,
  required bool message,
  required ClaudeHaikuTools? tools,
  required void Function(String line) onLine,
  void Function()? onStart,
}) async {
  final base = await ClaudeEnvironment.of();
  final proxy = await NetworkProxy.instance.environment();
  final env = ProcessCodexTransport.enrichedPath({...base, ...proxy});
  final binary = ProcessCodexTransport.locateCodex(env);
  if (binary == null) {
    throw const ClaudeHaikuException('未检测到 Codex CLI (codex)');
  }
  final effectivePrompt = _extractPromptText(prompt, message: message);
  final combinedPrompt = system.trim().isEmpty
      ? effectivePrompt
      : 'System instruction: $system\n\n$effectivePrompt';
  final cliModel = model.trim();
  final outFile = File(
    p.join(
      Directory.systemTemp.path,
      'ayte-codex-pk-${DateTime.now().microsecondsSinceEpoch}-$pid.txt',
    ),
  );
  final args = <String>[
    'exec',
    '--ephemeral',
    '--skip-git-repo-check',
    '--sandbox',
    'read-only',
    '--color',
    'never',
    if (cliModel.isNotEmpty && cliModel != 'default') ...['-m', cliModel],
    '-o',
    outFile.path,
    '-',
  ];
  final launch = ProcessCodexTransport.resolveLaunch(
    binary,
    env,
    appServerArgs: args,
  );
  try {
    final Process process;
    try {
      process = await Process.start(
        launch.executable,
        launch.arguments,
        workingDirectory: switch (tools?.directory) {
          final directory? when Directory(directory).existsSync() => directory,
          _ => Directory.systemTemp.path,
        },
        environment: env,
        includeParentEnvironment: false,
        runInShell: launch.runInShell,
      );
    } on ProcessException catch (error) {
      throw ClaudeHaikuException('Codex CLI could not start: ${error.message}');
    }
    onStart?.call();
    try {
      process.stdin.write(combinedPrompt);
      await process.stdin.close();
    } on Object {
      // Process may have exited early; exit code & stderr will report why.
    }
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
        throw const ClaudeHaikuException('Codex CLI took too long to answer.');
      },
    );
    if (cancelled) throw const ClaudeHaikuCancelled();
    await stdout;
    var text = '';
    if (await outFile.exists()) {
      text = (await outFile.readAsString()).trim();
    }
    if (text.isEmpty && code == 0) {
      text = stdoutLines.join('\n').trim();
    }
    if (text.isNotEmpty) {
      onLine(
        jsonEncode({
          'type': 'result',
          'subtype': 'success',
          'is_error': code != 0,
          'result': text,
        }),
      );
    }
    return (await stderr, code);
  } finally {
    unawaited(outFile.delete().catchError((Object _) => outFile));
  }
}

void _cleanupEphemeralAgyConversation(
  String convId,
  Map<String, String> env,
) {
  // Guard against any path traversal characters.
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(convId)) return;
  final home =
      env['HOME'] ??
      env['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '';
  if (home.isEmpty) return;
  final root = '$home/.gemini/antigravity-cli';
  for (final ext in const ['.db', '.db-wal', '.db-shm', '.pb']) {
    unawaited(
      File('$root/conversations/$convId$ext').delete().catchError((Object _) => File('')),
    );
  }
  unawaited(
    Directory('$root/brain/$convId')
        .delete(recursive: true)
        .catchError((Object _) => Directory('')),
  );
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
