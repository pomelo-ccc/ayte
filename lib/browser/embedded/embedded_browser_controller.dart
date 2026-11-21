import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../settings/user_settings.dart';
import '../../workspace/editor_launcher.dart' show openExternal;
import 'embedded_browser_native.dart';
import 'embedded_browser_settings.dart';

/// A single agent activity record on an embedded browser tab.
class BrowserTabActivity {
  BrowserTabActivity({
    required this.summary,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final String summary;
  final DateTime at;
}

/// One tab open in Ayte's workspace Embedded Browser.
class EmbeddedBrowserTab {
  EmbeddedBrowserTab({
    required this.id,
    required this.url,
    required this.profileId,
    required this.permission,
    this.title = '',
    this.loading = false,
    this.canGoBack = false,
    this.canGoForward = false,
    this.progress = 0.0,
    this.detached = false,
  });

  final String id;
  String url;
  String title;
  final String profileId;
  EmbeddedSharePermission permission;
  bool loading;
  bool canGoBack;
  bool canGoForward;
  double progress;
  bool detached;
  final List<BrowserTabActivity> activities = [];

  String get displayTitle {
    if (title.trim().isNotEmpty) return title.trim();
    final uri = Uri.tryParse(url);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return url.isEmpty ? 'New Tab' : url;
  }

  void recordActivity(String summary) {
    activities.insert(0, BrowserTabActivity(summary: summary));
    if (activities.length > 40) {
      activities.removeRange(40, activities.length);
    }
  }

  Map<String, Object?> toJson() => {
    'tabId': id,
    'url': url,
    'title': displayTitle,
    'profileId': profileId,
    'permission': permission.name,
    'loading': loading,
    'detached': detached,
  };
}

/// Manages embedded browser configuration, open tabs, native WKWebView
/// lifecycle, modal overlay suppression, and link routing.
class EmbeddedBrowserController extends ChangeNotifier {
  EmbeddedBrowserController._();
  static final instance = EmbeddedBrowserController._();

  EmbeddedBrowserConfig _config = const EmbeddedBrowserConfig();
  final List<EmbeddedBrowserTab> _tabs = [];
  String? _activeTabId;
  int _tabSeq = 0;
  int _overlayDepth = 0;
  Timer? _syncTimer;

  Listenable? _settingsSource;
  Object? Function(String key)? _settingsRead;
  UserSettings? _userSettings;

  /// Hook set by the active workbench to focus the Browser side panel tab
  /// whenever a link or tool opens an embedded browser tab.
  VoidCallback? onRevealBrowserPanel;

  EmbeddedBrowserConfig get config => _config;
  List<EmbeddedBrowserTab> get tabs => List.unmodifiable(_tabs);
  String? get activeTabId => _activeTabId;
  bool get overlayActive => _overlayDepth > 0;

  EmbeddedBrowserTab? get activeTab {
    if (_tabs.isEmpty) return null;
    for (final t in _tabs) {
      if (t.id == _activeTabId) return t;
    }
    return _tabs.first;
  }

  EmbeddedBrowserTab? tabById(String id) {
    for (final t in _tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  void follow(UserSettings settings) {
    _userSettings = settings;
    _settingsSource?.removeListener(_readSettings);
    _settingsSource = settings;
    _settingsRead = (key) => settings[key];
    settings.addListener(_readSettings);
    _readSettings();
    _ensureTimer();
  }

  Future<void> saveConfig(
    EmbeddedBrowserConfig next, {
    UserSettings? settings,
  }) async {
    _config = next;
    notifyListeners();
    final target = settings ?? _userSettings;
    if (target == null) return;
    final map = next.toSettingsMap();
    for (final entry in map.entries) {
      try {
        await target.update(entry.key, entry.value);
      } on Object catch (e) {
        debugPrint('${entry.key} not kept: $e');
      }
    }
  }

  void _readSettings() {
    final read = _settingsRead;
    if (read == null) return;
    _config = EmbeddedBrowserConfig.fromSettings(read);
    notifyListeners();
  }

  void _ensureTimer() {
    if (_syncTimer != null || Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    _syncTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_tabs.isEmpty || !EmbeddedBrowserNative.supported) return;
      var changed = false;
      for (final tab in _tabs) {
        final st = EmbeddedBrowserNative.getState(tab.id);
        if (!st.exists) continue;
        if (st.url.isNotEmpty && st.url != tab.url) {
          tab.url = st.url;
          changed = true;
        }
        if (st.title != tab.title) {
          tab.title = st.title;
          changed = true;
        }
        if (st.loading != tab.loading ||
            st.canGoBack != tab.canGoBack ||
            st.canGoForward != tab.canGoForward ||
            st.detached != tab.detached) {
          tab.loading = st.loading;
          tab.canGoBack = st.canGoBack;
          tab.canGoForward = st.canGoForward;
          tab.progress = st.progress;
          tab.detached = st.detached;
          changed = true;
        }
      }
      if (changed) notifyListeners();
    });
  }

  /// Called when a Flutter modal dialog (e.g. Settings) opens over the window
  /// so native WKWebView subviews hide temporarily and never cover Flutter UI.
  void pushOverlay() {
    _overlayDepth++;
    if (_overlayDepth == 1) {
      EmbeddedBrowserNative.hideAll();
      notifyListeners();
    }
  }

  void popOverlay() {
    if (_overlayDepth > 0) _overlayDepth--;
    if (_overlayDepth == 0) {
      notifyListeners();
    }
  }

  static String normalizeUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return 'about:blank';
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('file://') ||
        lower.startsWith('about:') ||
        lower.startsWith('data:') ||
        lower.startsWith('blob:')) {
      return trimmed;
    }
    if (lower.startsWith('localhost') ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}').hasMatch(trimmed)) {
      return 'http://$trimmed';
    }
    return 'https://$trimmed';
  }

  /// Opens a link according to site rules and link-source settings.
  /// Returns true if handled (either opened in embedded browser, opened in
  /// system browser, or blocked by a site rule).
  Future<bool> openLink(
    String rawUrl, {
    LinkSource source = LinkSource.chat,
    bool invertChoice = false,
    String? profileId,
    bool revealPanel = true,
  }) async {
    final normalized = normalizeUrl(rawUrl);
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !const {'http', 'https', 'file'}.contains(uri.scheme.toLowerCase())) {
      return openExternal(rawUrl);
    }

    if (uri.scheme == 'file') {
      if (_config.enabled && _config.htmlPreviewInEmbedded) {
        openTab(normalized, profileId: profileId, revealPanel: revealPanel);
        return true;
      }
      return openExternal(rawUrl);
    }

    final action = _config.resolveAction(
      uri,
      source: source,
      invertChoice: invertChoice,
    );
    switch (action) {
      case SiteRuleAction.block:
        return true;
      case SiteRuleAction.system:
        return openExternal(normalized);
      case SiteRuleAction.embedded:
        openTab(normalized, profileId: profileId, revealPanel: revealPanel);
        return true;
    }
  }

  /// Creates and activates a new embedded browser tab.
  EmbeddedBrowserTab openTab(
    String rawUrl, {
    String? profileId,
    bool? detached,
    bool revealPanel = true,
  }) {
    final url = normalizeUrl(rawUrl);
    final pid = profileId ?? _config.defaultProfileId;
    final id = 'tab_${++_tabSeq}';
    final wantDetached =
        detached ?? (_config.tabHostMode == BrowserTabHostMode.detached);
    final tab = EmbeddedBrowserTab(
      id: id,
      url: url,
      profileId: pid,
      permission: _config.defaultSharePermission,
      detached: wantDetached,
    );
    _tabs.add(tab);
    _activeTabId = id;
    EmbeddedBrowserNative.createTab(
      tabId: id,
      profileId: pid,
      url: url,
      googleSignInCompat: _config.googleSignInCompat,
      inspectorEnabled: _config.inspectorEnabled,
      detached: wantDetached,
    );
    notifyListeners();
    if (revealPanel && !wantDetached) {
      onRevealBrowserPanel?.call();
    }
    return tab;
  }

  void selectTab(String tabId) {
    if (_activeTabId == tabId) return;
    if (!_tabs.any((t) => t.id == tabId)) return;
    _activeTabId = tabId;
    EmbeddedBrowserNative.hideAll();
    notifyListeners();
  }

  void closeTab(String tabId) {
    final idx = _tabs.indexWhere((t) => t.id == tabId);
    if (idx == -1) return;
    _tabs.removeAt(idx);
    EmbeddedBrowserNative.action(tabId, 'close');
    if (_activeTabId == tabId) {
      _activeTabId = _tabs.isEmpty
          ? null
          : _tabs[idx.clamp(0, _tabs.length - 1)].id;
    }
    notifyListeners();
  }

  void navigateTab(String tabId, String rawUrl) {
    final tab = tabById(tabId);
    if (tab == null) return;
    final url = normalizeUrl(rawUrl);
    final uri = Uri.tryParse(url);
    if (uri != null &&
        _config.matchSiteRule(uri)?.action == SiteRuleAction.block) {
      return;
    }
    tab.url = url;
    EmbeddedBrowserNative.navigate(tabId, url);
    notifyListeners();
  }

  void setTabPermission(String tabId, EmbeddedSharePermission permission) {
    final tab = tabById(tabId);
    if (tab == null) return;
    tab.permission = permission;
    notifyListeners();
  }

  void toggleDetach(String tabId) {
    final tab = tabById(tabId);
    if (tab == null) return;
    tab.detached = !tab.detached;
    EmbeddedBrowserNative.action(tabId, tab.detached ? 'detach' : 'attach');
    notifyListeners();
  }

  void reopenInProfile(String tabId, String profileId) {
    final tab = tabById(tabId);
    if (tab == null) return;
    openTab(tab.url, profileId: profileId, detached: tab.detached);
  }

  void goBack(String tabId) => EmbeddedBrowserNative.action(tabId, 'back');
  void goForward(String tabId) =>
      EmbeddedBrowserNative.action(tabId, 'forward');
  void reload(String tabId) => EmbeddedBrowserNative.action(tabId, 'reload');
  void stopLoading(String tabId) => EmbeddedBrowserNative.action(tabId, 'stop');
  void openInspector(String tabId) =>
      EmbeddedBrowserNative.action(tabId, 'inspector');

  void clearProfileData(String profileId) {
    EmbeddedBrowserNative.clearProfile(profileId);
  }

  Future<void> deleteProfile(
    String profileId, {
    UserSettings? settings,
  }) async {
    if (profileId == BrowserProfile.defaultId) return;
    final toClose = [
      for (final t in _tabs)
        if (t.profileId == profileId) t.id,
    ];
    for (final id in toClose) {
      closeTab(id);
    }
    EmbeddedBrowserNative.clearProfile(profileId);
    final nextProfiles = [
      for (final p in _config.profiles)
        if (p.id != profileId) p,
    ];
    final nextDefault = _config.defaultProfileId == profileId
        ? BrowserProfile.defaultId
        : _config.defaultProfileId;
    await saveConfig(
      _config.copyWith(
        profiles: nextProfiles,
        defaultProfileId: nextDefault,
      ),
      settings: settings,
    );
  }
}
