import 'embedded_browser_native_stub.dart'
    if (dart.library.io) 'embedded_browser_native_io.dart'
    as impl;

/// Live navigation state read from a native WKWebView tab.
class NativeWebTabState {
  const NativeWebTabState({
    required this.exists,
    this.url = '',
    this.title = '',
    this.loading = false,
    this.canGoBack = false,
    this.canGoForward = false,
    this.progress = 0.0,
    this.detached = false,
  });

  final bool exists;
  final String url;
  final String title;
  final bool loading;
  final bool canGoBack;
  final bool canGoForward;
  final double progress;
  final bool detached;

  factory NativeWebTabState.fromJson(Map<String, Object?> json) =>
      NativeWebTabState(
        exists: json['exists'] == true,
        url: json['url'] as String? ?? '',
        title: json['title'] as String? ?? '',
        loading: json['loading'] == true,
        canGoBack: json['canGoBack'] == true,
        canGoForward: json['canGoForward'] == true,
        progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
        detached: json['detached'] == true,
      );
}

abstract final class EmbeddedBrowserNative {
  static bool get supported => impl.supported;

  static bool createTab({
    required String tabId,
    required String profileId,
    required String url,
    required bool googleSignInCompat,
    required bool inspectorEnabled,
    required bool detached,
  }) => impl.createTab(
    tabId: tabId,
    profileId: profileId,
    url: url,
    googleSignInCompat: googleSignInCompat,
    inspectorEnabled: inspectorEnabled,
    detached: detached,
  );

  static void setFrame({
    required String tabId,
    required double x,
    required double y,
    required double width,
    required double height,
    required bool visible,
  }) => impl.setFrame(
    tabId: tabId,
    x: x,
    y: y,
    width: width,
    height: height,
    visible: visible,
  );

  static void navigate(String tabId, String url) => impl.navigate(tabId, url);

  static void action(String tabId, String action) => impl.action(tabId, action);

  static void hideAll() => impl.hideAll();

  static NativeWebTabState getState(String tabId) => impl.getState(tabId);

  static Future<String> evalJs(
    String tabId,
    String script, {
    Duration timeout = const Duration(seconds: 15),
  }) => impl.evalJs(tabId, script, timeout: timeout);

  static Future<String> takeSnapshot(
    String tabId,
    String outputPath, {
    Duration timeout = const Duration(seconds: 15),
  }) => impl.takeSnapshot(tabId, outputPath, timeout: timeout);

  static void clearProfile(String profileId) => impl.clearProfile(profileId);
}
