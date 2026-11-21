import 'computer_use_native_stub.dart'
    if (dart.library.io) 'computer_use_native_io.dart'
    as impl;

/// Snapshot of macOS accessibility / screen recording permission state.
class ComputerUsePermissions {
  const ComputerUsePermissions({
    required this.accessibility,
    required this.screenRecording,
    this.pid = 0,
    this.bundleId = '',
  });

  final bool accessibility;
  final bool screenRecording;
  final int pid;
  final String bundleId;

  bool get allGranted => accessibility && screenRecording;
}

/// A desktop application window enumerated from the OS window server.
class DesktopWindowInfo {
  const DesktopWindowInfo({
    required this.windowId,
    required this.pid,
    required this.appName,
    required this.bundleId,
    required this.execPath,
    required this.title,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.isSelf,
  });

  final int windowId;
  final int pid;
  final String appName;
  final String bundleId;
  final String execPath;
  final String title;
  final double x;
  final double y;
  final double width;
  final double height;
  final bool isSelf;

  String get displayLabel =>
      title.isEmpty ? appName : '$appName — $title';

  factory DesktopWindowInfo.fromJson(Map<String, Object?> json) =>
      DesktopWindowInfo(
        windowId: (json['windowId'] as num?)?.toInt() ?? 0,
        pid: (json['pid'] as num?)?.toInt() ?? 0,
        appName: json['appName'] as String? ?? '',
        bundleId: json['bundleId'] as String? ?? '',
        execPath: json['execPath'] as String? ?? '',
        title: json['title'] as String? ?? '',
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
        width: (json['width'] as num?)?.toDouble() ?? 0,
        height: (json['height'] as num?)?.toDouble() ?? 0,
        isSelf: json['isSelf'] == true,
      );

  Map<String, Object?> toJson() => {
    'windowId': windowId,
    'pid': pid,
    'appName': appName,
    'bundleId': bundleId,
    'title': title,
    'bounds': {'x': x, 'y': y, 'width': width, 'height': height},
  };
}

abstract final class ComputerUseNative {
  static bool get supported => impl.supported;

  static ComputerUsePermissions checkPermissions() => impl.checkPermissions();

  static bool requestAccessibility() => impl.requestAccessibility();

  static bool requestScreenRecording() => impl.requestScreenRecording();

  static void openPrivacyPane(String pane) => impl.openPrivacyPane(pane);

  static List<DesktopWindowInfo> listWindows() => impl.listWindows();

  static bool captureWindow(int windowId, String outputPath) =>
      impl.captureWindow(windowId, outputPath);

  static bool registerStopHotkey(int keyCode, int carbonModifiers) =>
      impl.registerStopHotkey(keyCode, carbonModifiers);

  static void unregisterStopHotkey() => impl.unregisterStopHotkey();

  static bool pollStopEvent() => impl.pollStopEvent();

  static void showStopBar(String statusText, String stopLabel) =>
      impl.showStopBar(statusText, stopLabel);

  static void hideStopBar() => impl.hideStopBar();
}
