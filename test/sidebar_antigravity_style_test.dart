import 'package:baocode/ide/ide_list.dart';
import 'package:baocode/main.dart';
import 'package:baocode/search/search_palette.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:baocode/workspace/islands.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Finder inSidebar(Finder finder) =>
    find.descendant(of: find.byType(Sidebar), matching: finder);

void main() {
  testWidgets(
    'replicates Antigravity sidebar layout, x-alignment, pill selection, '
    'top-bar back/forward/search, 2-line pinned rows, and clean footer',
    (tester) async {
      final previousIslands = Islands.enabled.value;
      Islands.enabled.value = false;
      addTearDown(() => Islands.enabled.value = previousIslands);

      await tester.runAsync(
        () => WorkbenchThemeService.instance.setColorTheme(
          'Antigravity Light',
          preview: true,
        ),
      );
      addTearDown(
        () => tester.runAsync(
          () => WorkbenchThemeService.instance.setColorTheme(
            'Dark 2026',
            preview: true,
          ),
        ),
      );

      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final workspace = Workspace.mock();
      await tester.pumpWidget(BaoCodeApp(workspace: workspace));
      await tester.pump(const Duration(milliseconds: 250));

      final sidebarLeft = tester.getTopLeft(find.byType(Sidebar)).dx;

      // 1. Pinned Conversations appears ABOVE Projects, with 2-line project subtitle.
      final pinnedHeader = inSidebar(find.text('Pinned Conversations'));
      final projectsHeader = inSidebar(find.text('Projects'));
      expect(pinnedHeader, findsOneWidget);
      expect(projectsHeader, findsOneWidget);
      expect(
        tester.getTopLeft(pinnedHeader).dy,
        lessThan(tester.getTopLeft(projectsHeader).dy),
      );
      expect(
        inSidebar(find.text('baocode', findRichText: true)),
        findsNWidgets(2),
      );

      // 2. Exact horizontal x-alignment across New Conversation, project name,
      // selected conversation title, and Settings footer label.
      final newConvX =
          tester.getTopLeft(inSidebar(find.text('New Conversation'))).dx -
          sidebarLeft;
      final projectTitleX =
          tester.getTopLeft(inSidebar(find.text('baocode'))).dx - sidebarLeft;
      final selectedThread = workspace.current!;
      final selectedTitleFinder = inSidebar(
        find.textContaining(selectedThread.title),
      );
      final selectedTitleX =
          tester.getTopLeft(selectedTitleFinder.first).dx - sidebarLeft;
      final settingsTitleX =
          tester.getTopLeft(inSidebar(find.text('Settings'))).dx - sidebarLeft;

      expect(newConvX, closeTo(34.0, 1.0));
      expect(projectTitleX, closeTo(34.0, 1.0));
      expect(selectedTitleX, closeTo(34.0, 1.0));
      expect(settingsTitleX, closeTo(34.0, 1.0));

      // 3. Selected row is a floating #FFFFFF 7px-radius pill with no outline
      // even when Islands mode is disabled.
      final selectedIdeRow = tester.widget<IdeListRow>(
        find.ancestor(
          of: selectedTitleFinder.first,
          matching: find.byType(IdeListRow),
        ),
      );
      expect(selectedIdeRow.selected, isTrue);
      expect(selectedIdeRow.showOutline, isFalse);
      expect(selectedIdeRow.borderRadius, BorderRadius.circular(7));
      expect(selectedIdeRow.selectedColor, const Color(0xFFFFFFFF));

      // 4. Top-bar Back / Forward buttons navigate conversation history,
      // and Search icon opens SearchPalette.
      final otherThread = workspace.threads.firstWhere(
        (t) => !t.pinned && !t.archived && !identical(t, selectedThread),
      );
      await tester.tap(inSidebar(find.textContaining(otherThread.title)).first);
      await tester.pump(const Duration(milliseconds: 250));
      expect(workspace.current, same(otherThread));
      expect(workspace.canNavigateBack, isTrue);

      await tester.tap(inSidebar(find.byIcon(Icons.arrow_back_rounded)));
      await tester.pump(const Duration(milliseconds: 250));
      expect(workspace.current, same(selectedThread));
      expect(workspace.canNavigateForward, isTrue);

      await tester.tap(inSidebar(find.byIcon(Icons.arrow_forward_rounded)));
      await tester.pump(const Duration(milliseconds: 250));
      expect(workspace.current, same(otherThread));

      await tester.tap(inSidebar(find.text('Search')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(SearchPalette), findsOneWidget);

      // 5. Clean Antigravity footer: Settings row present, no "• N chats" badge.
      expect(inSidebar(find.textContaining('chats')), findsNothing);
      expect(inSidebar(find.byType(AntigravitySidebarIcon)), findsWidgets);
    },
  );

  testWidgets(
    'groups project threads under subtle per-agent sub-headers when multiple agents exist',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final workspace = Workspace.mock();
      await tester.pumpWidget(BaoCodeApp(workspace: workspace));
      await tester.pump(const Duration(milliseconds: 250));

      // api-gateway has both Claude Code (Rate limit, Flaky) and Codex (Migrate auth).
      // Subtle agent sub-headers nest under the project and group threads by agent.
      final apiGatewayTop = tester
          .getTopLeft(inSidebar(find.text('api-gateway')))
          .dy;
      final rateLimitTop = tester
          .getTopLeft(inSidebar(find.textContaining('Rate limit per API key')))
          .dy;
      final flakyTop = tester
          .getTopLeft(
            inSidebar(find.textContaining('Flaky integration test on CI')),
          )
          .dy;
      final migrateTop = tester
          .getTopLeft(
            inSidebar(find.textContaining('Migrate auth middleware to JWT')),
          )
          .dy;

      // Most-recently-active agent in api-gateway is Claude Code (Rate limit 55m ago),
      // so both Claude Code threads appear together above the Codex thread.
      expect(apiGatewayTop, lessThan(rateLimitTop));
      expect(rateLimitTop, lessThan(flakyTop));
      expect(flakyTop, lessThan(migrateTop));

      // Subtle agent sub-headers are present for both Claude Code and Codex.
      final codexHeaders = inSidebar(find.text('Codex'));
      expect(codexHeaders, findsWidgets);

      // Tapping the Codex sub-header inside api-gateway folds only Codex threads
      // under api-gateway without hiding Claude Code threads in api-gateway.
      await tester.tap(codexHeaders.last);
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        inSidebar(find.textContaining('Migrate auth middleware to JWT')),
        findsNothing,
      );
      expect(
        inSidebar(find.textContaining('Rate limit per API key')),
        findsOneWidget,
      );

      // Filtering the sidebar to a single kernel hides redundant sub-headers
      // (only the active filter chip still shows the kernel label).
      workspace.sidebarKernelFilter = workspace.kernels.first.id;
      await tester.pump(const Duration(milliseconds: 200));
      expect(inSidebar(find.text('Codex')), findsNothing);
      expect(
        inSidebar(find.byKey(const ValueKey('sidebar-kernel-filter-chip'))),
        findsOneWidget,
      );
      expect(
        inSidebar(find.text(workspace.kernels.first.label)),
        findsOneWidget,
      );
    },
  );
}
