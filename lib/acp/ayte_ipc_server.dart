import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../automations/automation_service.dart';
import '../browser/embedded/embedded_browser_controller.dart';
import '../tasks/task_queue_service.dart';
import 'acp_agent_service.dart';

/// Local loopback HTTP IPC server allowing `ayte-cli` (scripts & CI) to
/// communicate with a running Ayte desktop instance: run prompts, queue
/// worktree tasks, trigger automations, and open built-in browser tabs.
class AyteIpcServer extends ChangeNotifier {
  AyteIpcServer._();
  static final instance = AyteIpcServer._();

  HttpServer? _server;
  String _token = '';
  int? _port;

  bool get running => _server != null;
  int? get port => _port;

  static String get _home =>
      Platform.environment['HOME'] ?? Directory.systemTemp.path;

  static String get ipcInfoPath => p.join(_home, '.ayte', 'ipc.json');
  static String get cliInstallPath => p.join(_home, '.local', 'bin', 'ayte-cli');

  bool get isCliInstalled => File(cliInstallPath).existsSync();

  Future<void> start() async {
    if (_server != null || Platform.environment.containsKey('FLUTTER_TEST')) {
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
      await infoFile.writeAsString(
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
      Map<String, Object?> body = const {};
      if (req.method == 'POST') {
        final raw = await utf8.decoder.bind(req).join();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
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
          final prompt = '${body['prompt'] ?? ''}'.trim();
          final agentId = '${body['agent'] ?? 'agy'}';
          final cwd = '${body['cwd'] ?? Directory.current.path}';
          if (prompt.isEmpty) {
            req.response.statusCode = HttpStatus.badRequest;
            responsePayload = {'error': 'prompt is required'};
          } else {
            final res = await AcpAgentService.instance.runHeadlessPrompt(
              agentId: agentId,
              prompt: prompt,
              cwd: cwd,
            );
            responsePayload = {
              'ok': res.ok,
              'agent': agentId,
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
          final task = TaskQueueService.instance.enqueue(
            title: '${body['title'] ?? ''}',
            prompt: '${body['prompt'] ?? ''}',
            repoPath: '${body['cwd'] ?? Directory.current.path}',
            agentId: '${body['agent'] ?? 'agy'}',
          );
          if (body['run'] == true) {
            unawaited(TaskQueueService.instance.runTask(task.id));
          }
          responsePayload = {'ok': true, 'task': task.toJson()};
        case ('GET', '/automations'):
          responsePayload = {
            'automations': [
              for (final r in AutomationService.instance.rules) r.toJson(),
            ],
          };
        case ('POST', '/automations/run'):
          final id = '${body['id'] ?? ''}';
          unawaited(AutomationService.instance.runNow(id));
          responsePayload = {'ok': true, 'id': id};
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
          req.response.statusCode = HttpStatus.notFound;
          responsePayload = {'error': 'Not found: $path'};
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

  /// Installs the standalone `ayte-cli` command into `~/.local/bin/ayte-cli`.
  Future<bool> installCli() async {
    try {
      final file = File(cliInstallPath);
      file.parent.createSync(recursive: true);
      await file.writeAsString(_ayteCliPythonScript);
      await Process.run('chmod', ['+x', cliInstallPath]);
      notifyListeners();
      return true;
    } on Object catch (e) {
      debugPrint('installCli failed: $e');
      return false;
    }
  }

  Future<void> uninstallCli() async {
    final file = File(cliInstallPath);
    if (file.existsSync()) file.deleteSync();
    notifyListeners();
  }

  static const String _ayteCliPythonScript = r'''#!/usr/bin/env python3
"""ayte-cli — Command-line & CI client for a running Ayte desktop workspace."""
import argparse, json, os, sys, urllib.request, urllib.error

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
    p = argparse.ArgumentParser(prog="ayte-cli", description="Drive Ayte from terminal or CI")
    p.add_argument("-a", "--agent", default="agy", help="Agent ID (default: agy)")
    p.add_argument("-p", "--prompt", help="Prompt to run (stdin is appended automatically if piped)")
    p.add_argument("--cwd", default=os.getcwd(), help="Working directory")
    p.add_argument("--json", action="store_true", dest="as_json", help="Emit raw JSON")
    sub = p.add_subparsers(dest="cmd")

    sub.add_parser("status", help="Check connection to running Ayte")
    sub.add_parser("agents", help="List available ACP / CLI agents")

    t_p = sub.add_parser("task", help="Queue or list worktree tasks")
    t_p.add_argument("action", choices=["list", "add"])
    t_p.add_argument("--title", default="")
    t_p.add_argument("--prompt", default="")
    t_p.add_argument("--run", action="store_true")

    b_p = sub.add_parser("browser", help="Control Ayte built-in browser")
    b_p.add_argument("action", choices=["open"])
    b_p.add_argument("url")

    args = p.parse_args()

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
                print(f"{a['id']:16} {a['name']} ({a['protocol']}: {a['command']})")
        return

    if args.cmd == "task":
        if args.action == "list":
            res = call_api("GET", "/tasks")
            print(json.dumps(res, indent=2, ensure_ascii=False))
        else:
            res = call_api("POST", "/tasks", {"title": args.title, "prompt": args.prompt, "cwd": args.cwd, "agent": args.agent, "run": args.run})
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

    res = call_api("POST", "/prompt", {"agent": args.agent, "prompt": prompt, "cwd": args.cwd})
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
