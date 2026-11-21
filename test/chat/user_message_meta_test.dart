import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer_draft.dart';
import 'package:baocode/chat/user_message_style.dart';
import 'package:baocode/chat/widgets/copy_button.dart';
import 'package:baocode/chat/widgets/user_message_bubble.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

ImageAttachment _img(int number) =>
    ImageAttachment(bytes: _png, mediaType: 'image/png', number: number);

class _ReadOnlyFeed extends ChangeNotifier implements ChatFeed {
  _ReadOnlyFeed(this.items);

  final List<ChatItem> items;

  @override
  int get itemCount => items.length;
  @override
  ChatItem itemAt(int index) => items[index];
  @override
  bool get isStreaming => false;
  @override
  bool get isUnprompted => false;
  @override
  bool get canEditMessages => false;
  @override
  ({int index, ComposerDraft draft})? get editing => null;
  @override
  set editing(({int index, ComposerDraft draft})? value) {}
  @override
  void editMessage(int index, ComposerMessage message, {UserPlace? from}) {}
  @override
  VoidCallback? moveToBackgroundAt(int index) => null;
  @override
  VoidCallback? stopAt(int index) => null;
}

void main() {
  group('timestamp formatting', () {
    test('formats same-day, same-year, and older-year timestamps', () {
      final now = DateTime(2026, 11, 19, 15, 0, 0);
      expect(
        formatChatTimestamp(DateTime(2026, 11, 19, 9, 5, 3), now: now),
        '09:05:03',
      );
      expect(
        formatChatTimestamp(DateTime(2026, 5, 1, 9, 5, 3), now: now),
        '05-01 09:05:03',
      );
      expect(
        formatChatTimestamp(DateTime(2025, 12, 31, 23, 59, 58), now: now),
        '2025-12-31 23:59:58',
      );
      expect(
        formatChatFullTimestamp(DateTime(2026, 11, 19, 9, 5, 3)),
        '2026-11-19 09:05:03',
      );
    });

    test('formats turn wall-clock ranges within and across days', () {
      final now = DateTime(2026, 11, 19, 15, 0, 0);
      expect(
        formatTurnTimeRange(
          DateTime(2026, 11, 19, 9, 5, 3),
          worked: const Duration(minutes: 2, seconds: 12),
          now: now,
        ),
        '09:05:03 – 09:07:15',
      );
      expect(
        formatTurnTimeRange(
          DateTime(2026, 11, 18, 23, 55, 0),
          worked: const Duration(minutes: 10),
          now: now,
        ),
        '11-18 23:55:00 – 11-19 00:05:00',
      );
      expect(
        formatTurnTimeRange(
          DateTime(2026, 11, 19, 9, 5, 3),
          worked: Duration.zero,
          now: now,
        ),
        '09:05:03',
      );
    });
  });

  group('userPromptCopyText', () {
    test('leaves text untouched when no images are attached', () {
      expect(
        userPromptCopyText('Why does [Image #1] fail to parse?'),
        'Why does [Image #1] fail to parse?',
      );
    });

    test('strips attached image placeholders cleanly while keeping prompt text', () {
      expect(
        userPromptCopyText(
          '[Image #1] 这个时间不要显示整个会话的时间  只显示这一次问答的时间',
          images: [_img(1)],
        ),
        '这个时间不要显示整个会话的时间  只显示这一次问答的时间',
      );
      expect(
        userPromptCopyText(
          '[Image #1] [Image #2] 什么情况 一个正常 一个一直报错',
          images: [_img(1), _img(2)],
        ),
        '什么情况 一个正常 一个一直报错',
      );
      expect(
        userPromptCopyText('看看 [Image #1] 这里的报错', images: [_img(1)]),
        '看看 这里的报错',
      );
      expect(
        userPromptCopyText(
          '第一行\n[Image #1]\n第二行 [Image #2]',
          images: [_img(1), _img(2)],
        ),
        '第一行\n第二行',
      );
      expect(userPromptCopyText('[Image #1]', images: [_img(1)]), '');
      expect(
        userPromptCopyText(
          '[Image #1] 对比 [Image #9]',
          images: [_img(1)],
        ),
        '对比 [Image #9]',
      );
    });
  });

  group('widget integration', () {
    String? copied;
    setUp(() {
      copied = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets(
      'quick-copies prompt text without [Image #N] and avoids triggering edit',
      (tester) async {
        final now = DateTime.now();
        final sentAt = DateTime(now.year, now.month, now.day, 10, 20, 30);
        final feed = _ReadOnlyFeed([
          UserMessageItem(
            text: '[Image #1] [Image #2] 这个地方为什么会报错',
            images: [_img(1), _img(2)],
            sentAt: sentAt,
          ),
          const AssistantTextItem('我看一下。'),
        ]);
        addTearDown(feed.dispose);

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: buildAppTheme(),
            home: Scaffold(body: ChatHistoryView(feed: feed)),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('10:20:30'), findsOneWidget);
        final copyButton = find.descendant(
          of: find.byType(UserMessageMeta),
          matching: find.byType(CopyButton),
        );
        expect(copyButton, findsOneWidget);

        await tester.tap(copyButton);
        await tester.pump();
        expect(copied, '这个地方为什么会报错');
        expect(find.byType(UserMessageViewer), findsNothing);
      },
    );

    testWidgets('viewer copy button copies clean question text when opened', (
      tester,
    ) async {
      final feed = _ReadOnlyFeed([
        UserMessageItem(
          text: '[Image #1] 打开详情后也能复制这个问题',
          images: [_img(1)],
          sentAt: DateTime(2026, 11, 19, 11, 0, 5),
        ),
        const AssistantTextItem('好的。'),
      ]);
      addTearDown(feed.dispose);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(),
          home: Scaffold(body: ChatHistoryView(feed: feed)),
        ),
      );
      await tester.pumpAndSettle();

      // Tapping the bubble body (clear of image chip) opens UserMessageViewer.
      await tester.tapAt(
        tester.getBottomRight(find.byType(UserMessageBubble).first) -
            const Offset(10, 6),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UserMessageViewer), findsOneWidget);

      final viewerCopy = find.descendant(
        of: find.byType(UserMessageViewer),
        matching: find.byType(CopyButton),
      );
      expect(viewerCopy, findsOneWidget);
      await tester.tap(viewerCopy);
      await tester.pump();
      expect(copied, '打开详情后也能复制这个问题');
    });

    testWidgets(
      'drag-selecting a user message with images still selects and copies text',
      (tester) async {
        final feed = _ReadOnlyFeed([
          UserMessageItem(
            text: '[Image #1] 划选这句话也必须能复制',
            images: [_img(1)],
            sentAt: DateTime(2026, 11, 19, 12, 0, 0),
          ),
          const AssistantTextItem('明白。'),
        ]);
        addTearDown(feed.dispose);

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: buildAppTheme(),
            home: Scaffold(body: ChatHistoryView(feed: feed)),
          ),
        );
        await tester.pumpAndSettle();

        final bubble = find.descendant(
          of: find.byType(SuperListView),
          matching: find.byType(UserMessageBubble),
        );
        final rect = tester.getRect(bubble);
        final mouse = await tester.startGesture(
          Offset(rect.left + 6, rect.center.dy),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await mouse.moveTo(Offset(rect.right - 6, rect.center.dy));
        await tester.pump();
        await mouse.up();
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        expect(copied, contains('划选这句话也必须能复制'));
      },
    );

    testWidgets(
      'works in both bubble style and sticky style',
      (tester) async {
        final prev = UserMessageStyle.current.value;
        addTearDown(() => UserMessageStyle.current.value = prev);

        final now = DateTime.now();
        final sentAt = DateTime(now.year, now.month, now.day, 14, 15, 16);
        final feed = _ReadOnlyFeed([
          UserMessageItem(
            text: '[Image #1] 不同样式下都可以快速复制问题',
            images: [_img(1)],
            sentAt: sentAt,
          ),
          const AssistantTextItem('好的，我来处理。'),
        ]);
        addTearDown(feed.dispose);

        for (final style in UserMessageStyle.values) {
          copied = null;
          UserMessageStyle.current.value = style;
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: buildAppTheme(),
              home: Scaffold(body: ChatHistoryView(feed: feed)),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text('14:15:16'), findsOneWidget);
          await tester.tap(find.byType(CopyButton).first);
          await tester.pump();
          expect(copied, '不同样式下都可以快速复制问题');
        }
      },
    );
  });
}
