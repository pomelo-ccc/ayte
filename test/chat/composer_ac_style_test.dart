import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/antigravity_account_picker.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/chat/composer/composer_picker.dart';
import 'package:baocode/chat/composer/pickers_row.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'ChatComposer applies A (warm unified card + ghost buttons + focus ring) '
    'and C (left Agent + Model only, icon-only permission shield, right quota ring)',
    (tester) async {
      await tester.runAsync(() async {
        await WorkbenchThemeService.instance.setColorTheme('Antigravity Light');
      });

      final session = ChatSession(historyCount: 0);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  width: 680,
                  child: ChatComposer(session: session),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      // 1. Placeholder uses unified ` · ` separators without `、` mix.
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ChatComposer)),
      )!;
      expect(
        l10n.composerPlaceholder,
        '描述任务或提问 · 拖入或粘贴文件 · 输入 / 调用命令',
      );
      expect(l10n.composerPlaceholder.contains('、'), isFalse);

      // 2. Left PickersRow contains ONLY ghost buttons (no emphasized fill,
      //    no permission text, no account text).
      final leftPickers = find.descendant(
        of: find.byType(PickersRow),
        matching: find.byType(ComposerPicker),
      );
      expect(leftPickers, findsWidgets);
      for (final picker in tester.widgetList<ComposerPicker>(leftPickers)) {
        expect(picker.emphasized, isFalse);
        expect(picker.iconOnly, isFalse);
      }
      expect(
        find.descendant(
          of: find.byType(PickersRow),
          matching: find.byType(AntigravityAccountPicker),
        ),
        findsNothing,
      );

      // 3. Permission picker sits outside PickersRow as a compact iconOnly shield.
      final allPickers = tester.widgetList<ComposerPicker>(
        find.byType(ComposerPicker),
      );
      final permissionPickers = allPickers.where((p) => p.iconOnly).toList();
      expect(permissionPickers.length, 1);
      expect(permissionPickers.single.tooltip, isNotEmpty);

      // 4. Unified white card with warm border & 3px translucent focus halo when focused.
      final animatedContainers = tester.widgetList<AnimatedContainer>(
        find.descendant(
          of: find.byType(ChatComposer),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final cardContainer = animatedContainers.firstWhere(
        (c) => c.decoration is ShapeDecoration,
      );
      final shapeDeco = cardContainer.decoration! as ShapeDecoration;
      expect(shapeDeco.color, Colors.white);
      expect(
        shapeDeco.shadows!.any((s) => s.spreadRadius == 3 && s.blurRadius == 0),
        isTrue,
      );
    },
  );
}
