import 'package:flutter/foundation.dart';

/// Where a link clicked inside Ayte originated.
enum LinkSource {
  chat,
  tool,
  terminal,
  editor,
  notification;

  String label({required bool zh}) => switch (this) {
    chat => zh ? '会话消息' : 'Chat Messages',
    tool => zh ? '工具结果' : 'Tool Results',
    terminal => zh ? '终端' : 'Terminal',
    editor => zh ? '编辑器' : 'Editor',
    notification => zh ? '通知' : 'Notifications',
  };
}

/// Target browser for opening a link.
enum LinkOpenTarget {
  embedded,
  system;

  static LinkOpenTarget parse(Object? raw) =>
      raw == 'system' ? system : embedded;
}

/// Site-specific override rule action.
enum SiteRuleAction {
  embedded,
  system,
  block;

  static SiteRuleAction parse(Object? raw) => switch (raw) {
    'system' => system,
    'block' => block,
    _ => embedded,
  };

  String label({required bool zh}) => switch (this) {
    embedded => zh ? '始终用内置浏览器' : 'Always Embedded',
    system => zh ? '始终用系统浏览器' : 'Always System Browser',
    block => zh ? '阻止' : 'Block',
  };
}

/// Default or per-tab permission granted to agents for an embedded browser tab.
enum EmbeddedSharePermission {
  none,
  read,
  readWrite;

  static EmbeddedSharePermission parse(Object? raw) => switch (raw) {
    'none' => none,
    'read' => read,
    _ => readWrite,
  };

  String label({required bool zh}) => switch (this) {
    none => zh ? '不共享' : 'Not Shared',
    read => zh ? '仅读取' : 'Read Only',
    readWrite => zh ? '读取并操作' : 'Read & Operate',
  };

  bool get canRead => this == read || this == readWrite;
  bool get canOperate => this == readWrite;
}

/// Policy when an agent wants to run custom JavaScript inside an embedded tab.
enum JsExecutionPolicy {
  silent,
  ask;

  static JsExecutionPolicy parse(Object? raw) =>
      raw == 'ask' ? ask : silent;
}

/// How Ayte reacts when a local dev server URL appears in terminal output.
enum LocalServerAction {
  ignore,
  notify,
  openTab;

  static LocalServerAction parse(Object? raw) => switch (raw) {
    'ignore' => ignore,
    'openTab' => openTab,
    _ => notify,
  };
}

/// How embedded browser tabs are hosted on desktop.
enum BrowserTabHostMode {
  auto,
  embedded,
  detached;

  static BrowserTabHostMode parse(Object? raw) => switch (raw) {
    'embedded' => embedded,
    'detached' => detached,
    _ => auto,
  };
}

@immutable
class SiteRule {
  const SiteRule({required this.pattern, required this.action});

  final String pattern;
  final SiteRuleAction action;

  Map<String, Object?> toJson() => {'pattern': pattern, 'action': action.name};

  static SiteRule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final pat = raw['pattern'];
    if (pat is! String || pat.trim().isEmpty) return null;
    return SiteRule(
      pattern: pat.trim().toLowerCase(),
      action: SiteRuleAction.parse(raw['action']),
    );
  }

  /// Validates a site pattern: `host`, `*.example.com`, or `*`, with optional `:port`.
  static bool isValidPattern(String raw) {
    final trimmed = raw.trim().toLowerCase();
    if (trimmed.isEmpty || trimmed.contains(' ') || trimmed.contains('/')) {
      return false;
    }
    var hostPart = trimmed;
    final colonIdx = trimmed.lastIndexOf(':');
    if (colonIdx != -1) {
      final portStr = trimmed.substring(colonIdx + 1);
      final port = int.tryParse(portStr);
      if (port == null || port < 1 || port > 65535) return false;
      hostPart = trimmed.substring(0, colonIdx);
    }
    if (hostPart == '*') return true;
    if (hostPart.startsWith('*.')) {
      final rest = hostPart.substring(2);
      return rest.isNotEmpty &&
          !rest.contains('*') &&
          RegExp(r'^[a-z0-9.-]+$').hasMatch(rest);
    }
    return !hostPart.contains('*') &&
        RegExp(r'^[a-z0-9.-]+$').hasMatch(hostPart);
  }

  /// Returns a specificity score > 0 if [uri] matches this rule, or 0 if not.
  /// Exact host + port > exact host > wildcard subdomain + port > wildcard subdomain > `*`.
  int matchSpecificity(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return 0;
    final uriPort = uri.hasPort
        ? uri.port
        : (uri.scheme == 'https' ? 443 : 80);

    var patHost = pattern.toLowerCase();
    int? patPort;
    final colonIdx = patHost.lastIndexOf(':');
    if (colonIdx != -1) {
      patPort = int.tryParse(patHost.substring(colonIdx + 1));
      patHost = patHost.substring(0, colonIdx);
    }
    if (patPort != null && patPort != uriPort) return 0;
    final portBonus = patPort != null ? 10 : 0;

    if (patHost == '*') return 1 + portBonus;
    if (patHost.startsWith('*.')) {
      final suffix = patHost.substring(2);
      if (host == suffix || host.endsWith('.$suffix')) {
        return 100 + suffix.length + portBonus;
      }
      return 0;
    }
    if (host == patHost) {
      return 1000 + patHost.length + portBonus;
    }
    return 0;
  }
}

@immutable
class BrowserProfile {
  const BrowserProfile({required this.id, required this.name});

  static const defaultId = 'default';

  final String id;
  final String name;

  bool get isDefault => id == defaultId;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  static BrowserProfile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || id.isEmpty || name is! String || name.trim().isEmpty) {
      return null;
    }
    return BrowserProfile(id: id, name: name.trim());
  }
}

/// Complete settings model for the workspace Embedded Browser (`embeddedBrowser.*`).
@immutable
class EmbeddedBrowserConfig {
  const EmbeddedBrowserConfig({
    this.enabled = true,
    this.agentReadWriteEnabled = true,
    this.agentEvalJsEnabled = false,
    this.linkTargets = const {
      LinkSource.chat: LinkOpenTarget.embedded,
      LinkSource.tool: LinkOpenTarget.embedded,
      LinkSource.terminal: LinkOpenTarget.embedded,
      LinkSource.editor: LinkOpenTarget.embedded,
      LinkSource.notification: LinkOpenTarget.embedded,
    },
    this.siteRules = const [],
    this.defaultSharePermission = EmbeddedSharePermission.readWrite,
    this.jsExecutionPolicy = JsExecutionPolicy.silent,
    this.localServerAction = LocalServerAction.notify,
    this.terminalLinkMenu = false,
    this.htmlPreviewInEmbedded = true,
    this.inspectorEnabled = true,
    this.tabHostMode = BrowserTabHostMode.auto,
    this.googleSignInCompat = true,
    this.profiles = const [
      BrowserProfile(id: BrowserProfile.defaultId, name: 'Default'),
    ],
    this.defaultProfileId = BrowserProfile.defaultId,
  });

  static const enabledKey = 'embeddedBrowser.enabled';
  static const agentReadWriteKey = 'embeddedBrowser.agentReadWrite';
  static const agentEvalJsKey = 'embeddedBrowser.agentEvalJs';
  static const linkTargetsKey = 'embeddedBrowser.linkTargets';
  static const siteRulesKey = 'embeddedBrowser.siteRules';
  static const defaultShareKey = 'embeddedBrowser.defaultSharePermission';
  static const jsPolicyKey = 'embeddedBrowser.jsExecutionPolicy';
  static const localServerKey = 'embeddedBrowser.localServerAction';
  static const terminalLinkMenuKey = 'embeddedBrowser.terminalLinkMenu';
  static const htmlPreviewKey = 'embeddedBrowser.htmlPreviewInEmbedded';
  static const inspectorKey = 'embeddedBrowser.inspectorEnabled';
  static const tabHostModeKey = 'embeddedBrowser.tabHostMode';
  static const googleSignInKey = 'embeddedBrowser.googleSignInCompat';
  static const profilesKey = 'embeddedBrowser.profiles';
  static const defaultProfileKey = 'embeddedBrowser.defaultProfileId';

  final bool enabled;
  final bool agentReadWriteEnabled;
  final bool agentEvalJsEnabled;
  final Map<LinkSource, LinkOpenTarget> linkTargets;
  final List<SiteRule> siteRules;
  final EmbeddedSharePermission defaultSharePermission;
  final JsExecutionPolicy jsExecutionPolicy;
  final LocalServerAction localServerAction;
  final bool terminalLinkMenu;
  final bool htmlPreviewInEmbedded;
  final bool inspectorEnabled;
  final BrowserTabHostMode tabHostMode;
  final bool googleSignInCompat;
  final List<BrowserProfile> profiles;
  final String defaultProfileId;

  bool get effectiveAgentEvalJs =>
      enabled && agentReadWriteEnabled && agentEvalJsEnabled;

  factory EmbeddedBrowserConfig.fromSettings(
    Object? Function(String key) read,
  ) {
    final targets = <LinkSource, LinkOpenTarget>{
      for (final s in LinkSource.values) s: LinkOpenTarget.embedded,
    };
    final rawTargets = read(linkTargetsKey);
    if (rawTargets is Map) {
      for (final s in LinkSource.values) {
        if (rawTargets.containsKey(s.name)) {
          targets[s] = LinkOpenTarget.parse(rawTargets[s.name]);
        }
      }
    }

    final rules = <SiteRule>[];
    final rawRules = read(siteRulesKey);
    if (rawRules is List) {
      for (final item in rawRules) {
        final parsed = SiteRule.fromJson(item);
        if (parsed != null) rules.add(parsed);
      }
    }

    final profiles = <BrowserProfile>[
      const BrowserProfile(id: BrowserProfile.defaultId, name: 'Default'),
    ];
    final rawProfiles = read(profilesKey);
    if (rawProfiles is List) {
      for (final item in rawProfiles) {
        final p = BrowserProfile.fromJson(item);
        if (p != null && !p.isDefault && !profiles.any((e) => e.id == p.id)) {
          profiles.add(p);
        }
      }
    }
    final rawDefaultProfile = read(defaultProfileKey);
    final defaultProfile =
        rawDefaultProfile is String &&
            profiles.any((e) => e.id == rawDefaultProfile)
        ? rawDefaultProfile
        : BrowserProfile.defaultId;

    return EmbeddedBrowserConfig(
      enabled: read(enabledKey) != false,
      agentReadWriteEnabled: read(agentReadWriteKey) != false,
      agentEvalJsEnabled: read(agentEvalJsKey) == true,
      linkTargets: targets,
      siteRules: rules,
      defaultSharePermission: EmbeddedSharePermission.parse(
        read(defaultShareKey),
      ),
      jsExecutionPolicy: JsExecutionPolicy.parse(read(jsPolicyKey)),
      localServerAction: LocalServerAction.parse(read(localServerKey)),
      terminalLinkMenu: read(terminalLinkMenuKey) == true,
      htmlPreviewInEmbedded: read(htmlPreviewKey) != false,
      inspectorEnabled: read(inspectorKey) != false,
      tabHostMode: BrowserTabHostMode.parse(read(tabHostModeKey)),
      googleSignInCompat: read(googleSignInKey) != false,
      profiles: profiles,
      defaultProfileId: defaultProfile,
    );
  }

  Map<String, Object?> toSettingsMap() => {
    enabledKey: enabled ? null : false,
    agentReadWriteKey: agentReadWriteEnabled ? null : false,
    agentEvalJsKey: agentEvalJsEnabled ? true : null,
    linkTargetsKey: {
      for (final e in linkTargets.entries) e.key.name: e.value.name,
    },
    siteRulesKey: siteRules.isEmpty
        ? null
        : [for (final r in siteRules) r.toJson()],
    defaultShareKey:
        defaultSharePermission == EmbeddedSharePermission.readWrite
        ? null
        : defaultSharePermission.name,
    jsPolicyKey: jsExecutionPolicy == JsExecutionPolicy.silent
        ? null
        : jsExecutionPolicy.name,
    localServerKey: localServerAction == LocalServerAction.notify
        ? null
        : localServerAction.name,
    terminalLinkMenuKey: terminalLinkMenu ? true : null,
    htmlPreviewKey: htmlPreviewInEmbedded ? null : false,
    inspectorKey: inspectorEnabled ? null : false,
    tabHostModeKey: tabHostMode == BrowserTabHostMode.auto
        ? null
        : tabHostMode.name,
    googleSignInKey: googleSignInCompat ? null : false,
    profilesKey: profiles.length <= 1
        ? null
        : [for (final p in profiles) p.toJson()],
    defaultProfileKey: defaultProfileId == BrowserProfile.defaultId
        ? null
        : defaultProfileId,
  };

  EmbeddedBrowserConfig copyWith({
    bool? enabled,
    bool? agentReadWriteEnabled,
    bool? agentEvalJsEnabled,
    Map<LinkSource, LinkOpenTarget>? linkTargets,
    List<SiteRule>? siteRules,
    EmbeddedSharePermission? defaultSharePermission,
    JsExecutionPolicy? jsExecutionPolicy,
    LocalServerAction? localServerAction,
    bool? terminalLinkMenu,
    bool? htmlPreviewInEmbedded,
    bool? inspectorEnabled,
    BrowserTabHostMode? tabHostMode,
    bool? googleSignInCompat,
    List<BrowserProfile>? profiles,
    String? defaultProfileId,
  }) => EmbeddedBrowserConfig(
    enabled: enabled ?? this.enabled,
    agentReadWriteEnabled: agentReadWriteEnabled ?? this.agentReadWriteEnabled,
    agentEvalJsEnabled: agentEvalJsEnabled ?? this.agentEvalJsEnabled,
    linkTargets: linkTargets ?? this.linkTargets,
    siteRules: siteRules ?? this.siteRules,
    defaultSharePermission:
        defaultSharePermission ?? this.defaultSharePermission,
    jsExecutionPolicy: jsExecutionPolicy ?? this.jsExecutionPolicy,
    localServerAction: localServerAction ?? this.localServerAction,
    terminalLinkMenu: terminalLinkMenu ?? this.terminalLinkMenu,
    htmlPreviewInEmbedded: htmlPreviewInEmbedded ?? this.htmlPreviewInEmbedded,
    inspectorEnabled: inspectorEnabled ?? this.inspectorEnabled,
    tabHostMode: tabHostMode ?? this.tabHostMode,
    googleSignInCompat: googleSignInCompat ?? this.googleSignInCompat,
    profiles: profiles ?? this.profiles,
    defaultProfileId: defaultProfileId ?? this.defaultProfileId,
  );

  /// Finds the most specific matching site rule for [uri], or null if none match.
  SiteRule? matchSiteRule(Uri uri) {
    SiteRule? best;
    var bestScore = 0;
    for (final rule in siteRules) {
      final score = rule.matchSpecificity(uri);
      if (score > bestScore) {
        bestScore = score;
        best = rule;
      }
    }
    return best;
  }

  /// Resolves how [uri] from [source] should be opened.
  /// If [invertChoice] is true (e.g. holding ⌘/Ctrl), flips embedded <-> system
  /// unless the site is explicitly blocked.
  SiteRuleAction resolveAction(
    Uri uri, {
    LinkSource source = LinkSource.chat,
    bool invertChoice = false,
  }) {
    final matched = matchSiteRule(uri);
    if (matched != null) {
      if (matched.action == SiteRuleAction.block) return SiteRuleAction.block;
      if (!invertChoice) return matched.action;
      return matched.action == SiteRuleAction.embedded
          ? SiteRuleAction.system
          : SiteRuleAction.embedded;
    }
    if (!enabled) return SiteRuleAction.system;
    final target = linkTargets[source] ?? LinkOpenTarget.embedded;
    final base = target == LinkOpenTarget.embedded
        ? SiteRuleAction.embedded
        : SiteRuleAction.system;
    if (!invertChoice) return base;
    return base == SiteRuleAction.embedded
        ? SiteRuleAction.system
        : SiteRuleAction.embedded;
  }
}
