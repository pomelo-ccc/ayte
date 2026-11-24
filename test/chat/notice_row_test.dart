import 'dart:typed_data';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/widgets/chat_item_view.dart';
import 'package:baocode/chat/widgets/notice_row.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeKernel with KernelEventSource implements AgentKernel, AcceptsImages {
  _FakeKernel(this.descriptor);

  @override
  final KernelDescriptor descriptor;

  final List<KernelTurn> sentTurns = [];

  void pushItem(String id, ChatItem item) =>
      emit(ItemUpserted(nextSeq, id, item));

  void prependItems(List<(String, ChatItem)> items) =>
      emit(HistoryPrepended(nextSeq, items));

  @override
  KernelHealth get health => KernelHealth.ready;

  @override
  String? get sessionId => 'test-session';

  @override
  void send(KernelTurn turn) => sentTurns.add(turn);

  @override
  void answer(String requestId, InteractionAnswer answer) {}

  @override
  void cancel() {}

  @override
  void restart() {}

  @override
  void prepare() {}

  @override
  void release() {}

  @override
  void dispose() => closeEvents();

  @override
  Future<void> get stopped => Future.value();
}

({ChatSession session, _FakeKernel kernel}) _createSession() {
  late _FakeKernel kernel;
  late final KernelDescriptor descriptor;
  descriptor = KernelDescriptor(
    id: 'fake',
    label: 'Fake',
    icon: Icons.smart_toy_outlined,
    description: '',
    create: (_) => kernel = _FakeKernel(descriptor),
  );
  final session = ChatSession(
    kernel: descriptor,
    kernels: [descriptor],
    historyCount: 0,
  );
  return (session: session, kernel: kernel);
}

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(body: child),
  ),
);

void main() {
  testWidgets('retrying an earlier error resends its own user message, not the latest one', (
    tester,
  ) async {
    final (:session, :kernel) = _createSession();
    addTearDown(session.dispose);

    final image = ImageAttachment(
      bytes: Uint8List.fromList([1, 2, 3]),
      mediaType: 'image/png',
      number: 1,
    );
    const error = NoticeItem(
      NoticeKind.error,
      'authentication failed or timed out',
    );
    kernel.pushItem('u1', const UserMessageItem(text: '你好'));
    kernel.pushItem(
      'u2',
      UserMessageItem(
        text: '[Image #1] 这是在pdm项目里面的代码',
        images: [image],
      ),
    );
    kernel.pushItem('e2', error);
    kernel.pushItem('u3', const UserMessageItem(text: '4/0AUn6Hd-oauth-code'));
    kernel.pushItem('a3', const AssistantTextItem('看起来你输入的是一串 OAuth 授权码'));

    await _pump(
      tester,
      ChatItemView(item: error, itemIndex: 2, session: session),
    );

    await tester.tap(find.text('重试本条'));
    await tester.pump();

    expect(kernel.sentTurns, hasLength(1));
    expect(kernel.sentTurns.single.text, '[Image #1] 这是在pdm项目里面的代码');
    expect(kernel.sentTurns.single.images, [image]);
  });

  testWidgets('retrying without itemIndex still locates the error notice and its prompt', (
    tester,
  ) async {
    final (:session, :kernel) = _createSession();
    addTearDown(session.dispose);

    const error = NoticeItem(NoticeKind.error, 'request timed out');
    kernel.pushItem('u1', const UserMessageItem(text: 'first prompt'));
    kernel.pushItem('e1', error);
    kernel.pushItem('u2', const UserMessageItem(text: 'latest prompt'));

    await _pump(tester, NoticeRow(item: error, session: session));

    await tester.tap(find.text('重试本条'));
    await tester.pump();

    expect(kernel.sentTurns, hasLength(1));
    expect(kernel.sentTurns.single.text, 'first prompt');
  });

  testWidgets('duplicate const error notices each retry their own preceding prompt', (
    tester,
  ) async {
    final (:session, :kernel) = _createSession();
    addTearDown(session.dispose);

    const sharedError = NoticeItem(NoticeKind.error, 'network error');
    kernel.pushItem('u1', const UserMessageItem(text: 'prompt one'));
    kernel.pushItem('e1', sharedError);
    kernel.pushItem('u2', const UserMessageItem(text: 'prompt two'));
    kernel.pushItem('e2', sharedError);

    await _pump(
      tester,
      Column(
        children: [
          NoticeRow(
            key: const ValueKey('first-error'),
            item: sharedError,
            itemIndex: 1,
            session: session,
          ),
          NoticeRow(
            key: const ValueKey('second-error'),
            item: sharedError,
            itemIndex: 3,
            session: session,
          ),
        ],
      ),
    );

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('first-error')),
        matching: find.text('重试本条'),
      ),
    );
    await tester.pump();

    expect(kernel.sentTurns, hasLength(1));
    expect(kernel.sentTurns.last.text, 'prompt one');

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('second-error')),
        matching: find.text('重试本条'),
      ),
    );
    await tester.pump();

    expect(kernel.sentTurns, hasLength(2));
    expect(kernel.sentTurns.last.text, 'prompt two');
  });

  testWidgets('error before any user message hides retry button even after later messages', (
    tester,
  ) async {
    final (:session, :kernel) = _createSession();
    addTearDown(session.dispose);

    const earlyError = NoticeItem(
      NoticeKind.error,
      'Could not read this session',
    );
    kernel.pushItem('e0', earlyError);
    kernel.pushItem('u1', const UserMessageItem(text: 'later prompt'));

    await _pump(
      tester,
      NoticeRow(item: earlyError, itemIndex: 0, session: session),
    );

    expect(find.text('重试本条'), findsNothing);
  });

  testWidgets('skips agent-sent messages and handles prepended history', (
    tester,
  ) async {
    final (:session, :kernel) = _createSession();
    addTearDown(session.dispose);

    const error = NoticeItem(NoticeKind.error, 'upstream failed');
    kernel.pushItem('u1', const UserMessageItem(text: 'real user prompt'));
    kernel.pushItem(
      'ag1',
      const UserMessageItem(text: 'subagent report', fromAgent: 'research'),
    );
    kernel.pushItem('e1', error);
    kernel.pushItem('u2', const UserMessageItem(text: 'newest prompt'));

    // Render with the pre-prepend index, then prepend earlier history.
    await _pump(
      tester,
      NoticeRow(item: error, itemIndex: 2, session: session),
    );
    kernel.prependItems([
      ('u0', const UserMessageItem(text: 'older prompt')),
      ('a0', const AssistantTextItem('older answer')),
    ]);
    await tester.pump();

    await tester.tap(find.text('重试本条'));
    await tester.pump();

    expect(kernel.sentTurns, hasLength(1));
    expect(kernel.sentTurns.single.text, 'real user prompt');
  });
}
