// Tools of the app's own an agent can call: an MCP server that lives in
// the app rather than in a process of its own (Claude Code's "SDK"
// servers). Claude Code is told of it at launch (`--mcp-config`, type
// `sdk`) and as it is initialized (`sdkMcpServers`), and sends what it
// says to it as control requests (`mcp_message`), whose answers go back
// the same way.

import 'dart:async';

import '../../chat/chat_models.dart' show ToolCallItem, ToolKind;
import '../kernel_types.dart' show ApprovalDecision, ApprovalRequest;

/// Asks the user [request] on the agent's conversation, as the agent's
/// own requests are: what they decided, or null where it was given up
/// (the turn stopped) or no one is there to ask.
typedef ClaudeSdkAsk = Future<ApprovalDecision?> Function(
  ApprovalRequest request,
);

/// Where a tool is called from: the agent's working directory (its
/// project's path, as the workspace has it) and its session.
class ClaudeSdkCall {
  const ClaudeSdkCall({
    required this.cwd,
    this._sessionId,
    this.sessionIdProvider,
    this._turnId,
    this.turnIdProvider,
    this.cancelled,
    this.toolUseId,
    this.ask,
  });

  final String cwd;

  /// Asks the user, on the agent's conversation: its id is the kernel's
  /// to give (the request's own is not kept). None where the kernel cannot.
  final ClaudeSdkAsk? ask;
  final String? _sessionId;
  final String? Function()? sessionIdProvider;
  final String? _turnId;
  final String? Function()? turnIdProvider;

  String? get sessionId {
    final provided = sessionIdProvider?.call();
    if (provided != null && provided.isNotEmpty) return provided;
    return _sessionId;
  }

  String? get turnId {
    final provided = turnIdProvider?.call();
    if (provided != null && provided.isNotEmpty) return provided;
    return _turnId;
  }

  /// The tool use it answers, as Claude Code says (`_meta`'s
  /// `claudecode/toolUseId`): its step's in the conversation
  /// ([ToolCallItem.callId]).
  final String? toolUseId;

  /// Completes once the call is given up: the turn stopped, or the agent
  /// cancelled it. A tool that waits long (on the user, say) stops then.
  final Future<void>? cancelled;
}

/// One tool: its name, what it does and the JSON schema of its input, for
/// the model; [run] answers a call with text, or MCP content blocks (a
/// list of them: text, an image), or throws to say it failed.
class ClaudeSdkTool {
  const ClaudeSdkTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.run,
    this.kind,
    this.summary,
    this.files,
    this.alwaysLoad = false,
    this.offeredIn,
    this.asksItself = false,
  });

  /// Whether it asks the user itself, each time, whatever the mode
  /// ([ClaudeSdkCall.ask]): the CLI's leave not asked for it too.
  final bool asksItself;

  /// Whether an agent working in a folder (its location) is offered it, as
  /// the tool itself says, besides [ClaudeSdkTools.gate]; everywhere for
  /// null.
  final bool Function(String cwd)? offeredIn;

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
  final Future<Object> Function(Map<String, Object?> input, ClaudeSdkCall call)
  run;

  /// The step a call is in the conversation; else any MCP tool's.
  final ToolKind? kind;

  /// What a call is about, in a few words, from its input and (once
  /// answered) what it answered: the step's line, when the agent did not
  /// say it (an input's `description`, as Bash's).
  final String Function(Map<String, Object?> input, String? output)? summary;

  /// The files its pictures were saved to, one each, from what it answered
  /// ([ToolCallItem.imageFiles]): in place of the CLI's copies.
  final List<String> Function(String output)? files;

  /// Always in the model's prompt, never deferred behind Claude Code's tool
  /// search (where it would see only its name): for a tool it should think
  /// of unprompted.
  final bool alwaysLoad;
}

/// An image as MCP content, for a tool's answer.
Map<String, Object?> claudeSdkImage(String base64, String mimeType) => {
  'type': 'image',
  'data': base64,
  'mimeType': mimeType,
};

/// Text as MCP content, for a tool's answer.
Map<String, Object?> claudeSdkText(String text) => {
  'type': 'text',
  'text': text,
};

/// Which of the app's tools an agent is offered, by the folder it works in:
/// a bot's are its own, its abilities'; a project's agent has none of
/// them.
abstract interface class ClaudeSdkGate {
  bool offersTool(String cwd, String tool);

  /// Whether what [feature] tells of its tools ([ClaudeSdkTools.instruct])
  /// is told there.
  bool tellsFeature(String cwd, String feature);

  /// Whether a tool called there may wait on the user at the computer (to
  /// pick a model, say): not where there is none to.
  bool asksUser(String cwd);
}

/// The app's server and its tools (registered as their features start).
abstract final class ClaudeSdkTools {
  /// The server's name: its tools are `mcp__baocode__<name>` to the agent.
  static const server = 'baocode';

  static final Map<String, ClaudeSdkTool> _tools = {};

  /// The calls under way, by their session and request's id (each
  /// session counts its own): to cancel them.
  static final Map<(String?, Object), Completer<void>> _calls = {};

  static void register(ClaudeSdkTool tool) => _tools[tool.name] = tool;

  static void unregister(String name) => _tools.remove(name);

  /// What each feature tells the agent of its tools, by feature, for the
  /// folder it works in: the server's instructions, in the agent's system
  /// prompt.
  static final Map<String, String? Function(String cwd)> _instructions = {};

  /// Has the server tell the agent [text] for [feature]; null takes it
  /// back.
  static void instruct(String feature, String? text) => text == null
      ? _instructions.remove(feature)
      : _instructions[feature] = (_) => text;

  /// Has the server tell an agent what [text] gives for the folder it
  /// works in (nothing for null) for [feature].
  static void instructFor(String feature, String? Function(String cwd) text) =>
      _instructions[feature] = text;

  /// Which tools, by name, an agent working in a folder is offered, and
  /// which features' instructions it is told (see [ClaudeSdkGate]); all of
  /// them when null.
  static ClaudeSdkGate? gate;

  static bool _offers(String cwd, String tool) =>
      (_tools[tool]?.offeredIn?.call(cwd) ?? true) &&
      (gate?.offersTool(cwd, tool) ?? true);

  static bool _tells(String cwd, String feature) =>
      gate?.tellsFeature(cwd, feature) ?? true;

  /// Whether a tool called by an agent working in [cwd] may wait on the
  /// user at the computer ([ClaudeSdkGate.asksUser]).
  static bool asksUser(String cwd) => gate?.asksUser(cwd) ?? true;

  /// Whether [name] is a registered SDK tool on this server.
  static bool hasTool(String name) => _tools.containsKey(name);

  /// The registered SDK tool named [name], or null if none.
  static ClaudeSdkTool? toolNamed(String name) => _tools[name];

  /// The combined feature instructions offered for an agent working in [cwd],
  /// or null when none apply.
  static String? instructionsFor(String cwd) {
    final told = [
      for (final MapEntry(key: feature, value: text) in _instructions.entries)
        if (_tells(cwd, feature)) ?text(cwd),
    ];
    return told.isEmpty ? null : told.join('\n\n');
  }

  /// The tool an agent calls [name] (`mcp__baocode__<name>`), if one of
  /// this server's.
  static ClaudeSdkTool? called(String name) {
    const prefix = 'mcp__${server}__';
    return name.startsWith(prefix)
        ? _tools[name.substring(prefix.length)]
        : null;
  }

  /// Whether there is any tool: the server is only given then.
  static bool get any => _tools.isNotEmpty;

  /// The servers to launch Claude Code with: this one, if it has tools.
  static List<String> get servers => any ? const [server] : const [];

  /// The servers to launch an agent working in [cwd] with: this one, if it
  /// offers that agent a tool.
  static List<String> serversFor(String cwd) =>
      _tools.keys.any((name) => _offers(cwd, name)) ? const [server] : const [];

  /// The answer to [message] (JSON-RPC) for the server.
  static Future<Map<String, Object?>> handle(
    Map<String, Object?> message,
    ClaudeSdkCall call,
  ) async {
    final id = message.containsKey('id') ? message['id'] : 0;
    final rawParams = message['params'];
    if (rawParams != null && rawParams is! Map) {
      return {
        'jsonrpc': '2.0',
        'id': id,
        'error': {
          'code': -32602,
          'message': 'Invalid params: expected object.',
        },
      };
    }
    final params = rawParams is Map
        ? rawParams.cast<String, Object?>()
        : const <String, Object?>{};
    Map<String, Object?> result(Map<String, Object?> result) => {
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };
    switch (message['method']) {
      case 'initialize':
        final instructions = instructionsFor(call.cwd);
        return result({
          'protocolVersion': params['protocolVersion'] ?? '2024-11-05',
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': server, 'version': '1.0.0'},
          'instructions': ?instructions,
        });
      case 'tools/list':
        return result({
          'tools': [
            for (final tool in _tools.values)
              if (_offers(call.cwd, tool.name))
                {
                  'name': tool.name,
                  'description': tool.description,
                  'inputSchema': tool.inputSchema,
                  if (tool.alwaysLoad) '_meta': {'anthropic/alwaysLoad': true},
                },
          ],
        });
      case 'tools/call':
        final rawName = params['name'];
        if (rawName is! String || rawName.isEmpty) {
          return {
            'jsonrpc': '2.0',
            'id': id,
            'error': {
              'code': -32602,
              'message': 'Invalid params: "name" must be a non-empty string.',
            },
          };
        }
        final rawArgs = params['arguments'];
        if (rawArgs != null && rawArgs is! Map) {
          return {
            'jsonrpc': '2.0',
            'id': id,
            'error': {
              'code': -32602,
              'message': 'Invalid params: "arguments" must be an object.',
            },
          };
        }
        final tool = _offers(call.cwd, rawName) ? _tools[rawName] : null;
        final input = rawArgs is Map
            ? rawArgs.cast<String, Object?>()
            : const <String, Object?>{};
        if (tool == null) {
          return result({
            'content': [
              {'type': 'text', 'text': 'No tool $rawName.'},
            ],
            'isError': true,
          });
        }
        // Given up as the turn stops, or as the agent says.
        final cancel = Completer<void>();
        final sessionKey = call.sessionId;
        final key = (sessionKey, id ?? cancel);
        _calls[key] = cancel;
        unawaited(
          call.cancelled?.then(
            (_) {
              if (!cancel.isCompleted) cancel.complete();
            },
            onError: (_, _) {
              if (!cancel.isCompleted) cancel.complete();
            },
          ),
        );
        try {
          final answer = await tool.run(
            input,
            ClaudeSdkCall(
              cwd: call.cwd,
              sessionId: sessionKey,
              sessionIdProvider: call.sessionIdProvider,
              turnId: call.turnId,
              turnIdProvider: call.turnIdProvider,
              cancelled: cancel.future,
              ask: call.ask,
              toolUseId: switch (params['_meta']) {
                {'claudecode/toolUseId': final String id} => id,
                _ => null,
              },
            ),
          );
          return result({
            'content': switch (answer) {
              final List<Object?> blocks => blocks,
              _ => [claudeSdkText('$answer')],
            },
          });
        } on Object catch (error) {
          return result({
            'content': [
              {'type': 'text', 'text': '$error'},
            ],
            'isError': true,
          });
        } finally {
          if (identical(_calls[key], cancel)) _calls.remove(key);
          if (!cancel.isCompleted) cancel.complete();
        }
      case 'notifications/cancelled':
        final requestId = params['requestId'];
        if (requestId != null) {
          if (_calls.remove((call.sessionId, requestId)) case final cancel?
              when !cancel.isCompleted) {
            cancel.complete();
          }
        }
        return result({});
      case final String method when method.startsWith('notifications/'):
        return result({});
      default:
        return {
          'jsonrpc': '2.0',
          'id': id,
          'error': {
            'code': -32601,
            'message': 'Method not found: ${message['method']}',
          },
        };
    }
  }
}
