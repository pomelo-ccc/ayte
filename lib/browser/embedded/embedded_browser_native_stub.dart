import 'embedded_browser_native.dart';

bool get supported => false;

bool createTab({
  required String tabId,
  required String profileId,
  required String url,
  required bool googleSignInCompat,
  required bool inspectorEnabled,
  required bool detached,
}) => false;

void setFrame({
  required String tabId,
  required double x,
  required double y,
  required double width,
  required double height,
  required bool visible,
}) {}

void navigate(String tabId, String url) {}

void action(String tabId, String action) {}

void hideAll() {}

NativeWebTabState getState(String tabId) =>
    const NativeWebTabState(exists: false);

Future<String> evalJs(
  String tabId,
  String script, {
  Duration timeout = const Duration(seconds: 15),
}) async => throw UnsupportedError('Embedded WKWebView is macOS-only.');

Future<String> takeSnapshot(
  String tabId,
  String outputPath, {
  Duration timeout = const Duration(seconds: 15),
}) async => throw UnsupportedError('Embedded WKWebView is macOS-only.');

void clearProfile(String profileId) {}
