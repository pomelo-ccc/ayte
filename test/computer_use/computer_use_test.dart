import 'package:baocode/computer_use/computer_use_controller.dart';
import 'package:baocode/computer_use/computer_use_native.dart';
import 'package:baocode/computer_use/computer_use_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ComputerUseConfig', () {
    test('locks delivery mode to background when bringToFront is false', () {
      const cfg = ComputerUseConfig(
        allowBringToFront: false,
        defaultDeliveryMode: ComputerUseDeliveryMode.foreground,
      );
      expect(cfg.effectiveDeliveryMode, ComputerUseDeliveryMode.background);
    });

    test('validates macOS Carbon stop hotkey rules', () {
      final ok = ComputerUseConfig.parseMacCarbonHotkey('Ctrl+Cmd+Escape');
      expect(ok, isNotNull);
      expect(ok!.keyCode, 53);
      // Only one modifier should fail.
      expect(ComputerUseConfig.parseMacCarbonHotkey('Cmd+Escape'), isNull);
      // Missing Ctrl/Cmd should fail.
      expect(
        ComputerUseConfig.parseMacCarbonHotkey('Shift+Alt+Escape'),
        isNull,
      );
    });

    test('blocks default password managers and system settings', () {
      const cfg = ComputerUseConfig();
      expect(
        cfg.isBlockedApp(
          bundleId: 'com.1password.1password',
          appName: '1Password',
          execPath: '/Applications/1Password.app/Contents/MacOS/1Password',
        ),
        isTrue,
      );
      expect(
        cfg.isBlockedApp(
          bundleId: 'com.apple.Safari',
          appName: 'Safari',
          execPath: '/Applications/Safari.app/Contents/MacOS/Safari',
        ),
        isFalse,
      );
    });

    test('round-trips through settings map', () {
      const orig = ComputerUseConfig(
        enabled: true,
        agentToolEnabled: true,
        idleTimeoutMinutes: 60,
        allowBringToFront: false,
        allowLaunchAndMove: true,
        allowClipboard: true,
        allowFullScreen: true,
      );
      final map = orig.toSettingsMap();
      final parsed = ComputerUseConfig.fromSettings((k) => map[k]);
      expect(parsed.enabled, isTrue);
      expect(parsed.agentToolEnabled, isTrue);
      expect(parsed.toolsActive, isTrue);
      expect(parsed.idleTimeoutMinutes, 60);
      expect(parsed.allowBringToFront, isFalse);
      expect(parsed.allowLaunchAndMove, isTrue);
      expect(parsed.allowClipboard, isTrue);
      expect(parsed.allowFullScreen, isTrue);
    });
  });

  group('ComputerUseController', () {
    test('never allows sharing self window or blacklisted apps', () async {
      final ctrl = ComputerUseController.instance;
      await ctrl.saveConfig(const ComputerUseConfig(enabled: true));

      const selfWin = DesktopWindowInfo(
        windowId: 100,
        pid: 1,
        appName: 'Ayte',
        bundleId: 'dev.ayte.desktop',
        execPath: '/Applications/Ayte.app',
        title: 'Ayte',
        x: 0,
        y: 0,
        width: 1200,
        height: 800,
        isSelf: true,
      );
      const safeWin = DesktopWindowInfo(
        windowId: 101,
        pid: 2,
        appName: 'Safari',
        bundleId: 'com.apple.Safari',
        execPath: '/Applications/Safari.app',
        title: 'Docs',
        x: 0,
        y: 0,
        width: 1000,
        height: 700,
        isSelf: false,
      );

      expect(ctrl.shareWindow(selfWin, WindowShareLevel.interactive), isFalse);
      expect(ctrl.shareWindow(safeWin, WindowShareLevel.readOnly), isTrue);
      expect(ctrl.shareLevelOf(101), WindowShareLevel.readOnly);

      ctrl.stopAllSharing();
      expect(ctrl.hasActiveShares, isFalse);
      await ctrl.saveConfig(const ComputerUseConfig(enabled: false));
    });
  });
}
