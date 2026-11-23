import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../automations/automation_service.dart';
import '../bots/bot_tools.dart';
import '../browser/embedded/embedded_browser_controller.dart';
import '../chat/chat_session.dart' show ComposerMessage;
import '../kernel/agent_kernel.dart' show KernelDescriptor;
import '../kernel/antigravity/antigravity_cli.dart'
    show antigravityBuiltinProviderId;
import '../kernel/codebuddy/codebuddy_cli.dart' show codebuddyBuiltinProviderId;
import '../kernel/kernel_registry.dart' show claudeCodeKernelId, codexKernelId;
import '../kernel/kernel_types.dart' show KernelOption;
import '../platform/app_paths.dart';
import '../platform/data_dir.dart';
import '../tasks/task_queue_service.dart';
import '../workspace/session_tools.dart';
import '../workspace/workspace.dart';
import 'acp_agent_service.dart';

/// Local loopback HTTP IPC server allowing `ayte-cli` (scripts & CI) to
/// communicate with a running Ayte desktop instance: run prompts, queue
/// worktree tasks, trigger automations, and open built-in browser tabs.
class AyteIpcServer extends ChangeNotifier {
  AyteIpcServer._();
  static final instance = AyteIpcServer._();

  @visibleForTesting
  String? homeOverride;

  /// Attached live desktop [Workspace] for `/sessions` endpoints (`null` before
  /// workbench mount or in headless unit tests).
  Workspace? workspace;

  HttpServer? _server;
  String _token = '';
  int? _port;

  bool get running => _server != null;
  int? get port => _port;

  String get _home {
    if (homeOverride case final override? when override.isNotEmpty) {
      return override;
    }
    final resolved = AppPaths.home(Platform.environment);
    return resolved.isNotEmpty ? resolved : Directory.systemTemp.path;
  }

  String get ipcInfoPath => p.join(_home, '.ayte', 'ipc.json');

  /// Path to the user-invocable `ayte-cli` entrypoint (`ayte-cli.cmd` on
  /// Windows, `ayte-cli` on POSIX).
  String get cliInstallPath => p.join(
    _home,
    '.local',
    'bin',
    Platform.isWindows ? 'ayte-cli.cmd' : 'ayte-cli',
  );

  /// Path to the underlying Python script (`ayte-cli.py` on Windows, same as
  /// [cliInstallPath] on POSIX).
  String get cliScriptPath => p.join(
    _home,
    '.local',
    'bin',
    Platform.isWindows ? 'ayte-cli.py' : 'ayte-cli',
  );

  bool get isCliInstalled =>
      File(cliInstallPath).existsSync() && File(cliScriptPath).existsSync();

  Future<void> start() async {
    if (_server != null ||
        (Platform.environment.containsKey('FLUTTER_TEST') &&
            homeOverride == null)) {
      return;
    }
    try {
      final rnd = Random.secure();
      _token = List.generate(
        24,
        (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      _port = server.port;

      final infoFile = File(ipcInfoPath);
      infoFile.parent.createSync(recursive: true);
      await writeFileAtomically(
        infoFile,
        jsonEncode({'port': _port, 'token': _token, 'pid': pid}),
      );
      server.listen(_handleRequest);
      notifyListeners();
    } on Object catch (e) {
      debugPrint('AyteIpcServer start failed: $e');
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = null;
    try {
      final f = File(ipcInfoPath);
      if (f.existsSync()) f.deleteSync();
    } on Object {
      // Ignore.
    }
    notifyListeners();
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final auth = req.headers.value('authorization') ?? '';
      if (auth != 'Bearer $_token') {
        req.response
          ..statusCode = HttpStatus.unauthorized
          ..write(jsonEncode({'error': 'Unauthorized'}));
        await req.response.close();
        return;
      }

      final path = req.uri.path;
      final segs = req.uri.pathSegments;
      Map<String, Object?> body = const {};
      if (req.method == 'POST') {
        final raw = await utf8.decoder.bind(req).join();
        if (raw.trim().isNotEmpty) {
          final Object? decoded;
          try {
            decoded = jsonDecode(raw);
          } on FormatException {
            req.response
              ..statusCode = HttpStatus.badRequest
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'error': 'Invalid JSON body'}));
            await req.response.close();
            return;
          }
          if (decoded is Map<String, Object?>) body = decoded;
        }
      }

      Object? responsePayload;
      switch ((req.method, path)) {
        case ('GET', '/health'):
          responsePayload = {'ok': true, 'pid': pid, 'port': _port};
        case ('GET', '/agents'):
          responsePayload = {
            'agents': [
              for (final a in AcpAgentService.instance.selectableAgents)
                a.toJson(),
            ],
          };
        case ('POST', '/prompt'):
          final errors = <String>[];
          final prompt = _optionalString(body, 'prompt', errors) ?? '';
          final optAgent = _optionalString(body, 'agent', errors);
          final optAgentId = _optionalString(body, 'agentId', errors);
          final rawAgent = (optAgent != null && optAgent.isNotEmpty)
              ? optAgent
              : (optAgentId ?? '');
          final requestedAgent = rawAgent.isEmpty ? 'agy' : rawAgent;
          final resolvedAgent = AcpAgentService.instance.byId(requestedAgent);
          final model = _optionalString(body, 'model', errors);
          final effort = _optionalString(body, 'effort', errors);
          final rawCwd = _optionalString(body, 'cwd', errors);
          final cwd = (body.containsKey('cwd') && body['cwd'] != null)
              ? (rawCwd ?? '')
              : Directory.current.path;
          if (errors.isNotEmpty) {
            req.response.statusCode = HttpStatus.badRequest;
            responsePayload = {'error': errors.first};
          } else if (prompt.isEmpty) {
            req.response.statusCode = HttpStatus.badRequest;
            responsePayload = {'error': 'prompt is required'};
          } else if (cwd.isEmpty || !Directory(cwd).existsSync()) {
            req.response.statusCode = HttpStatus.badRequest;
            responsePayload = {'error': 'cwd must be an existing directory'};
          } else if (resolvedAgent == null) {
            req.response.statusCode = HttpStatus.badRequest;
            responsePayload = {
              'error':
                  'Unknown agent "$requestedAgent". Available: ${AcpAgentService.builtInAgents.map((a) => a.id).join(', ')}',
            };
          } else {
            final res = await AcpAgentService.instance.runHeadlessPrompt(
              agentId: resolvedAgent.id,
              prompt: prompt,
              cwd: cwd,
              model: model,
              effort: effort,
            );
            responsePayload = {
              'ok': res.ok,
              'agent': resolvedAgent.id,
              'output': res.output,
              'error': res.error,
            };
          }
        case ('GET', '/tasks'):
          responsePayload = {
            'tasks': [
              for (final t in TaskQueueService.instance.tasks) t.toJson(),
            ],
          };
        case ('POST', '/tasks'):
          final errors = <String>[];
          final prompt = _optionalString(body, 'prompt', errors) ?? '';
          final rawCwd = _optionalString(body, 'cwd', errors);
          final cwd = (body.containsKey('cwd') && body['cwd'] != null)
              ? (rawCwd ?? '')
              : Directory.current.path;
          final optAgent = _optionalString(body, 'agent', errors);
          final optAgentId = _optionalString(body, 'agentId', errors);
          final rawAgent = (optAgent != null && optAgent.isNotEmpty)
              ? optAgent
              : (optAgentId ?? '');
          final requestedAgent = rawAgent.isEmpty ? 'agy' : rawAgent;
          final resolvedAgent = AcpAgentService.instance.byId(requestedAgent);
          final title = _optionalString(body, 'title', errors) ?? '';
          final model = _optionalString(body, 'model', errors);
          final effort = _optionalString(body, 'effort', errors);
          final useWorktree = _optionalBool(body, 'useWorktree', errors);
          final workflowTemplateId = _optionalString(
            body,
            'workflowTemplateId',
            errors,
          );
          final runNow = _optionalBool(body, 'run', errors);
          if (errors.isNotEmpty) {
            req.response.statusCode = HttpStatus.badRequest;
            responsePayload = {'error': errors.first};
          } else if (prompt.isEmpty) {
            req.response.statusCode = HttpStatus.badRequest;
            responsePayload = {'error': 'prompt is required'};
          } else if (cwd.isEmpty || !Directory(cwd).existsSync()) {
            req.response.statusCode = HttpStatus.badRequest;
            responsePayload = {'error': 'cwd must be an existing directory'};
          } else if (resolvedAgent == null) {
            req.response.statusCode = HttpStatus.badRequest;
            responsePayload = {
              'error':
                  'Unknown agent "$requestedAgent". Available: ${AcpAgentService.builtInAgents.map((a) => a.id).join(', ')}',
            };
          } else {
            final task = TaskQueueService.instance.enqueue(
              title: title,
              prompt: prompt,
              repoPath: cwd,
              agentId: resolvedAgent.id,
              model: model,
              effort: effort,
              useWorktree: useWorktree ?? true,
              workflowTemplateId: workflowTemplateId,
            );
            if (runNow == true) {
              unawaited(TaskQueueService.instance.runTask(task.id));
            }
            responsePayload = {'ok': true, 'task': task.toJson()};
          }
        case ('GET', '/sessions'):
          final ws = workspace;
          if (ws == null) {
            responsePayload = {
              'ok': true,
              'attached': false,
              'sessions': const <Object?>[],
            };
          } else {
            responsePayload = {
              'ok': true,
              'attached': true,
              'sessions': [
                for (final t in ws.threads)
                  if (!t.archived && !ws.isAppFolder(t.project.path))
                    {
                      'id': SessionTools.idOf(t),
                      'title': t.title,
                      'project': t.project.name,
                      'cwd': t.project.path,
                      'kernel': t.kernel.id,
                      'status': BotTools.statusOf(t),
                      'updatedAt': t.updatedAt.toIso8601String(),
                      'model': SessionTools.modelOf(t)?.id,
                    },
              ],
            };
          }
        case ('POST', '/sessions'):
          final ws = workspace;
          if (ws == null) {
            req.response.statusCode = HttpStatus.serviceUnavailable;
            responsePayload = {'error': 'Workspace is not attached'};
          } else {
            final errors = <String>[];
            final rawPrompt = _optionalString(body, 'prompt', errors);
            final rawText = _optionalString(body, 'text', errors);
            final prompt = (rawPrompt != null && rawPrompt.isNotEmpty)
                ? rawPrompt
                : (rawText ?? '');
            final cwd = _optionalString(body, 'cwd', errors) ?? '';
            final rawKernel = _optionalString(body, 'kernel', errors);
            final rawAgent = _optionalString(body, 'agent', errors);
            final wantedKernel = (rawKernel != null && rawKernel.isNotEmpty)
                ? rawKernel
                : (rawAgent ?? '');
            final wantedModel = _optionalString(body, 'model', errors) ?? '';
            final targetKernel = wantedKernel.isEmpty
                ? null
                : _resolveWorkspaceKernel(ws, wantedKernel);
            if (errors.isNotEmpty) {
              req.response.statusCode = HttpStatus.badRequest;
              responsePayload = {'error': errors.first};
            } else if (prompt.isEmpty) {
              req.response.statusCode = HttpStatus.badRequest;
              responsePayload = {'error': 'prompt is required'};
            } else if (cwd.isEmpty || !Directory(cwd).existsSync()) {
              req.response.statusCode = HttpStatus.badRequest;
              responsePayload = {'error': 'cwd must be an existing directory'};
            } else if (wantedKernel.isNotEmpty && targetKernel == null) {
              req.response.statusCode = HttpStatus.badRequest;
              responsePayload = {
                'error':
                    'Unknown kernel "$wantedKernel". Available: ${ws.kernels.map((k) => k.id).join(', ')}',
              };
            } else {
              var thread = await ws.openFolder(cwd);
              if (targetKernel != null && thread.kernel.id != targetKernel.id) {
                if (!thread.session.kernelLocked) {
                  thread.session.setKernel(targetKernel);
                } else {
                  final fresh = ws.startAgent(
                    thread.project,
                    kernel: targetKernel,
                  );
                  ws.select(fresh);
                  thread = fresh;
                }
              }
              if (targetKernel != null && thread.kernel.id != targetKernel.id) {
                req.response.statusCode = HttpStatus.conflict;
                responsePayload = {
                  'error':
                      'Session kernel is locked to "${thread.kernel.id}" and cannot use "${targetKernel.id}"',
                };
              } else {
                if (wantedModel.isNotEmpty && thread.session.models != null) {
                  final modelsChoice = thread.session.models!;
                  final lowerM = wantedModel.toLowerCase();
                  KernelOption? matched = modelsChoice.options
                      .where((o) => o.id.toLowerCase() == lowerM)
                      .firstOrNull;
                  matched ??= () {
                    final suffix = [
                      for (final o in modelsChoice.options)
                        if (o.id.toLowerCase().endsWith('/$lowerM')) o,
                    ];
                    return suffix.length == 1 ? suffix.single : null;
                  }();
                  matched ??= modelsChoice.options
                      .where((o) => o.label.toLowerCase() == lowerM)
                      .firstOrNull;
                  if (matched != null &&
                      matched.id != modelsChoice.selected.id) {
                    modelsChoice.onSelected(matched);
                  }
                }
                if (!thread.session.canSend) {
                  req.response.statusCode = HttpStatus.conflict;
                  responsePayload = {
                    'error': 'Session cannot accept messages right now',
                  };
                } else {
                  thread.session.send(ComposerMessage(text: prompt));
                  responsePayload = {
                    'ok': true,
                    'session': {
                      'id': SessionTools.idOf(thread),
                      'title': thread.title,
                      'project': thread.project.name,
                      'cwd': thread.project.path,
                      'kernel': thread.kernel.id,
                      'status': BotTools.statusOf(thread),
                      'model': SessionTools.modelOf(thread)?.id,
                    },
                  };
                }
              }
            }
          }
        case ('GET', '/automations'):
          responsePayload = {
            'automations': [
              for (final r in AutomationService.instance.rules) r.toJson(),
            ],
          };
        case ('POST', '/automations/run'):
          final id = '${body['id'] ?? ''}'.trim();
          final found = AutomationService.instance.rules.any(
            (r) => r.id == id,
          );
          if (found) {
            unawaited(AutomationService.instance.runNow(id));
          }
          responsePayload = {'ok': true, 'id': id, 'found': found};
        case ('POST', '/browser/open'):
          final url = '${body['url'] ?? ''}'.trim();
          if (url.isEmpty) {
            req.response.statusCode = HttpStatus.badRequest;
            responsePayload = {'error': 'url is required'};
          } else {
            final tab = EmbeddedBrowserController.instance.openTab(url);
            responsePayload = {'ok': true, 'tab': tab.toJson()};
          }
        default:
          if (req.method == 'GET' && segs.length == 2 && segs[0] == 'tasks') {
            final id = Uri.decodeComponent(segs[1]);
            final task = TaskQueueService.instance.byId(id);
            if (task == null) {
              req.response.statusCode = HttpStatus.notFound;
              responsePayload = {'error': 'Task not found: $id'};
            } else {
              await TaskQueueService.instance.ensureTaskDetailsLoaded(id);
              responsePayload = {
                'ok': true,
                'task': task.toJson(),
                'log': task.log,
                'diffText': task.diffText,
              };
            }
          } else if (req.method == 'POST' &&
              segs.length == 3 &&
              segs[0] == 'tasks') {
            final id = Uri.decodeComponent(segs[1]);
            final action = segs[2];
            final task = TaskQueueService.instance.byId(id);
            if (task == null) {
              req.response.statusCode = HttpStatus.notFound;
              responsePayload = {'error': 'Task not found: $id'};
            } else {
              switch (action) {
                case 'run':
                  unawaited(TaskQueueService.instance.runTask(id));
                  responsePayload = {'ok': true, 'task': task.toJson()};
                case 'cancel':
                  await TaskQueueService.instance.cancelTask(id);
                  responsePayload = {'ok': true, 'task': task.toJson()};
                case 'merge':
                  final res = await TaskQueueService.instance.approveAndMerge(
                    id,
                  );
                  if (!res.ok) {
                    req.response.statusCode = HttpStatus.conflict;
                  }
                  responsePayload = {
                    'ok': res.ok,
                    'message': res.message,
                    'task': task.toJson(),
                  };
                case 'discard':
                  await TaskQueueService.instance.discardTask(id);
                  responsePayload = {'ok': true, 'id': id};
                default:
                  req.response.statusCode = HttpStatus.notFound;
                  responsePayload = {'error': 'Not found: $path'};
              }
            }
          } else if (req.method == 'GET' &&
              segs.length == 2 &&
              segs[0] == 'sessions') {
            final ws = workspace;
            if (ws == null) {
              req.response.statusCode = HttpStatus.serviceUnavailable;
              responsePayload = {'error': 'Workspace is not attached'};
            } else {
              final id = Uri.decodeComponent(segs[1]);
              final t = SessionTools.threadOf(ws, id);
              if (t == null || ws.isAppFolder(t.project.path)) {
                req.response.statusCode = HttpStatus.notFound;
                responsePayload = {'error': 'Session not found: $id'};
              } else {
                final limit =
                    (int.tryParse(req.uri.queryParameters['limit'] ?? '') ?? 30)
                        .clamp(1, 200);
                final openFlag = req.uri.queryParameters['open'] == 'true';
                final items = <String>[];
                if (t.isOpen || openFlag) {
                  final session = t.session;
                  final count = session.itemCount;
                  final start = count > limit ? count - limit : 0;
                  for (var i = start; i < count; i++) {
                    final line = BotTools.lineOf(
                      session.itemAt(i),
                      max: 2000,
                    );
                    if (line != null) items.add(line);
                  }
                }
                responsePayload = {
                  'ok': true,
                  'session': {
                    'id': SessionTools.idOf(t),
                    'title': t.title,
                    'project': t.project.name,
                    'cwd': t.project.path,
                    'kernel': t.kernel.id,
                    'status': BotTools.statusOf(t),
                    'updatedAt': t.updatedAt.toIso8601String(),
                    'model': SessionTools.modelOf(t)?.id,
                    'isOpen': t.isOpen,
                  },
                  'items': items,
                };
              }
            }
          } else if (req.method == 'POST' &&
              segs.length == 3 &&
              segs[0] == 'sessions' &&
              segs[2] == 'send') {
            final ws = workspace;
            if (ws == null) {
              req.response.statusCode = HttpStatus.serviceUnavailable;
              responsePayload = {'error': 'Workspace is not attached'};
            } else {
              final id = Uri.decodeComponent(segs[1]);
              final t = SessionTools.threadOf(ws, id);
              if (t == null || ws.isAppFolder(t.project.path)) {
                req.response.statusCode = HttpStatus.notFound;
                responsePayload = {'error': 'Session not found: $id'};
              } else {
                final errors = <String>[];
                final rawText = _optionalString(body, 'text', errors);
                final rawPrompt = _optionalString(body, 'prompt', errors);
                final text = (rawText != null && rawText.isNotEmpty)
                    ? rawText
                    : (rawPrompt ?? '');
                if (errors.isNotEmpty) {
                  req.response.statusCode = HttpStatus.badRequest;
                  responsePayload = {'error': errors.first};
                } else if (text.isEmpty) {
                  req.response.statusCode = HttpStatus.badRequest;
                  responsePayload = {'error': 'text is required'};
                } else {
                  final session = t.session;
                  if (!session.canSend) {
                    req.response.statusCode = HttpStatus.conflict;
                    responsePayload = {
                      'error': 'Session cannot accept messages right now',
                    };
                  } else {
                    session.send(ComposerMessage(text: text));
                    responsePayload = {
                      'ok': true,
                      'id': SessionTools.idOf(t),
                      'status': BotTools.statusOf(t),
                    };
                  }
                }
              }
            }
          } else {
            req.response.statusCode = HttpStatus.notFound;
            responsePayload = {'error': 'Not found: $path'};
          }
      }

      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(responsePayload));
      await req.response.close();
    } on Object catch (e) {
      req.response
        ..statusCode = HttpStatus.internalServerError
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': '$e'}));
      await req.response.close();
    }
  }

  static KernelDescriptor? _resolveWorkspaceKernel(
    Workspace ws,
    String raw,
  ) {
    final lower = raw.trim().toLowerCase();
    if (lower.isEmpty) return null;
    for (final k in ws.kernels) {
      if (k.id.toLowerCase() == lower) return k;
    }
    final canonical = switch (AcpAgentService.normalizeAgentId(lower)) {
      'agy' => antigravityBuiltinProviderId,
      'claude' => claudeCodeKernelId,
      'codebuddy' => codebuddyBuiltinProviderId,
      'codex' => codexKernelId,
      _ => null,
    };
    if (canonical != null) {
      for (final k in ws.kernels) {
        if (k.id.toLowerCase() == canonical.toLowerCase()) return k;
      }
    }
    for (final k in ws.kernels) {
      if (k.label.toLowerCase() == lower) return k;
    }
    return null;
  }

  static String? _optionalString(
    Map<String, Object?> body,
    String key,
    List<String> errors,
  ) {
    if (!body.containsKey(key) || body[key] == null) return null;
    final raw = body[key];
    if (raw is String) return raw.trim();
    errors.add('$key must be a string');
    return null;
  }

  static bool? _optionalBool(
    Map<String, Object?> body,
    String key,
    List<String> errors,
  ) {
    if (!body.containsKey(key) || body[key] == null) return null;
    final raw = body[key];
    if (raw is bool) return raw;
    errors.add('$key must be a boolean');
    return null;
  }

  /// Installs the standalone `ayte-cli` command into `~/.local/bin/`
  /// (`ayte-cli.cmd` + `ayte-cli.py` on Windows, `ayte-cli` on POSIX).
  Future<bool> installCli() async {
    try {
      final scriptFile = File(cliScriptPath);
      scriptFile.parent.createSync(recursive: true);
      await writeFileAtomically(scriptFile, _ayteCliPythonScript);
      if (Platform.isWindows) {
        final cmdFile = File(cliInstallPath);
        await writeFileAtomically(cmdFile, _ayteCliWindowsCmdWrapper);
      } else {
        await Process.run('chmod', ['+x', cliInstallPath]);
      }
      notifyListeners();
      return true;
    } on Object catch (e) {
      debugPrint('installCli failed: $e');
      return false;
    }
  }

  Future<void> uninstallCli() async {
    for (final path in {cliInstallPath, cliScriptPath}) {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    }
    notifyListeners();
  }

  static const String _ayteCliWindowsCmdWrapper =
      '@echo off\r\n'
      'setlocal\r\n'
      'where py >nul 2>nul\r\n'
      'if %ERRORLEVEL%==0 (\r\n'
      '  py -3 "%~dp0ayte-cli.py" %*\r\n'
      '  exit /b %ERRORLEVEL%\r\n'
      ')\r\n'
      'python "%~dp0ayte-cli.py" %*\r\n'
      'exit /b %ERRORLEVEL%\r\n';

  static const String _ayteCliPythonScript = r'''#!/usr/bin/env python3
"""ayte-cli — Command-line & CI client for a running Ayte desktop workspace."""
import argparse, json, os, sys, urllib.error, urllib.parse, urllib.request

IPC_PATH = os.path.expanduser("~/.ayte/ipc.json")

def load_ipc():
    if not os.path.exists(IPC_PATH):
        sys.stderr.write("Error: Ayte is not running (missing ~/.ayte/ipc.json).\n")
        sys.exit(1)
    with open(IPC_PATH, "r", encoding="utf-8") as f:
        return json.load(f)

def call_api(method, path, payload=None):
    info = load_ipc()
    url = f"http://127.0.0.1:{info['port']}{path}"
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {info['token']}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=900) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')}\n")
        sys.exit(1)
    except Exception as e:
        sys.stderr.write(f"Connection failed: {e}\n")
        sys.exit(1)

def main():
    shared = argparse.ArgumentParser(add_help=False)
    shared.add_argument("-a", "--agent", default=argparse.SUPPRESS, help="Agent ID (default: agy)")
    shared.add_argument("-m", "--model", default=argparse.SUPPRESS, help="Optional model ID override")
    shared.add_argument("--effort", default=argparse.SUPPRESS, help="Optional reasoning effort override")
    shared.add_argument("-p", "--prompt", default=argparse.SUPPRESS, help="Prompt to run or pass to subcommand")
    shared.add_argument("--cwd", default=argparse.SUPPRESS, help="Working directory")
    shared.add_argument("--json", action="store_true", dest="as_json", default=argparse.SUPPRESS, help="Emit raw JSON")

    p = argparse.ArgumentParser(
        prog="ayte-cli",
        parents=[shared],
        description="Drive Ayte from terminal or CI",
    )
    sub = p.add_subparsers(dest="cmd")

    sub.add_parser("status", parents=[shared], help="Check connection to running Ayte")
    sub.add_parser("agents", parents=[shared], help="List available native coding kernels")

    t_p = sub.add_parser("task", parents=[shared], help="Queue, inspect, or manage worktree tasks")
    t_p.add_argument("action", choices=["list", "add", "get", "run", "cancel", "merge", "discard"])
    t_p.add_argument("target", nargs="?", default="", help="Task ID for get/run/cancel/merge/discard")
    t_p.add_argument("--id", default="", help="Task ID override")
    t_p.add_argument("--title", default="")
    t_p.add_argument("--in-place", action="store_true", dest="in_place")
    t_p.add_argument("--run", action="store_true")

    s_p = sub.add_parser("sessions", parents=[shared], help="List, inspect, create, or message workspace sessions")
    s_p.add_argument("action", choices=["list", "read", "new", "send"])
    s_p.add_argument("target", nargs="?", default="", help="Session ID for read/send")
    s_p.add_argument("--id", default="", help="Session ID override")
    s_p.add_argument("--text", default="", help="Message text for new/send")
    s_p.add_argument("--limit", type=int, default=30, help="Max items to read")
    s_p.add_argument("--open", action="store_true", help="Open closed session before reading")

    a_p = sub.add_parser("automations", parents=[shared], help="List or trigger scheduled automations")
    a_p.add_argument("action", choices=["list", "run"])
    a_p.add_argument("target", nargs="?", default="", help="Automation rule ID")
    a_p.add_argument("--id", default="", help="Automation rule ID override")

    b_p = sub.add_parser("browser", parents=[shared], help="Control Ayte built-in browser")
    b_p.add_argument("action", choices=["open"])
    b_p.add_argument("url")

    args = p.parse_args()
    for k, v in (
        ("agent", "agy"),
        ("model", ""),
        ("effort", ""),
        ("prompt", ""),
        ("cwd", os.getcwd()),
        ("as_json", False),
    ):
        if not hasattr(args, k):
            setattr(args, k, v)

    if args.cmd == "status":
        res = call_api("GET", "/health")
        print(json.dumps(res, indent=2) if args.as_json else f"Ayte IPC OK (pid={res.get('pid')}, port={res.get('port')})")
        return

    if args.cmd == "agents":
        res = call_api("GET", "/agents")
        if args.as_json:
            print(json.dumps(res, indent=2, ensure_ascii=False))
        else:
            for a in res.get("agents", []):
                proto = a.get("protocol", "native")
                cmd = a.get("command", "")
                print(f"{a.get('id', ''):16} {a.get('name', '')} ({proto}: {cmd})")
        return

    if args.cmd == "task":
        tid = args.id or args.target
        if args.action == "list":
            res = call_api("GET", "/tasks")
            print(json.dumps(res, indent=2, ensure_ascii=False))
        elif args.action == "add":
            payload = {
                "title": args.title,
                "prompt": args.prompt,
                "cwd": args.cwd,
                "agent": args.agent,
                "useWorktree": not args.in_place,
                "run": args.run,
            }
            if args.model:
                payload["model"] = args.model
            if args.effort:
                payload["effort"] = args.effort
            res = call_api("POST", "/tasks", payload)
            print(json.dumps(res, indent=2, ensure_ascii=False))
        else:
            if not tid:
                sys.stderr.write(f"Error: task id required for '{args.action}'\n")
                sys.exit(2)
            q_tid = urllib.parse.quote(tid, safe="")
            if args.action == "get":
                res = call_api("GET", f"/tasks/{q_tid}")
            else:
                res = call_api("POST", f"/tasks/{q_tid}/{args.action}", {})
            print(json.dumps(res, indent=2, ensure_ascii=False))
        return

    if args.cmd == "sessions":
        sid = args.id or args.target
        if args.action == "list":
            res = call_api("GET", "/sessions")
        elif args.action == "read":
            if not sid:
                sys.stderr.write("Error: session id required for 'read'\n")
                sys.exit(2)
            q_sid = urllib.parse.quote(sid, safe="")
            qs = f"?limit={args.limit}" + ("&open=true" if args.open else "")
            res = call_api("GET", f"/sessions/{q_sid}{qs}")
        elif args.action == "new":
            text = args.text or args.prompt or ""
            payload = {"prompt": text, "cwd": args.cwd, "kernel": args.agent}
            if args.model:
                payload["model"] = args.model
            res = call_api("POST", "/sessions", payload)
        else:
            if not sid:
                sys.stderr.write("Error: session id required for 'send'\n")
                sys.exit(2)
            q_sid = urllib.parse.quote(sid, safe="")
            text = args.text or args.prompt or ""
            res = call_api("POST", f"/sessions/{q_sid}/send", {"text": text})
        print(json.dumps(res, indent=2, ensure_ascii=False))
        return

    if args.cmd == "automations":
        if args.action == "list":
            res = call_api("GET", "/automations")
        else:
            aid = args.id or args.target
            if not aid:
                sys.stderr.write("Error: automation id required for 'run'\n")
                sys.exit(2)
            res = call_api("POST", "/automations/run", {"id": aid})
        print(json.dumps(res, indent=2, ensure_ascii=False))
        return

    if args.cmd == "browser":
        res = call_api("POST", "/browser/open", {"url": args.url})
        print(json.dumps(res, indent=2, ensure_ascii=False))
        return

    stdin_data = "" if sys.stdin.isatty() else sys.stdin.read()
    prompt = args.prompt or ""
    if stdin_data.strip():
        prompt = f"{prompt}\n\n```text\n{stdin_data}\n```".strip()
    if not prompt:
        p.print_help()
        sys.exit(2)

    payload = {"agent": args.agent, "prompt": prompt, "cwd": args.cwd}
    if args.model:
        payload["model"] = args.model
    if args.effort:
        payload["effort"] = args.effort
    res = call_api("POST", "/prompt", payload)
    if args.as_json:
        print(json.dumps(res, indent=2, ensure_ascii=False))
    else:
        if not res.get("ok"):
            sys.stderr.write((res.get("error") or "Error") + "\n")
            sys.exit(1)
        print(res.get("output", ""))

if __name__ == "__main__":
    main()
''';
}
