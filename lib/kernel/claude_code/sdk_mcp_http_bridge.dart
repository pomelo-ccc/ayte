import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../extension_switches.dart';
import 'claude_sdk_tools.dart';

typedef SdkMcpSessionIdProvider = String? Function();
typedef SdkMcpTurnIdProvider = String? Function();
typedef SdkMcpCancelledProvider = Future<void>? Function();
typedef SdkMcpHandler =
    Future<Map<String, Object?>> Function(
      Map<String, Object?> message,
      ClaudeSdkCall call,
    );

/// In-process loopback Streamable-HTTP MCP bridge exposing [ClaudeSdkTools]
/// to external CLI kernels (`AntigravityTransport`, `CodexKernel`) that cannot
/// use Claude Code's stdio `control_request` (`mcp_message`) channel.
class AyteSdkMcpBridge {
  AyteSdkMcpBridge._({
    required this._server,
    required this._token,
    required this._mcpSessionId,
    required this.cwd,
    this._sessionIdProvider,
    this._turnIdProvider,
    this._cancelledProvider,
    this._ask,
    SdkMcpHandler? handler,
    this.includeAntigravityAlwaysLoad = false,
    Set<String> disabledTools = const {},
    this._serverDisabled = false,
    this._onConversationIdObserved,
  }) : _handler = handler ?? ClaudeSdkTools.handle,
       _disabledTools = {...disabledTools},
       _disabledNormalizedTools = {
         for (final tool in disabledTools) ExtensionSwitches.normalize(tool),
       } {
    _sub = _server.listen(
      (request) => unawaited(_handleRequest(request)),
      onError: (_) {},
      cancelOnError: false,
    );
  }

  /// Starts a loopback HTTP server on `127.0.0.1:0` with a 256-bit CSPRNG
  /// bearer token.
  static Future<AyteSdkMcpBridge> start({
    required String cwd,
    SdkMcpSessionIdProvider? sessionIdProvider,
    SdkMcpTurnIdProvider? turnIdProvider,
    SdkMcpCancelledProvider? cancelledProvider,
    ClaudeSdkAsk? ask,
    SdkMcpHandler? handler,
    bool includeAntigravityAlwaysLoad = false,
    Set<String> disabledTools = const {},
    bool serverDisabled = false,
    void Function(String conversationId)? onConversationIdObserved,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final rng = Random.secure();
    final token = _randomHex(rng, 32);
    final mcpSessionId = _randomHex(rng, 16);
    return AyteSdkMcpBridge._(
      server: server,
      token: token,
      mcpSessionId: mcpSessionId,
      cwd: cwd,
      sessionIdProvider: sessionIdProvider,
      turnIdProvider: turnIdProvider,
      cancelledProvider: cancelledProvider,
      ask: ask,
      handler: handler,
      includeAntigravityAlwaysLoad: includeAntigravityAlwaysLoad,
      disabledTools: disabledTools,
      serverDisabled: serverDisabled,
      onConversationIdObserved: onConversationIdObserved,
    );
  }

  static String _randomHex(Random rng, int bytes) {
    final buf = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buf.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  final HttpServer _server;
  final String _token;
  final String _mcpSessionId;
  late final StreamSubscription<HttpRequest> _sub;

  final String cwd;
  final SdkMcpSessionIdProvider? _sessionIdProvider;
  final SdkMcpTurnIdProvider? _turnIdProvider;
  final SdkMcpCancelledProvider? _cancelledProvider;
  final ClaudeSdkAsk? _ask;
  final SdkMcpHandler _handler;
  final bool includeAntigravityAlwaysLoad;
  final void Function(String conversationId)? _onConversationIdObserved;

  String? _sessionId;
  String? _lastObservedConvId;
  Set<String> _disabledTools;
  Set<String> _disabledNormalizedTools;
  bool _serverDisabled;
  Future<void>? _closing;
  final Map<Object, Completer<void>> _inFlightCancels = {};

  int get port => _server.port;
  String get token => _token;
  Uri get endpointUri => Uri.parse('http://127.0.0.1:$port/mcp');
  int get inFlightCancelCountForTesting => _inFlightCancels.length;

  /// Standard `mcp_config.json` / `mcpServers` entry for Streamable HTTP clients.
  Map<String, Object?> mcpServerConfig({String? type}) => {
    'type': ?type,
    'url': endpointUri.toString(),
    'headers': {'Authorization': 'Bearer $_token'},
  };

  /// Updates the active session/thread correlation id (before/after init).
  void updateSessionId(String? sessionId) {
    _sessionId = (sessionId == null || sessionId.isEmpty) ? null : sessionId;
  }

  /// Updates dynamic tool/server disablement from `ExtensionSwitches`.
  void updateDisabled({Set<String>? disabledTools, bool? serverDisabled}) {
    if (disabledTools != null) {
      _disabledTools = {...disabledTools};
      _disabledNormalizedTools = {
        for (final tool in disabledTools) ExtensionSwitches.normalize(tool),
      };
    }
    if (serverDisabled != null) {
      _serverDisabled = serverDisabled;
    }
  }

  bool _isToolDisabled(String name) =>
      _disabledTools.contains(name) ||
      _disabledNormalizedTools.contains(ExtensionSwitches.normalize(name));

  /// Gracefully shuts down the loopback server; safe to call multiple times.
  Future<void> close({bool force = false}) => _closing ??= () async {
    for (final cancel in _inFlightCancels.values) {
      if (!cancel.isCompleted) cancel.complete();
    }
    _inFlightCancels.clear();
    await _sub.cancel();
    await _server.close(force: force);
  }();

  String? _resolveSessionId([String? metaConversationId]) {
    if (_sessionId case final sid? when sid.isNotEmpty) return sid;
    if (_sessionIdProvider?.call() case final sid? when sid.isNotEmpty) {
      return sid;
    }
    if (metaConversationId != null && metaConversationId.isNotEmpty) {
      return metaConversationId;
    }
    if (_lastObservedConvId case final sid? when sid.isNotEmpty) {
      return sid;
    }
    return null;
  }

  Future<void>? _safeCancelled() {
    try {
      return _cancelledProvider?.call();
    } on Object {
      return Future<void>.value();
    }
  }

  ClaudeSdkCall _buildCall([String? metaConversationId]) {
    String? sessionProvider() => _resolveSessionId(metaConversationId);
    return ClaudeSdkCall(
      cwd: cwd,
      sessionId: sessionProvider(),
      sessionIdProvider: sessionProvider,
      turnId: _turnIdProvider?.call(),
      turnIdProvider: _turnIdProvider,
      cancelled: _safeCancelled(),
      ask: _ask,
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      final path = request.uri.path;
      if (path.startsWith('/.well-known/')) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      if (path != '/mcp' && !path.startsWith('/mcp/')) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      if (!_isAuthorized(request, path)) {
        response.statusCode = HttpStatus.unauthorized;
        response.headers.set('WWW-Authenticate', 'Bearer');
        await response.close();
        return;
      }

      switch (request.method.toUpperCase()) {
        case 'GET':
          response.statusCode = HttpStatus.methodNotAllowed;
          response.headers.set('Allow', 'POST, DELETE');
          await response.close();
        case 'DELETE':
          response.statusCode = HttpStatus.ok;
          await response.close();
        case 'POST':
          await _handlePost(request, response);
        default:
          response.statusCode = HttpStatus.methodNotAllowed;
          response.headers.set('Allow', 'POST, DELETE');
          await response.close();
      }
    } on Object {
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } on Object {
        // Ignore broken client socket during shutdown.
      }
    }
  }

  bool _isAuthorized(HttpRequest request, String path) {
    if (path.startsWith('/mcp/')) {
      final pathToken = path.substring('/mcp/'.length);
      return pathToken.isNotEmpty &&
          !pathToken.contains('/') &&
          _constantTimeEquals(pathToken, _token);
    }
    final authHeader = request.headers.value(HttpHeaders.authorizationHeader);
    if (authHeader != null) {
      const prefix = 'bearer ';
      final lower = authHeader.toLowerCase();
      if (lower.startsWith(prefix)) {
        final bearer = authHeader.substring(prefix.length).trim();
        if (_constantTimeEquals(bearer, _token)) return true;
      }
    }
    return false;
  }

  static bool _constantTimeEquals(String a, String b) {
    final bytesA = utf8.encode(a);
    final bytesB = utf8.encode(b);
    var diff = bytesA.length ^ bytesB.length;
    final len = bytesA.length < bytesB.length ? bytesA.length : bytesB.length;
    for (var i = 0; i < len; i++) {
      diff |= bytesA[i] ^ bytesB[i];
    }
    return diff == 0;
  }

  Future<void> _handlePost(HttpRequest request, HttpResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
    }
    final Object? decoded;
    try {
      final body = utf8.decode(builder.takeBytes());
      decoded = jsonDecode(body);
    } on FormatException {
      await _writeJson(response, HttpStatus.badRequest, {
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32700, 'message': 'Parse error'},
      });
      return;
    }

    if (decoded is Map) {
      final msg = decoded.cast<String, Object?>();
      final isNotification = !msg.containsKey('id');
      final result = await _dispatchJsonRpc(msg);
      if (isNotification) {
        response.statusCode = HttpStatus.accepted;
        await response.close();
        return;
      }
      final includeSessionHeader = msg['method'] == 'initialize';
      await _writeJson(
        response,
        HttpStatus.ok,
        result,
        mcpSessionId: includeSessionHeader ? _mcpSessionId : null,
      );
      return;
    }

    if (decoded is List) {
      if (decoded.isEmpty) {
        await _writeJson(response, HttpStatus.badRequest, {
          'jsonrpc': '2.0',
          'id': null,
          'error': {'code': -32600, 'message': 'Invalid Request'},
        });
        return;
      }
      final responses = <Map<String, Object?>>[];
      var hasInitialize = false;
      for (final item in decoded) {
        if (item is! Map) {
          responses.add({
            'jsonrpc': '2.0',
            'id': null,
            'error': {'code': -32600, 'message': 'Invalid Request'},
          });
          continue;
        }
        final msg = item.cast<String, Object?>();
        if (msg['method'] == 'initialize') hasInitialize = true;
        final isNotification = !msg.containsKey('id');
        final res = await _dispatchJsonRpc(msg);
        if (!isNotification) {
          responses.add(res);
        }
      }
      if (responses.isEmpty) {
        response.statusCode = HttpStatus.accepted;
        await response.close();
        return;
      }
      await _writeJson(
        response,
        HttpStatus.ok,
        responses,
        mcpSessionId: hasInitialize ? _mcpSessionId : null,
      );
      return;
    }

    await _writeJson(response, HttpStatus.badRequest, {
      'jsonrpc': '2.0',
      'id': null,
      'error': {'code': -32600, 'message': 'Invalid Request'},
    });
  }

  static Map<String, Object?> _jsonRpcError(
    Object? id,
    int code,
    String message,
  ) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };

  Future<Map<String, Object?>> _dispatchJsonRpc(
    Map<String, Object?> msg,
  ) async {
    final hasId = msg.containsKey('id');
    final id = hasId ? msg['id'] : 0;
    final method = msg['method'];
    if (method is! String) {
      return _jsonRpcError(
        id,
        -32600,
        'Invalid Request: "method" must be a string.',
      );
    }
    final rawParams = msg['params'];
    if (rawParams != null && rawParams is! Map) {
      return _jsonRpcError(id, -32602, 'Invalid params: expected object.');
    }
    final params = rawParams is Map
        ? rawParams.cast<String, Object?>()
        : const <String, Object?>{};

    switch (method) {
      case 'server/discover':
        return {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'capabilities': {'tools': <String, Object?>{}},
            'serverInfo': {'name': ClaudeSdkTools.server, 'version': '1.0.0'},
          },
        };
      case 'ping':
        return {
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, Object?>{},
        };
      case 'initialize':
        return _handler(msg, _buildCall());
      case 'tools/list':
        if (_serverDisabled) {
          return {
            'jsonrpc': '2.0',
            'id': id,
            'result': {'tools': const <Object?>[]},
          };
        }
        final rawResponse = await _handler(msg, _buildCall());
        final rawResult = rawResponse['result'];
        if (rawResult is! Map) return rawResponse;
        final resultMap = Map<String, Object?>.from(rawResult);
        final rawTools = resultMap['tools'];
        if (rawTools is! List) return rawResponse;
        final filteredTools = <Map<String, Object?>>[];
        for (final rawTool in rawTools) {
          if (rawTool is! Map) continue;
          final tool = Map<String, Object?>.from(rawTool);
          final name = switch (tool['name']) {
            final String s => s,
            _ => null,
          };
          if (name != null && _isToolDisabled(name)) continue;
          if (includeAntigravityAlwaysLoad) {
            if (tool['_meta'] case final Map rawMeta
                when rawMeta['anthropic/alwaysLoad'] == true) {
              final meta = Map<String, Object?>.from(rawMeta);
              meta['antigravity/alwaysLoad'] = true;
              tool['_meta'] = meta;
            }
          }
          filteredTools.add(tool);
        }
        resultMap['tools'] = filteredTools;
        return {
          ...rawResponse,
          'result': resultMap,
        };
      case 'tools/call':
        final rawMeta = params['_meta'];
        if (rawMeta != null && rawMeta is! Map) {
          return _jsonRpcError(
            id,
            -32602,
            'Invalid params: "_meta" must be an object.',
          );
        }
        final meta = rawMeta is Map ? rawMeta.cast<String, Object?>() : null;
        final metaConvId = switch (meta?['antigravity.google/conversation_id']) {
          final String s when s.isNotEmpty => s,
          _ => null,
        };
        if (metaConvId != null) {
          _lastObservedConvId = metaConvId;
          _onConversationIdObserved?.call(metaConvId);
        }
        final rawName = params['name'];
        if (rawName is! String || rawName.isEmpty) {
          return _jsonRpcError(
            id,
            -32602,
            'Invalid params: "name" must be a non-empty string.',
          );
        }
        final rawArgs = params['arguments'];
        if (rawArgs != null && rawArgs is! Map) {
          return _jsonRpcError(
            id,
            -32602,
            'Invalid params: "arguments" must be an object.',
          );
        }
        final toolName = rawName;
        if (_serverDisabled || _isToolDisabled(toolName)) {
          return {
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'content': [
                {'type': 'text', 'text': 'Tool $toolName is disabled.'},
              ],
              'isError': true,
            },
          };
        }
        final requestCancel = Completer<void>();
        if (hasId && id != null) {
          _inFlightCancels[id] = requestCancel;
        }
        final combinedCancel = Completer<void>();
        void completeCombined() {
          if (!combinedCancel.isCompleted) combinedCancel.complete();
        }
        try {
          unawaited(
            requestCancel.future.then(
              (_) => completeCombined(),
              onError: (_, _) => completeCombined(),
            ),
          );
          try {
            if (_cancelledProvider?.call() case final turnCancelled?) {
              unawaited(
                turnCancelled.then(
                  (_) => completeCombined(),
                  onError: (_, _) => completeCombined(),
                ),
              );
            }
          } on Object {
            completeCombined();
          }
          String? sessionProvider() => _resolveSessionId(metaConvId);
          final call = ClaudeSdkCall(
            cwd: cwd,
            sessionId: sessionProvider(),
            sessionIdProvider: sessionProvider,
            turnId: _turnIdProvider?.call(),
            turnIdProvider: _turnIdProvider,
            cancelled: combinedCancel.future,
            ask: _ask,
            toolUseId: switch (meta?['claudecode/toolUseId']) {
              final String tid when tid.isNotEmpty => tid,
              _ => null,
            },
          );
          return await _handler(msg, call);
        } on Object catch (error) {
          return {
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'content': [
                {'type': 'text', 'text': '$error'},
              ],
              'isError': true,
            },
          };
        } finally {
          if (hasId &&
              id != null &&
              identical(_inFlightCancels[id], requestCancel)) {
            _inFlightCancels.remove(id);
          }
          completeCombined();
        }
      case 'notifications/cancelled':
        final requestId = params['requestId'];
        var handled = false;
        if (requestId != null) {
          final cancel = _inFlightCancels.remove(requestId);
          if (cancel != null) {
            handled = true;
            if (!cancel.isCompleted) cancel.complete();
          }
        }
        // Never forward to ClaudeSdkTools.handle when _inFlightCancels
        // already handled it or when sessionId is still null, so concurrent
        // Turn-1 bridges cannot collide on ClaudeSdkTools._calls[(null, id)].
        if (handled || _resolveSessionId() == null) {
          return {
            'jsonrpc': '2.0',
            'id': id,
            'result': <String, Object?>{},
          };
        }
        return _handler(msg, _buildCall());
      default:
        return _handler(msg, _buildCall());
    }
  }

  static Future<void> _writeJson(
    HttpResponse response,
    int statusCode,
    Object payload, {
    String? mcpSessionId,
  }) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    if (mcpSessionId != null && mcpSessionId.isNotEmpty) {
      response.headers.set('Mcp-Session-Id', mcpSessionId);
    }
    response.write(jsonEncode(payload));
    await response.close();
  }
}
