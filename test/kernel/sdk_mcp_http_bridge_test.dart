import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/claude_code/sdk_mcp_http_bridge.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttpOverrides extends HttpOverrides {
  HttpClient newRealClient() => super.createHttpClient(null);
}

void main() {
  late HttpClient httpClient;

  setUp(() {
    httpClient = _RealHttpOverrides().newRealClient();
  });

  tearDown(() {
    httpClient.close(force: true);
  });

  Future<({int status, HttpHeaders headers, String body})> sendHttp(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Object? jsonBody,
    String? rawBody,
  }) async {
    final req = await httpClient.openUrl(method, uri);
    headers.forEach(req.headers.set);
    if (jsonBody != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(jsonBody));
    } else if (rawBody != null) {
      req.headers.contentType = ContentType.json;
      req.write(rawBody);
    }
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    return (status: res.statusCode, headers: res.headers, body: body);
  }

  group('AyteSdkMcpBridge', () {
    const toolA = 'bridge_test_alpha';
    const toolB = 'bridge_test_beta';

    setUp(() {
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: toolA,
          description: 'Alpha tool',
          inputSchema: const {'type': 'object'},
          alwaysLoad: true,
          run: (input, call) async => jsonEncode({
            'cwd': call.cwd,
            'sessionId': call.sessionId,
            'turnId': call.turnId,
            'toolUseId': call.toolUseId,
            'input': input,
          }),
        ),
      );
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: toolB,
          description: 'Beta tool',
          inputSchema: const {'type': 'object'},
          run: (input, call) async {
            if (input['fail'] == true) {
              throw StateError('boom');
            }
            if (input['ask'] == true) {
              final decision = await call.ask?.call(
                const ApprovalRequest(
                  id: '',
                  title: 'Allow beta?',
                  toolName: 'mcp__baocode__$toolB',
                ),
              );
              return 'decision=${decision?.name}';
            }
            if (input['waitCancel'] == true) {
              await call.cancelled;
              return 'cancelled';
            }
            return 'ok:${input['v']}';
          },
        ),
      );
    });

    tearDown(() {
      ClaudeSdkTools.unregister(toolA);
      ClaudeSdkTools.unregister(toolB);
      ClaudeSdkTools.instruct('bridge_test', null);
    });

    test(
      'binds loopback with 256-bit CSPRNG token and enforces auth & HTTP methods',
      () async {
        final bridge = await AyteSdkMcpBridge.start(cwd: '/work');
        addTearDown(() => bridge.close(force: true));

        expect(bridge.port, greaterThan(0));
        expect(bridge.token, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(bridge.endpointUri.toString(), 'http://127.0.0.1:${bridge.port}/mcp');
        expect(bridge.mcpServerConfig(), {
          'url': 'http://127.0.0.1:${bridge.port}/mcp',
          'headers': {'Authorization': 'Bearer ${bridge.token}'},
        });
        expect(bridge.mcpServerConfig(type: 'http')['type'], 'http');

        // Unauthenticated /.well-known/* returns 404.
        final wellKnown = await sendHttp(
          'GET',
          Uri.parse('http://127.0.0.1:${bridge.port}/.well-known/oauth-protected-resource/mcp'),
        );
        expect(wellKnown.status, 404);

        // Missing or invalid auth on /mcp returns 401.
        final noAuth = await sendHttp('POST', bridge.endpointUri, jsonBody: {'id': 1, 'method': 'ping'});
        expect(noAuth.status, 401);

        final badAuth = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: {'Authorization': 'Bearer ${'0' * 64}'},
          jsonBody: {'id': 1, 'method': 'ping'},
        );
        expect(badAuth.status, 401);

        final badPathToken = await sendHttp(
          'POST',
          Uri.parse('http://127.0.0.1:${bridge.port}/mcp/badtoken'),
          jsonBody: {'id': 1, 'method': 'ping'},
        );
        expect(badPathToken.status, 401);

        // GET /mcp with auth returns 405 with Allow: POST, DELETE.
        final getRes = await sendHttp(
          'GET',
          bridge.endpointUri,
          headers: {'Authorization': 'Bearer ${bridge.token}'},
        );
        expect(getRes.status, 405);
        expect(getRes.headers.value('allow'), contains('POST'));

        // DELETE /mcp with auth returns 200.
        final delRes = await sendHttp(
          'DELETE',
          bridge.endpointUri,
          headers: {'Authorization': 'Bearer ${bridge.token}'},
        );
        expect(delRes.status, 200);

        // Path-token fallback (/mcp/<token>) works for ping.
        final pathTokenRes = await sendHttp(
          'POST',
          Uri.parse('http://127.0.0.1:${bridge.port}/mcp/${bridge.token}'),
          jsonBody: {'jsonrpc': '2.0', 'id': 9, 'method': 'ping'},
        );
        expect(pathTokenRes.status, 200);
        expect(jsonDecode(pathTokenRes.body), {
          'jsonrpc': '2.0',
          'id': 9,
          'result': <String, Object?>{},
        });
      },
    );

    test(
      'handles server/discover, initialize, notifications, batch, invalid JSON, and antigravity/alwaysLoad',
      () async {
        ClaudeSdkTools.instruct('bridge_test', 'Follow bridge rules.');
        final bridge = await AyteSdkMcpBridge.start(
          cwd: '/work',
          includeAntigravityAlwaysLoad: true,
        );
        addTearDown(() => bridge.close(force: true));
        final auth = {'Authorization': 'Bearer ${bridge.token}'};

        final parseErr = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          rawBody: '{not json',
        );
        expect(parseErr.status, 400);
        expect((jsonDecode(parseErr.body) as Map)['error'], containsPair('code', -32700));

        final emptyBatch = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: const <Object?>[],
        );
        expect(emptyBatch.status, 400);

        final discover = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {'jsonrpc': '2.0', 'id': 1, 'method': 'server/discover'},
        );
        expect(discover.status, 200);
        expect((jsonDecode(discover.body) as Map)['result'], {
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': ClaudeSdkTools.server, 'version': '1.0.0'},
        });

        final init = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'initialize',
            'params': {'protocolVersion': '2025-11-25'},
          },
        );
        expect(init.status, 200);
        expect(init.headers.value('mcp-session-id'), isNotEmpty);
        final initResult = (jsonDecode(init.body) as Map)['result'] as Map;
        expect(initResult['instructions'], 'Follow bridge rules.');

        final notif = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {'jsonrpc': '2.0', 'method': 'notifications/initialized', 'params': {}},
        );
        expect(notif.status, 202);
        expect(notif.body, isEmpty);

        // tools/list adds antigravity/alwaysLoad without mutating ClaudeSdkTools.handle.
        final listRes = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'},
        );
        expect(listRes.status, 200);
        final tools = ((jsonDecode(listRes.body) as Map)['result'] as Map)['tools'] as List;
        final alpha = tools.cast<Map>().firstWhere((t) => t['name'] == toolA);
        expect(alpha['_meta'], {
          'anthropic/alwaysLoad': true,
          'antigravity/alwaysLoad': true,
        });

        final directList = await ClaudeSdkTools.handle(
          {'id': 1, 'method': 'tools/list'},
          const ClaudeSdkCall(cwd: '/work'),
        );
        final directAlpha = ((directList['result'] as Map)['tools'] as List)
            .cast<Map>()
            .firstWhere((t) => t['name'] == toolA);
        expect(directAlpha['_meta'], {'anthropic/alwaysLoad': true});

        // Batch containing notification + ping returns only ping response.
        final batchRes = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: [
            {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
            {'jsonrpc': '2.0', 'id': 4, 'method': 'ping'},
          ],
        );
        expect(batchRes.status, 200);
        final batchDecoded = jsonDecode(batchRes.body) as List;
        expect(batchDecoded, hasLength(1));
        expect((batchDecoded.single as Map)['id'], 4);

        // Explicit id: null preserves null id; invalid UTF-8 bytes return -32700.
        final nullIdRes = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {'jsonrpc': '2.0', 'id': null, 'method': 'ping'},
        );
        expect(nullIdRes.status, 200);
        final nullIdMap = jsonDecode(nullIdRes.body) as Map;
        expect(nullIdMap.containsKey('id'), isTrue);
        expect(nullIdMap['id'], isNull);

        final badUtf8Req = await httpClient.openUrl('POST', bridge.endpointUri);
        badUtf8Req.headers.set('Authorization', 'Bearer ${bridge.token}');
        badUtf8Req.add(const [0xff, 0xfe, 0xfd]);
        final badUtf8Res = await badUtf8Req.close();
        expect(badUtf8Res.statusCode, 400);
        final badUtf8Body = jsonDecode(await utf8.decoder.bind(badUtf8Res).join()) as Map;
        expect((badUtf8Body['error'] as Map)['code'], -32700);
      },
    );

    test(
      'routes tools/call with dynamic sessionId, turnId, conversation_id meta, ask, cancellation, and disabled toggling',
      () async {
        String? activeTurn = 'turn-1';
        String? providerSession;
        final observedConvIds = <String>[];
        var cancelCompleter = Completer<void>();

        final bridge = await AyteSdkMcpBridge.start(
          cwd: '/repo',
          sessionIdProvider: () => providerSession,
          turnIdProvider: () => activeTurn,
          cancelledProvider: () => cancelCompleter.future,
          ask: (req) async => ApprovalDecision.allowOnce,
          onConversationIdObserved: observedConvIds.add,
        );
        addTearDown(() => bridge.close(force: true));
        final auth = {'Authorization': 'Bearer ${bridge.token}'};

        // Call 1: before sessionId binds, _meta conversation_id is observed and used.
        final call1 = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {
            'jsonrpc': '2.0',
            'id': 10,
            'method': 'tools/call',
            'params': {
              'name': toolA,
              'arguments': {'x': 1},
              '_meta': {
                'antigravity.google/conversation_id': 'agy-conv-1',
                'claudecode/toolUseId': 'tu-10',
              },
            },
          },
        );
        expect(observedConvIds, ['agy-conv-1']);
        final payload1 = jsonDecode(
          ((((jsonDecode(call1.body) as Map)['result'] as Map)['content'] as List)
                  .single as Map)['text']
              as String,
        ) as Map;
        expect(payload1['cwd'], '/repo');
        expect(payload1['sessionId'], 'agy-conv-1');
        expect(payload1['turnId'], 'turn-1');
        expect(payload1['toolUseId'], 'tu-10');

        // Update sessionId and turnId dynamically.
        bridge.updateSessionId('bound-session-2');
        activeTurn = 'turn-2';
        final call2 = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {
            'jsonrpc': '2.0',
            'id': 11,
            'method': 'tools/call',
            'params': {'name': toolA, 'arguments': const <String, Object?>{}},
          },
        );
        final payload2 = jsonDecode(
          ((((jsonDecode(call2.body) as Map)['result'] as Map)['content'] as List)
                  .single as Map)['text']
              as String,
        ) as Map;
        expect(payload2['sessionId'], 'bound-session-2');
        expect(payload2['turnId'], 'turn-2');

        // Ask callback forwarding.
        final askRes = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {
            'jsonrpc': '2.0',
            'id': 12,
            'method': 'tools/call',
            'params': {
              'name': toolB,
              'arguments': {'ask': true},
            },
          },
        );
        expect(
          ((((jsonDecode(askRes.body) as Map)['result'] as Map)['content'] as List)
              .single as Map)['text'],
          'decision=allowOnce',
        );

        // Error propagation returns isError: true.
        final errRes = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {
            'jsonrpc': '2.0',
            'id': 13,
            'method': 'tools/call',
            'params': {
              'name': toolB,
              'arguments': {'fail': true},
            },
          },
        );
        expect(((jsonDecode(errRes.body) as Map)['result'] as Map)['isError'], isTrue);

        // Turn cancellation triggers cancelled future.
        final waitFuture = sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {
            'jsonrpc': '2.0',
            'id': 14,
            'method': 'tools/call',
            'params': {
              'name': toolB,
              'arguments': {'waitCancel': true},
            },
          },
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        cancelCompleter.complete();
        final cancelRes = await waitFuture;
        expect(
          ((((jsonDecode(cancelRes.body) as Map)['result'] as Map)['content'] as List)
              .single as Map)['text'],
          'cancelled',
        );

        // Disable toolB dynamically.
        bridge.updateDisabled(disabledTools: {toolB});
        final listAfterDisable = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {'jsonrpc': '2.0', 'id': 15, 'method': 'tools/list'},
        );
        final namesAfterDisable =
            (((jsonDecode(listAfterDisable.body) as Map)['result'] as Map)['tools']
                    as List)
                .cast<Map>()
                .map((t) => t['name'])
                .toList();
        expect(namesAfterDisable, contains(toolA));
        expect(namesAfterDisable, isNot(contains(toolB)));

        final callDisabled = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {
            'jsonrpc': '2.0',
            'id': 16,
            'method': 'tools/call',
            'params': {'name': toolB, 'arguments': const <String, Object?>{}},
          },
        );
        expect(
          ((jsonDecode(callDisabled.body) as Map)['result'] as Map)['isError'],
          isTrue,
        );

        // Disable whole server dynamically.
        bridge.updateDisabled(serverDisabled: true);
        final listServerDisabled = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {'jsonrpc': '2.0', 'id': 17, 'method': 'tools/list'},
        );
        expect(
          ((jsonDecode(listServerDisabled.body) as Map)['result'] as Map)['tools'],
          isEmpty,
        );

        // Idempotent close.
        await bridge.close();
        await bridge.close();
      },
    );

    test(
      'handles notifications/cancelled after mid-call updateSessionId and isolates concurrent Turn-1 bridges',
      () async {
        // (a) Mid-call updateSessionId before notifications/cancelled.
        final singleBridge = await AyteSdkMcpBridge.start(cwd: '/repo');
        addTearDown(() => singleBridge.close(force: true));
        final singleAuth = {'Authorization': 'Bearer ${singleBridge.token}'};

        final midCallFuture = sendHttp(
          'POST',
          singleBridge.endpointUri,
          headers: singleAuth,
          jsonBody: {
            'jsonrpc': '2.0',
            'id': 601,
            'method': 'tools/call',
            'params': {
              'name': toolB,
              'arguments': {'waitCancel': true},
            },
          },
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        singleBridge.updateSessionId('conv-late-bound');

        final midCancelNotif = await sendHttp(
          'POST',
          singleBridge.endpointUri,
          headers: singleAuth,
          jsonBody: {
            'jsonrpc': '2.0',
            'method': 'notifications/cancelled',
            'params': {'requestId': 601},
          },
        );
        expect(midCancelNotif.status, 202);

        final midCallRes = await midCallFuture.timeout(
          const Duration(seconds: 2),
        );
        expect(midCallRes.status, 200);
        expect(
          ((((jsonDecode(midCallRes.body) as Map)['result'] as Map)['content']
                  as List)
              .single as Map)['text'],
          'cancelled',
        );

        // (b) Two concurrent Turn-1 bridges (sessionId == null) both using id: 1.
        final b1 = await AyteSdkMcpBridge.start(cwd: '/repo');
        final b2 = await AyteSdkMcpBridge.start(cwd: '/repo');
        addTearDown(() async {
          await b1.close(force: true);
          await b2.close(force: true);
        });
        final auth1 = {'Authorization': 'Bearer ${b1.token}'};
        final auth2 = {'Authorization': 'Bearer ${b2.token}'};

        var c1Done = false;
        var c2Done = false;
        final c1Future = sendHttp(
          'POST',
          b1.endpointUri,
          headers: auth1,
          jsonBody: {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': toolB,
              'arguments': {'waitCancel': true},
            },
          },
        ).then((res) {
          c1Done = true;
          return res;
        });

        await Future<void>.delayed(const Duration(milliseconds: 30));
        final c2Future = sendHttp(
          'POST',
          b2.endpointUri,
          headers: auth2,
          jsonBody: {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': toolB,
              'arguments': {'waitCancel': true},
            },
          },
        ).then((res) {
          c2Done = true;
          return res;
        });

        await Future<void>.delayed(const Duration(milliseconds: 30));
        // Cancel ONLY b1.
        final cancelB1 = await sendHttp(
          'POST',
          b1.endpointUri,
          headers: auth1,
          jsonBody: {
            'jsonrpc': '2.0',
            'method': 'notifications/cancelled',
            'params': {'requestId': 1},
          },
        );
        expect(cancelB1.status, 202);

        final c1Res = await c1Future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(c1Done, isTrue);
        expect(c2Done, isFalse);
        expect(
          ((((jsonDecode(c1Res.body) as Map)['result'] as Map)['content']
                  as List)
              .single as Map)['text'],
          'cancelled',
        );

        // Now cancel b2 cleanly and verify it finishes normally.
        final cancelB2 = await sendHttp(
          'POST',
          b2.endpointUri,
          headers: auth2,
          jsonBody: {
            'jsonrpc': '2.0',
            'method': 'notifications/cancelled',
            'params': {'requestId': 1},
          },
        );
        expect(cancelB2.status, 202);
        final c2Res = await c2Future.timeout(const Duration(seconds: 2));
        expect(c2Done, isTrue);
        expect(
          ((((jsonDecode(c2Res.body) as Map)['result'] as Map)['content']
                  as List)
              .single as Map)['text'],
          'cancelled',
        );
      },
    );

    test(
      'returns JSON-RPC -32602 (never HTTP 500) on malformed params, _meta, name, arguments, and isolates batch errors',
      () async {
        final bridge = await AyteSdkMcpBridge.start(cwd: '/work');
        addTearDown(() => bridge.close(force: true));
        final auth = {'Authorization': 'Bearer ${bridge.token}'};

        // Wrong path token with valid Bearer header must still be rejected (401).
        final mismatchedPath = await sendHttp(
          'POST',
          Uri.parse('http://127.0.0.1:${bridge.port}/mcp/wrongtoken'),
          headers: auth,
          jsonBody: {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
        );
        expect(mismatchedPath.status, 401);

        Future<Map<String, Object?>> postRpc(Object payload) async {
          final res = await sendHttp(
            'POST',
            bridge.endpointUri,
            headers: auth,
            jsonBody: payload,
          );
          expect(res.status, 200);
          return (jsonDecode(res.body) as Map).cast<String, Object?>();
        }

        // params: ["bad"]
        final listParams = await postRpc({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': ['bad'],
        });
        expect((listParams['error'] as Map)['code'], -32602);
        expect(listParams['id'], 1);

        // _meta: "str"
        final badMeta = await postRpc({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': {
            'name': toolB,
            'arguments': {'v': 1},
            '_meta': 'str',
          },
        });
        expect((badMeta['error'] as Map)['code'], -32602);
        expect(badMeta['id'], 2);

        // name: 123
        final intName = await postRpc({
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'tools/call',
          'params': {'name': 123, 'arguments': const <String, Object?>{}},
        });
        expect((intName['error'] as Map)['code'], -32602);
        expect(intName['id'], 3);

        // arguments: []
        final listArgs = await postRpc({
          'jsonrpc': '2.0',
          'id': 4,
          'method': 'tools/call',
          'params': {'name': toolB, 'arguments': const <Object?>[]},
        });
        expect((listArgs['error'] as Map)['code'], -32602);
        expect(listArgs['id'], 4);

        // Mixed batch: malformed items return -32602 while valid sibling succeeds.
        final batchRes = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: [
            {
              'jsonrpc': '2.0',
              'id': 10,
              'method': 'tools/call',
              'params': ['bad'],
            },
            {
              'jsonrpc': '2.0',
              'id': 11,
              'method': 'tools/call',
              'params': {'name': 123, 'arguments': const <String, Object?>{}},
            },
            {
              'jsonrpc': '2.0',
              'id': 12,
              'method': 'tools/call',
              'params': {
                'name': toolB,
                'arguments': {'v': 42},
              },
            },
          ],
        );
        expect(batchRes.status, 200);
        final batchItems = (jsonDecode(batchRes.body) as List)
            .cast<Map<String, Object?>>();
        expect(batchItems, hasLength(3));
        expect(batchItems[0]['id'], 10);
        expect((batchItems[0]['error'] as Map)['code'], -32602);
        expect(batchItems[1]['id'], 11);
        expect((batchItems[1]['error'] as Map)['code'], -32602);
        expect(batchItems[2]['id'], 12);
        expect(
          ((((batchItems[2]['result'] as Map)['content'] as List).single
              as Map)['text']),
          'ok:42',
        );

        // Direct ClaudeSdkTools.handle also returns -32602 on malformed inputs.
        final directBadParams = await ClaudeSdkTools.handle({
          'id': 20,
          'method': 'tools/call',
          'params': ['bad'],
        }, const ClaudeSdkCall(cwd: '/work'));
        expect((directBadParams['error'] as Map)['code'], -32602);

        final directBadArgs = await ClaudeSdkTools.handle({
          'id': 21,
          'method': 'tools/call',
          'params': {'name': toolB, 'arguments': const <Object?>[]},
        }, const ClaudeSdkCall(cwd: '/work'));
        expect((directBadArgs['error'] as Map)['code'], -32602);
      },
    );

    test(
      'preserves explicit id: null across initialize, tools/list, tools/call, unknown methods, and direct handle',
      () async {
        final bridge = await AyteSdkMcpBridge.start(cwd: '/work');
        addTearDown(() => bridge.close(force: true));
        final auth = {'Authorization': 'Bearer ${bridge.token}'};

        Future<Map<String, Object?>> postRpc(Map<String, Object?> body) async {
          final res = await sendHttp(
            'POST',
            bridge.endpointUri,
            headers: auth,
            jsonBody: body,
          );
          expect(res.status, 200);
          final decoded = (jsonDecode(res.body) as Map).cast<String, Object?>();
          expect(decoded.containsKey('id'), isTrue);
          expect(decoded['id'], isNull);
          return decoded;
        }

        await postRpc({
          'jsonrpc': '2.0',
          'id': null,
          'method': 'initialize',
          'params': {'protocolVersion': '2025-11-25'},
        });
        await postRpc({
          'jsonrpc': '2.0',
          'id': null,
          'method': 'tools/list',
        });
        final validCall = await postRpc({
          'jsonrpc': '2.0',
          'id': null,
          'method': 'tools/call',
          'params': {
            'name': toolB,
            'arguments': {'v': 'null-id'},
          },
        });
        expect(
          ((((validCall['result'] as Map)['content'] as List).single
              as Map)['text']),
          'ok:null-id',
        );
        final errCall = await postRpc({
          'jsonrpc': '2.0',
          'id': null,
          'method': 'tools/call',
          'params': {
            'name': toolB,
            'arguments': {'fail': true},
          },
        });
        expect((errCall['result'] as Map)['isError'], isTrue);

        final unknown = await postRpc({
          'jsonrpc': '2.0',
          'id': null,
          'method': 'unknown/method',
        });
        expect((unknown['error'] as Map)['code'], -32601);

        // Direct ClaudeSdkTools.handle preserves explicit id: null while omitted id stays 0.
        for (final msg in [
          const {'id': null, 'method': 'initialize'},
          const {'id': null, 'method': 'tools/list'},
          const {
            'id': null,
            'method': 'tools/call',
            'params': {
              'name': toolB,
              'arguments': {'v': 1},
            },
          },
          const {
            'id': null,
            'method': 'tools/call',
            'params': ['bad'],
          },
          const {
            'id': null,
            'method': 'tools/call',
            'params': {'name': ''},
          },
          const {
            'id': null,
            'method': 'tools/call',
            'params': {'name': toolB, 'arguments': <Object?>[]},
          },
          const {'id': null, 'method': 'unknown/method'},
        ]) {
          final res = await ClaudeSdkTools.handle(
            msg,
            const ClaudeSdkCall(cwd: '/work'),
          );
          expect(res.containsKey('id'), isTrue);
          expect(res['id'], isNull);
        }

        final omittedId = await ClaudeSdkTools.handle(
          const {'method': 'tools/list'},
          const ClaudeSdkCall(cwd: '/work'),
        );
        expect(omittedId['id'], 0);
      },
    );

    test(
      'guards synchronous throw in cancelledProvider without HTTP 500, batch abort, or leaked _inFlightCancels',
      () async {
        final bridge = await AyteSdkMcpBridge.start(
          cwd: '/work',
          cancelledProvider: () => throw StateError('sync cancelledProvider boom'),
        );
        addTearDown(() => bridge.close(force: true));
        final auth = {'Authorization': 'Bearer ${bridge.token}'};

        // Single waitCancel call returns HTTP 200 and cleans up _inFlightCancels.
        final singleRes = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: {
            'jsonrpc': '2.0',
            'id': 901,
            'method': 'tools/call',
            'params': {
              'name': toolB,
              'arguments': {'waitCancel': true},
            },
          },
        ).timeout(const Duration(seconds: 2));
        expect(singleRes.status, 200);
        final singleMap = jsonDecode(singleRes.body) as Map;
        expect(singleMap['id'], 901);
        expect(
          ((((singleMap['result'] as Map)['content'] as List).single
              as Map)['text']),
          'cancelled',
        );
        expect(bridge.inFlightCancelCountForTesting, 0);

        // Mixed batch preserves all siblings cleanly.
        final batchRes = await sendHttp(
          'POST',
          bridge.endpointUri,
          headers: auth,
          jsonBody: [
            {
              'jsonrpc': '2.0',
              'id': 902,
              'method': 'tools/call',
              'params': {
                'name': toolB,
                'arguments': {'waitCancel': true},
              },
            },
            {
              'jsonrpc': '2.0',
              'id': 903,
              'method': 'tools/call',
              'params': {
                'name': toolB,
                'arguments': {'v': 'sibling-ok'},
              },
            },
            {
              'jsonrpc': '2.0',
              'id': 904,
              'method': 'ping',
            },
          ],
        ).timeout(const Duration(seconds: 2));
        expect(batchRes.status, 200);
        final batchItems = (jsonDecode(batchRes.body) as List)
            .cast<Map<String, Object?>>();
        expect(batchItems, hasLength(3));
        expect(batchItems[0]['id'], 902);
        expect(
          ((((batchItems[0]['result'] as Map)['content'] as List).single
              as Map)['text']),
          'cancelled',
        );
        expect(batchItems[1]['id'], 903);
        expect(
          ((((batchItems[1]['result'] as Map)['content'] as List).single
              as Map)['text']),
          'ok:sibling-ok',
        );
        expect(batchItems[2]['id'], 904);
        expect(batchItems[2]['result'], <String, Object?>{});
        expect(bridge.inFlightCancelCountForTesting, 0);
      },
    );

    test(
      'enforces normalized disabledTools in constructor and updateDisabled across tools/list and tools/call',
      () async {
        const dottedTool = 'bridge_probe.dotted-tool';
        const plainTool = 'bridge_probe_plain';
        var dottedRuns = 0;

        ClaudeSdkTools.register(
          ClaudeSdkTool(
            name: dottedTool,
            description: 'Dotted probe tool',
            inputSchema: const {'type': 'object'},
            run: (input, call) async {
              dottedRuns++;
              return 'dotted-ok:${input['v']}';
            },
          ),
        );
        ClaudeSdkTools.register(
          ClaudeSdkTool(
            name: plainTool,
            description: 'Plain probe tool',
            inputSchema: const {'type': 'object'},
            run: (input, call) async => 'plain-ok',
          ),
        );
        addTearDown(() {
          ClaudeSdkTools.unregister(dottedTool);
          ClaudeSdkTools.unregister(plainTool);
        });

        final bridge = await AyteSdkMcpBridge.start(
          cwd: '/work',
          disabledTools: const {'bridge_probe_dotted-tool'},
        );
        addTearDown(() => bridge.close(force: true));
        final auth = {'Authorization': 'Bearer ${bridge.token}'};

        Future<List<String>> listNames() async {
          final res = await sendHttp(
            'POST',
            bridge.endpointUri,
            headers: auth,
            jsonBody: {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'},
          );
          expect(res.status, 200);
          return (((jsonDecode(res.body) as Map)['result'] as Map)['tools']
                  as List)
              .cast<Map>()
              .map((t) => t['name'] as String)
              .toList();
        }

        Future<Map<String, Object?>> callTool(String name) async {
          final res = await sendHttp(
            'POST',
            bridge.endpointUri,
            headers: auth,
            jsonBody: {
              'jsonrpc': '2.0',
              'id': 2,
              'method': 'tools/call',
              'params': {'name': name, 'arguments': {'v': 7}},
            },
          );
          expect(res.status, 200);
          return (jsonDecode(res.body) as Map).cast<String, Object?>();
        }

        // Constructor normalized name hides and blocks the dotted tool.
        final initialNames = await listNames();
        expect(initialNames, contains(plainTool));
        expect(initialNames, isNot(contains(dottedTool)));
        final blockedInitial = await callTool(dottedTool);
        expect((blockedInitial['result'] as Map)['isError'], isTrue);
        expect(dottedRuns, 0);

        // Re-enable all tools.
        bridge.updateDisabled(disabledTools: const {});
        final enabledNames = await listNames();
        expect(enabledNames, contains(dottedTool));
        final allowedRes = await callTool(dottedTool);
        expect((allowedRes['result'] as Map)['isError'], isNot(isTrue));
        expect(dottedRuns, 1);

        // Dynamically disable via normalized name again.
        bridge.updateDisabled(disabledTools: const {'bridge_probe_dotted-tool'});
        final disabledNames = await listNames();
        expect(disabledNames, isNot(contains(dottedTool)));
        final blockedAgain = await callTool(dottedTool);
        expect((blockedAgain['result'] as Map)['isError'], isTrue);
        expect(dottedRuns, 1);
      },
    );
  });
}
