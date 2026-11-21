import 'computer_use_native.dart';

bool get supported => false;

ComputerUsePermissions checkPermissions() =>
    const ComputerUsePermissions(accessibility: false, screenRecording: false);

bool requestAccessibility() => false;

bool requestScreenRecording() => false;

void openPrivacyPane(String pane) {}

List<DesktopWindowInfo> listWindows() => const [];

bool captureWindow(int windowId, String outputPath) => false;

bool registerStopHotkey(int keyCode, int carbonModifiers) => false;

void unregisterStopHotkey() {}

bool pollStopEvent() => false;

void showStopBar(String statusText, String stopLabel) {}

void hideStopBar() {}
