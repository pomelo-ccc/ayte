import 'dart:async';

import 'package:baocode/debug/common/debug_model.dart';
import 'package:baocode/debug/common/debug_types.dart';
import 'package:baocode/debug/common/repl_model.dart';
import 'package:baocode/debug/session/debug_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'model/mock_debug.dart';

class _LazyScriptedAdapter extends MockDebugAdapter {
  int _seq = 0;
  final List<Json> requests = [];
  Completer<void>? holdNextVariables;

  Json Function(Json args)? onEvaluate;
  Json Function(Json args)? onVariables;

  void respond(
    Json request, {
    Json? body,
    bool success = true,
    String? message,
    String? commandOverride,
  }) {
    acceptMessage({
      'seq': ++_seq,
      'type': 'response',
      'request_seq': request['seq'],
      'command': commandOverride ?? request['command'],
      'success': success,
      'message': ?message,
      'body': ?body,
    });
  }

  @override
  void send(Json message) {
    if (message['type'] != 'request') return;
    requests.add(message);
    final cmd = message['command'];
    final args = message.obj('arguments') ?? const {};

    if (cmd == 'variables' && holdNextVariables != null) {
      final gate = holdNextVariables!;
      holdNextVariables = null;
      unawaited(
        gate.future.then((_) {
          if (onVariables != null) {
            final res = onVariables!(args);
            respond(
              message,
              body: res.obj('body'),
              success: res['success'] as bool? ?? true,
              message: res.str('message'),
              commandOverride: res.str('command'),
            );
          } else {
            respond(message, body: {'variables': <Json>[]});
          }
        }),
      );
      return;
    }

    Timer.run(() {
      if (cmd == 'evaluate' && onEvaluate != null) {
        final res = onEvaluate!(args);
        respond(
          message,
          body: res.obj('body'),
          success: res['success'] as bool? ?? true,
          message: res.str('message'),
          commandOverride: res.str('command'),
        );
      } else if (cmd == 'variables' && onVariables != null) {
        final res = onVariables!(args);
        respond(
          message,
          body: res.obj('body'),
          success: res['success'] as bool? ?? true,
          message: res.str('message'),
          commandOverride: res.str('command'),
        );
      } else {
        respond(message, body: {});
      }
    });
  }
}

DebugSession _attachSession(_LazyScriptedAdapter adapter) {
  final model = createMockDebugModel();
  final service = createMockDebugService();
  final session = createTestSession(model, service);
  session.raw = createMockAdapterRawSession(adapter);
  return session;
}

void main() {
  test('RawObjectReplElement.evaluateLazy completes as a safe no-op', () async {
    final element = RawObjectReplElement(
      'raw-1',
      'payload',
      {'a': 1, 'b': [2, 3]},
    );
    await expectLater(element.evaluateLazy(), completes);
    expect(element.getSession(), isNull);
    expect(element.value, 'Object');
    expect((await element.getChildren()).length, 2);
  });

  test('ReplEvaluationResult and addReplExpression forward keepLazyVars and location', () async {
    final adapter = _LazyScriptedAdapter()
      ..onEvaluate = ((args) => {
        'body': {
          'result': '<lazy>',
          'variablesReference': 42,
          'type': 'LazyBox',
          'presentationHint': {'lazy': true},
        },
      })
      ..onVariables = ((args) => {
        'body': {
          'variables': [
            {
              'name': '',
              'value': 'expanded(42)',
              'type': 'ResolvedBox',
              'variablesReference': 7,
              'namedVariables': 1,
            },
          ],
        },
      });

    final session = _attachSession(adapter);
    final repl = ReplModel();
    const loc = (
      line: 18,
      column: 4,
      source: {'name': 'main.dart', 'path': '/app/main.dart'},
    );

    // 1. keepLazyVars: true keeps the lazy placeholder without sending variables yet.
    await repl.addReplExpression(
      session,
      null,
      'deferredExpr',
      keepLazyVars: true,
      location: loc,
    );

    final evalReq = adapter.requests.firstWhere((r) => r['command'] == 'evaluate');
    final evalArgs = evalReq.obj('arguments')!;
    expect(evalArgs['expression'], 'deferredExpr');
    expect(evalArgs['line'], 18);
    expect(evalArgs['column'], 4);
    expect(evalArgs.obj('source')?['path'], '/app/main.dart');
    expect(adapter.requests.where((r) => r['command'] == 'variables'), isEmpty);

    final results = repl.getReplElements().whereType<ReplEvaluationResult>().toList();
    expect(results, hasLength(1));
    final kept = results.single;
    expect(kept.value, '<lazy>');
    expect(kept.reference, 42);
    expect(kept.hasChildren, isFalse);

    // 2. keepLazyVars: false auto-expands immediately via variables and updates type.
    await repl.addReplExpression(session, null, 'autoExpandExpr');
    expect(adapter.requests.where((r) => r['command'] == 'variables'), hasLength(1));
    final autoResult = repl.getReplElements().whereType<ReplEvaluationResult>().last;
    expect(autoResult.value, 'expanded(42)');
    expect(autoResult.type, 'ResolvedBox');
    expect(autoResult.reference, 7);
    expect(autoResult.hasChildren, isTrue);

    repl.dispose();
  });

  test('ReplModel.evaluateLazy resolves lazy ReplEvaluationResult via variables and notifies listeners', () async {
    final adapter = _LazyScriptedAdapter()
      ..onEvaluate = ((args) => {
        'body': {
          'result': '(click to load)',
          'variablesReference': 55,
          'presentationHint': {'lazy': true},
        },
      })
      ..onVariables = ((args) {
        expect(args['variablesReference'], 55);
        return {
          'body': {
            'variables': [
              {
                'name': '',
                'value': '{loaded: true}',
                'type': 'Map<String, bool>',
                'variablesReference': 9,
                'namedVariables': 1,
              },
            ],
          },
        };
      });

    final session = _attachSession(adapter);
    final repl = ReplModel();
    await repl.addReplExpression(session, null, 'heavyMap', keepLazyVars: true);
    final result = repl.getReplElements().whereType<ReplEvaluationResult>().single;

    final firedElements = <ReplElement?>[];
    var notifyCount = 0;
    repl.onDidChangeElements(firedElements.add);
    repl.addListener(() => notifyCount++);

    await repl.evaluateLazy(result);

    expect(result.value, '{loaded: true}');
    expect(result.type, 'Map<String, bool>');
    expect(result.reference, 9);
    expect(result.hasChildren, isTrue);
    expect(result.available, isTrue);
    expect(firedElements, [result]);
    expect(notifyCount, 1);

    repl.dispose();
  });

  test('ReplModel.evaluateLazy falls back to DAP evaluate when no lazy variablesReference exists', () async {
    final adapter = _LazyScriptedAdapter()
      ..onEvaluate = ((args) => {
        'body': {
          'result': '99',
          'type': 'int',
          'variablesReference': 0,
        },
      });

    final session = _attachSession(adapter);
    final repl = ReplModel();

    // Case A: ReplEvaluationResult with lazy hint and variablesReference == 0
    final lazyNoRef = ReplEvaluationResult('computeAnswer()')
      ..presentationHint = {'lazy': true}
      ..value = 'lazy';
    final events = <ReplElement?>[];
    repl.onDidChangeElements(events.add);

    await repl.evaluateLazy(lazyNoRef, session: session, context: 'repl');
    expect(lazyNoRef.value, '99');
    expect(lazyNoRef.type, 'int');
    expect(lazyNoRef.available, isTrue);
    expect(events, [lazyNoRef]);

    // Case B: Empty un-evaluated ReplEvaluationResult evaluates once; second call does not re-evaluate
    final fresh = ReplEvaluationResult('x + 1');
    await repl.evaluateLazy(fresh, session: session);
    expect(fresh.value, '99');
    final evaluateCount = adapter.requests.where((r) => r['command'] == 'evaluate').length;
    await repl.evaluateLazy(fresh, session: session);
    expect(
      adapter.requests.where((r) => r['command'] == 'evaluate').length,
      evaluateCount,
    );

    repl.dispose();
  });

  test('ReplModel.evaluateLazy resolves lazy Variable and notifies listeners', () async {
    final adapter = _LazyScriptedAdapter()
      ..onVariables = ((args) => {
        'body': {
          'variables': [
            {
              'name': 'secret',
              'value': '"resolved"',
              'type': 'String',
              'variablesReference': 0,
            },
          ],
        },
      });

    final session = _attachSession(adapter);
    final repl = ReplModel();
    var notified = 0;
    repl.addListener(() => notified++);

    final parent = ExpressionContainer(session, 1, 1, 'scope:local');
    final variable = Variable(
      session,
      1,
      parent,
      77,
      'secret',
      'secret',
      '<lazy>',
      0,
      0,
      null,
      const {'lazy': true},
      available: true,
    );

    await repl.evaluateLazy(variable);
    expect(variable.value, '"resolved"');
    expect(variable.type, 'String');
    expect(notified, 1);

    repl.dispose();
  });

  test('ReplModel.evaluateLazy handles DAP errors, cancellation, null/inactive sessions, and mid-flight dispose', () async {
    // 1. DAP error on variables
    final errorAdapter = _LazyScriptedAdapter()
      ..onVariables = ((args) => {
        'success': false,
        'message': 'Evaluation timed out',
      });
    final errorSession = _attachSession(errorAdapter);
    final repl = ReplModel();
    final errResult = ReplEvaluationResult('slow()')
      ..session = errorSession
      ..reference = 10
      ..memoryReference = '0x10'
      ..presentationHint = {'lazy': true}
      ..value = '<lazy>';

    await repl.evaluateLazy(errResult);
    expect(errResult.available, isFalse);
    expect(errResult.value, 'Evaluation timed out');
    expect(errResult.reference, 0);
    expect(errResult.memoryReference, isNull);

    // 2. Cancellation (DebugCancelledError) leaves state untouched
    final cancelAdapter = _LazyScriptedAdapter()
      ..onVariables = ((args) => {
        'success': false,
        'command': 'canceled',
        'message': 'canceled',
      });
    final cancelSession = _attachSession(cancelAdapter);
    final cancelResult = ReplEvaluationResult('cancelMe()')
      ..session = cancelSession
      ..reference = 11
      ..presentationHint = {'lazy': true}
      ..value = '<still lazy>';

    await repl.evaluateLazy(cancelResult);
    expect(cancelResult.value, '<still lazy>');
    expect(cancelResult.available, isTrue);

    // 2b. D-10: Cancellation on fallback DAP evaluate branch also leaves state untouched
    final evalCancelAdapter = _LazyScriptedAdapter()
      ..onEvaluate = ((args) => {
        'success': false,
        'command': 'canceled',
        'message': 'canceled',
      });
    final evalCancelSession = _attachSession(evalCancelAdapter);
    final evalCancelResult = ReplEvaluationResult('lazyEvalCancel()')
      ..session = evalCancelSession
      ..reference = 0
      ..presentationHint = {'lazy': true}
      ..value = '<lazy placeholder>';
    var evalCancelNotifies = 0;
    repl.addListener(() => evalCancelNotifies++);
    await repl.evaluateLazy(evalCancelResult, session: evalCancelSession);
    expect(evalCancelResult.value, '<lazy placeholder>');
    expect(evalCancelResult.available, isTrue);
    expect(evalCancelNotifies, 0);

    // 3. Null / zero-ref / disposed session guards on ExpressionContainer.evaluateLazy
    final noSession = ReplEvaluationResult('orphan')
      ..reference = 12
      ..presentationHint = {'lazy': true}
      ..value = '<orphan>';
    await expectLater(noSession.evaluateLazy(), completes);
    await expectLater(repl.evaluateLazy(noSession), completes);
    expect(noSession.value, '<orphan>');

    final parent = ExpressionContainer(errorSession, 1, 1, 'scope:local');
    final zeroRef = Variable(
      errorSession,
      1,
      parent,
      0,
      'z',
      'z',
      'zero',
      0,
      0,
      null,
      const {'lazy': true},
      available: true,
    );
    await expectLater(zeroRef.evaluateLazy(), completes);

    // 4. Mid-flight ReplModel.dispose() prevents post-disposal notifications
    final slowAdapter = _LazyScriptedAdapter();
    final slowGate = Completer<void>();
    slowAdapter.holdNextVariables = slowGate;
    slowAdapter.onVariables = ((args) => {
      'body': {
        'variables': [
          {'name': '', 'value': 'late', 'variablesReference': 0},
        ],
      },
    });
    final slowSession = _attachSession(slowAdapter);
    final disposableRepl = ReplModel();
    var postDisposeNotified = 0;
    disposableRepl.addListener(() => postDisposeNotified++);
    disposableRepl.onDidChangeElements((_) => postDisposeNotified++);

    final pending = ReplEvaluationResult('lateExpr')
      ..session = slowSession
      ..reference = 21
      ..presentationHint = {'lazy': true};
    final inflight = disposableRepl.evaluateLazy(pending);
    await pumpEventQueue();
    disposableRepl.dispose();
    slowGate.complete();
    await inflight;
    expect(postDisposeNotified, 0);

    repl.dispose();
  });
}
