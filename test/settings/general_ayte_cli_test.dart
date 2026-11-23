import 'dart:io';

import 'package:baocode/acp/ayte_ipc_server.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/settings/pages/general_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory homeDir;

  setUp(() async {
    homeDir = await Directory.systemTemp.createTemp('ayte-gen-cli-');
    await AyteIpcServer.instance.stop();
    AyteIpcServer.instance.homeOverride = homeDir.path;
    await AyteIpcServer.instance.uninstallCli();
  });

  tearDown(() async {
    await AyteIpcServer.instance.stop();
    await AyteIpcServer.instance.uninstallCli();
    AyteIpcServer.instance.homeOverride = null;
    if (homeDir.existsSync()) {
      await homeDir.delete(recursive: true);
    }
  });

  Widget wrapPage(Locale locale) => MaterialApp(
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: const Scaffold(body: GeneralSettingsPage()),
  );

  testWidgets('GeneralSettingsPage displays ayte-cli status, installs, uninstalls, and updates IPC status', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(wrapPage(const Locale('en')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('ayte-cli Command'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('ayte-cli Command'), findsOneWidget);
    expect(find.text('CLI status: Not installed'), findsOneWidget);
    expect(find.text('IPC server: Stopped'), findsOneWidget);

    // Install CLI (tap the Install button inside the ayte-cli row)
    await tester.tap(find.text('Install').last);
    await tester.pump();
    for (var i = 0;
        i < 80 && find.text('ayte-cli installed').evaluate().isEmpty;
        i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(AyteIpcServer.instance.isCliInstalled, isTrue);
    expect(find.text('CLI status: Installed'), findsOneWidget);
    expect(find.text('Reinstall'), findsOneWidget);
    expect(find.text('ayte-cli installed'), findsOneWidget);

    // Live IPC server state update
    await tester.runAsync(() => AyteIpcServer.instance.start());
    await tester.pumpAndSettle();
    final port = AyteIpcServer.instance.port;
    expect(port, isNotNull);
    expect(find.text('IPC server: Running (127.0.0.1:$port)'), findsOneWidget);

    // Uninstall CLI
    await tester.tap(find.text('Uninstall').last);
    await tester.pump();
    for (var i = 0;
        i < 80 && find.text('ayte-cli uninstalled').evaluate().isEmpty;
        i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(AyteIpcServer.instance.isCliInstalled, isFalse);
    expect(find.text('CLI status: Not installed'), findsOneWidget);
    expect(find.text('ayte-cli uninstalled'), findsOneWidget);
  });

  testWidgets('GeneralSettingsPage renders localized Chinese ayte-cli labels', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(wrapPage(const Locale('zh')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('ayte-cli 命令行接口'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('ayte-cli 命令行接口'), findsOneWidget);
    expect(find.text('CLI 状态：未安装'), findsOneWidget);
    expect(find.text('IPC 服务：未启动'), findsOneWidget);
  });
}
