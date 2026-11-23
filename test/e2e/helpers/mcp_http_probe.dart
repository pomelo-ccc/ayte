import 'dart:convert';
import 'dart:io';

/// Response captured by [McpHttpProbe].
class McpProbeResponse {
  const McpProbeResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.json,
  });

  final int statusCode;
  final Map<String, String> headers;
  final String body;
  final Map<String, Object?>? json;
}

/// Loopback HTTP JSON-RPC 2.0 probe for testing MCP bridges and IPC servers.
///
/// Requires `HttpOverrides.global = null` (enabled via `E2eSandbox.create(realHttp: true)`)
/// so `dart:io` [HttpClient] reaches `127.0.0.1` inside `flutter test`.
class McpHttpProbe {
  McpHttpProbe(this.endpoint, {this.bearerToken});

  final Uri endpoint;
  final String? bearerToken;
  int _nextId = 1;

  Future<McpProbeResponse> initialize({
    String protocolVersion = '2024-11-05',
    String? tokenOverride,
    bool omitAuth = false,
  }) => postJsonRpc(
    {
      'jsonrpc': '2.0',
      'id': _nextId++,
      'method': 'initialize',
      'params': {'protocolVersion': protocolVersion},
    },
    tokenOverride: tokenOverride,
    omitAuth: omitAuth,
  );

  Future<McpProbeResponse> notificationsInitialized({
    String? tokenOverride,
    bool omitAuth = false,
  }) => postJsonRpc(
    {
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
      'params': const <String, Object?>{},
    },
    tokenOverride: tokenOverride,
    omitAuth: omitAuth,
  );

  Future<McpProbeResponse> toolsList({
    String? tokenOverride,
    bool omitAuth = false,
  }) => postJsonRpc(
    {
      'jsonrpc': '2.0',
      'id': _nextId++,
      'method': 'tools/list',
      'params': const <String, Object?>{},
    },
    tokenOverride: tokenOverride,
    omitAuth: omitAuth,
  );

  Future<McpProbeResponse> toolsCall(
    String name, [
    Map<String, Object?> arguments = const {},
    String? tokenOverride,
    bool omitAuth = false,
  ]) => postJsonRpc(
    {
      'jsonrpc': '2.0',
      'id': _nextId++,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    },
    tokenOverride: tokenOverride,
    omitAuth: omitAuth,
  );

  Future<McpProbeResponse> ping({
    String? tokenOverride,
    bool omitAuth = false,
  }) => postJsonRpc(
    {'jsonrpc': '2.0', 'id': _nextId++, 'method': 'ping'},
    tokenOverride: tokenOverride,
    omitAuth: omitAuth,
  );

  Future<McpProbeResponse> postJsonRpc(
    Map<String, Object?> payload, {
    String? tokenOverride,
    bool omitAuth = false,
  }) => postRaw(
    jsonEncode(payload),
    tokenOverride: tokenOverride,
    omitAuth: omitAuth,
  );

  Future<McpProbeResponse> postRaw(
    String rawBody, {
    String contentType = 'application/json',
    String? tokenOverride,
    bool omitAuth = false,
  }) => _send(
    'POST',
    body: rawBody,
    contentType: contentType,
    tokenOverride: tokenOverride,
    omitAuth: omitAuth,
  );

  Future<McpProbeResponse> requestMethod(
    String method, {
    String? tokenOverride,
    bool omitAuth = false,
  }) => _send(method, tokenOverride: tokenOverride, omitAuth: omitAuth);

  Future<McpProbeResponse> _send(
    String method, {
    String? body,
    String contentType = 'application/json',
    String? tokenOverride,
    bool omitAuth = false,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.openUrl(method, endpoint);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
      if (!omitAuth) {
        final token = tokenOverride ?? bearerToken;
        if (token != null && token.isNotEmpty) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
      }
      if (body != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType);
        request.write(body);
      }
      final response = await request.close().timeout(const Duration(seconds: 5));
      final raw = await utf8.decoder.bind(response).join().timeout(
        const Duration(seconds: 5),
      );
      final headers = <String, String>{};
      response.headers.forEach((k, values) {
        headers[k.toLowerCase()] = values.join(', ');
      });
      Map<String, Object?>? decoded;
      try {
        final obj = jsonDecode(raw);
        if (obj is Map) decoded = obj.cast<String, Object?>();
      } on FormatException {
        // Leave decoded null for non-JSON responses (e.g. 401/405/SSE).
      }
      return McpProbeResponse(
        statusCode: response.statusCode,
        headers: headers,
        body: raw,
        json: decoded,
      );
    } finally {
      client.close(force: true);
    }
  }
}
