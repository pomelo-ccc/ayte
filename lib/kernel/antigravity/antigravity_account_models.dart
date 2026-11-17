import 'dart:math' as math;

/// Subscription tier classification for Antigravity accounts.
enum AntigravityTier {
  ultra('ULTRA'),
  pro('PRO'),
  free('FREE'),
  unknown('UNKNOWN');

  const AntigravityTier(this.badge);
  final String badge;

  static AntigravityTier fromRaw(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return AntigravityTier.unknown;
    final lower = trimmed.toLowerCase();
    if (lower.contains('ultra')) return AntigravityTier.ultra;
    if (lower.contains('pro')) return AntigravityTier.pro;
    return AntigravityTier.free;
  }
}

/// Canonical quota pool buckets returned by Cloud Code PA.
enum AntigravityQuotaPool {
  gemini('gemini', 'Gemini'),
  thirdParty('3p', 'Claude / GPT'),
  argon('argon', 'Argon'),
  carbon('carbon', 'Carbon');

  const AntigravityQuotaPool(this.key, this.shortLabel);
  final String key;
  final String shortLabel;

  /// Classifies a bucket by `bucket_id` first, then `group_name`.
  static AntigravityQuotaPool? classify(String bucketId, String groupName) {
    final id = bucketId.trim().toLowerCase();
    if (id == 'gemini-5h' || id == 'gemini-weekly') {
      return AntigravityQuotaPool.gemini;
    }
    if (id == '3p-5h' || id == '3p-weekly') {
      return AntigravityQuotaPool.thirdParty;
    }
    if (id == 'gemini-argon-wtu-weekly' || id.startsWith('gemini-argon-')) {
      return AntigravityQuotaPool.argon;
    }
    if (id == 'gemini-carbon-wtu-weekly' ||
        id == 'gemini-carbon-5h' ||
        id.startsWith('gemini-carbon-')) {
      return AntigravityQuotaPool.carbon;
    }
    if (id.startsWith('gemini-') || id.startsWith('3p-')) {
      return null;
    }

    final group = groupName.trim().toLowerCase();
    return switch (group) {
      'gemini' || 'gemini models' => AntigravityQuotaPool.gemini,
      'claude' ||
      'claude / gpt' ||
      'claude/gpt' ||
      'claude/gpt models' ||
      'claude and gpt models' => AntigravityQuotaPool.thirdParty,
      'gemini 4 argon' => AntigravityQuotaPool.argon,
      'gemini 4 carbon' => AntigravityQuotaPool.carbon,
      _ => null,
    };
  }

  static AntigravityQuotaPool? ofModel(String name, [String displayName = '']) {
    final lower = name.trim().toLowerCase();
    if (lower.startsWith('gemini')) {
      final words = '$lower ${displayName.toLowerCase()}'
          .split(RegExp(r'[^a-z0-9]+'))
          .where((w) => w.isNotEmpty)
          .toSet();
      if (lower.startsWith('gemini-pro-orchestrator')) {
        return (words.contains('argon') || lower.contains('g1-pro'))
            ? AntigravityQuotaPool.argon
            : AntigravityQuotaPool.carbon;
      }
      if (words.contains('carbon') || lower.startsWith('gemini-4-carbon')) {
        return AntigravityQuotaPool.carbon;
      }
      if (words.contains('argon') || lower.startsWith('gemini-4-argon')) {
        return AntigravityQuotaPool.argon;
      }
      return AntigravityQuotaPool.gemini;
    }
    if (lower.startsWith('claude') || lower.startsWith('gpt')) {
      return AntigravityQuotaPool.thirdParty;
    }
    return null;
  }
}

/// Quota display window in the UI (`5h` rolling vs `weekly`).
enum AntigravityQuotaWindow {
  fiveHour('5h', '5H 窗口'),
  weekly('weekly', '周配额');

  const AntigravityQuotaWindow(this.id, this.label);
  final String id;
  final String label;
}

/// OAuth2 token bundle persisted per Antigravity account.
class AntigravityTokenData {
  const AntigravityTokenData({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.expiryTimestamp,
    this.tokenType = 'Bearer',
    this.email,
    this.projectId,
    this.oauthClientKey,
    this.sessionId,
    this.isGcpTos = false,
    this.idToken,
  });

  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final int expiryTimestamp; // Unix seconds
  final String tokenType;
  final String? email;
  final String? projectId;
  final String? oauthClientKey;
  final String? sessionId;
  final bool isGcpTos;
  final String? idToken;

  bool isFresh({int skewSeconds = 900}) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return accessToken.isNotEmpty && expiryTimestamp > nowSec + skewSeconds;
  }

  /// Effective `is_gcp_tos` normalized for consumer accounts.
  bool effectiveIsGcpTos(String accountEmail) {
    if (oauthClientKey == 'antigravity_enterprise') return false;
    final lower = accountEmail.trim().toLowerCase();
    const consumerSuffixes = [
      '@gmail.com',
      '@outlook.com',
      '@hotmail.com',
      '@qq.com',
      '@163.com',
    ];
    if (consumerSuffixes.any(lower.endsWith)) return false;
    return isGcpTos;
  }

  /// Formats `expiryTimestamp` as UTC RFC3339 with microsecond precision,
  /// matching `agy` CLI and Keychain credential expectations.
  String get rfc3339MicrosExpiry {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      expiryTimestamp * 1000,
      isUtc: true,
    );
    String pad2(int n) => n.toString().padLeft(2, '0');
    final y = dt.year.toString().padLeft(4, '0');
    return '$y-${pad2(dt.month)}-${pad2(dt.day)}T'
        '${pad2(dt.hour)}:${pad2(dt.minute)}:${pad2(dt.second)}.000000Z';
  }

  /// Native JSON payload stored in Keychain and `antigravity-oauth-token`.
  Map<String, Object?> toCliCredentialJson() => {
    'token': {
      'access_token': accessToken,
      'token_type': tokenType.isEmpty ? 'Bearer' : tokenType,
      'refresh_token': refreshToken,
      'expiry': rfc3339MicrosExpiry,
    },
    'auth_method': 'consumer',
    if (idToken case final id? when id.isNotEmpty) 'id_token': id,
  };

  AntigravityTokenData copyWith({
    String? accessToken,
    String? refreshToken,
    int? expiresIn,
    int? expiryTimestamp,
    String? tokenType,
    String? email,
    String? projectId,
    String? oauthClientKey,
    String? sessionId,
    bool? isGcpTos,
    String? idToken,
  }) => AntigravityTokenData(
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    expiresIn: expiresIn ?? this.expiresIn,
    expiryTimestamp: expiryTimestamp ?? this.expiryTimestamp,
    tokenType: tokenType ?? this.tokenType,
    email: email ?? this.email,
    projectId: projectId ?? this.projectId,
    oauthClientKey: oauthClientKey ?? this.oauthClientKey,
    sessionId: sessionId ?? this.sessionId,
    isGcpTos: isGcpTos ?? this.isGcpTos,
    idToken: idToken ?? this.idToken,
  );

  factory AntigravityTokenData.fromJson(Map<String, Object?> json) {
    return AntigravityTokenData(
      accessToken: '${json['access_token'] ?? ''}',
      refreshToken: '${json['refresh_token'] ?? ''}',
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 3599,
      expiryTimestamp: (json['expiry_timestamp'] as num?)?.toInt() ?? 0,
      tokenType: (json['token_type'] as String?) ?? 'Bearer',
      email: json['email'] as String?,
      projectId: json['project_id'] as String?,
      oauthClientKey: json['oauth_client_key'] as String?,
      sessionId: json['session_id'] as String?,
      isGcpTos: json['is_gcp_tos'] == true,
      idToken: json['id_token'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_in': expiresIn,
    'expiry_timestamp': expiryTimestamp,
    'token_type': tokenType,
    'email': email,
    if (projectId != null) 'project_id': projectId,
    if (oauthClientKey != null) 'oauth_client_key': oauthClientKey,
    if (sessionId != null) 'session_id': sessionId,
    'is_gcp_tos': isGcpTos,
    if (idToken != null) 'id_token': idToken,
  };
}

/// Device telemetry profile isolated per account.
class AntigravityDeviceProfile {
  const AntigravityDeviceProfile({
    required this.machineId,
    required this.macMachineId,
    required this.devDeviceId,
    required this.sqmId,
  });

  final String machineId;
  final String macMachineId;
  final String devDeviceId;
  final String sqmId;

  factory AntigravityDeviceProfile.generate() {
    final rng = math.Random.secure();
    const alnum = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final suffix = List.generate(
      32,
      (_) => alnum[rng.nextInt(alnum.length)],
    ).join();
    final macId = _uuidV4(rng);
    final devId = _uuidV4(rng);
    final sqm = '{${_uuidV4(rng).toUpperCase()}}';
    return AntigravityDeviceProfile(
      machineId: 'auth0|user_$suffix',
      macMachineId: macId,
      devDeviceId: devId,
      sqmId: sqm,
    );
  }

  static String _uuidV4(math.Random rng) {
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => [
      for (var i = start; i < end; i++) bytes[i].toRadixString(16).padLeft(2, '0'),
    ].join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  factory AntigravityDeviceProfile.fromJson(Map<String, Object?> json) =>
      AntigravityDeviceProfile(
        machineId: '${json['machine_id'] ?? ''}',
        macMachineId: '${json['mac_machine_id'] ?? ''}',
        devDeviceId: '${json['dev_device_id'] ?? ''}',
        sqmId: '${json['sqm_id'] ?? ''}',
      );

  Map<String, Object?> toJson() => {
    'machine_id': machineId,
    'mac_machine_id': macMachineId,
    'dev_device_id': devDeviceId,
    'sqm_id': sqmId,
  };
}

/// One window (`5h` or `weekly`) inside a quota group.
class AntigravityQuotaBucket {
  const AntigravityQuotaBucket({
    required this.bucketId,
    required this.window,
    required this.remainingFraction,
    this.remainingFractionKnown = true,
    this.resetTime = '',
    this.displayName = '',
    this.description,
  });

  final String bucketId;
  final String window; // '5h' | 'weekly'
  final double remainingFraction;
  final bool remainingFractionKnown;
  final String resetTime; // RFC3339
  final String displayName;
  final String? description;

  int get percentage =>
      remainingFractionKnown ? (remainingFraction.clamp(0.0, 1.0) * 100).round() : 0;

  DateTime? get resetAt =>
      resetTime.isEmpty ? null : DateTime.tryParse(resetTime)?.toUtc();

  factory AntigravityQuotaBucket.fromJson(Map<String, Object?> json) {
    final rawFrac = json['remaining_fraction'] ?? json['remainingFraction'];
    final hasFrac =
        rawFrac is num && rawFrac.isFinite && rawFrac >= 0.0 && rawFrac <= 1.0;
    return AntigravityQuotaBucket(
      bucketId: '${json['bucket_id'] ?? json['bucketId'] ?? ''}',
      window: '${json['window'] ?? ''}',
      remainingFraction: hasFrac ? rawFrac.toDouble() : 0.0,
      remainingFractionKnown: json['remaining_fraction_known'] is bool
          ? json['remaining_fraction_known'] as bool
          : hasFrac,
      resetTime: '${json['reset_time'] ?? json['resetTime'] ?? ''}',
      displayName: '${json['display_name'] ?? json['displayName'] ?? ''}',
      description: json['description'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'bucket_id': bucketId,
    'window': window,
    'remaining_fraction': remainingFraction,
    'remaining_fraction_known': remainingFractionKnown,
    'reset_time': resetTime,
    'display_name': displayName,
    if (description != null) 'description': description,
  };
}

/// A group of quota buckets (`Gemini Models`, `Claude and GPT models`, etc.).
class AntigravityQuotaGroup {
  const AntigravityQuotaGroup({
    required this.displayName,
    this.description,
    this.buckets = const [],
  });

  final String displayName;
  final String? description;
  final List<AntigravityQuotaBucket> buckets;

  factory AntigravityQuotaGroup.fromJson(Map<String, Object?> json) {
    final rawBuckets = json['buckets'];
    return AntigravityQuotaGroup(
      displayName: '${json['display_name'] ?? json['displayName'] ?? ''}',
      description: json['description'] as String?,
      buckets: [
        if (rawBuckets is List)
          for (final item in rawBuckets)
            if (item is Map)
              AntigravityQuotaBucket.fromJson(item.cast<String, Object?>()),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'display_name': displayName,
    if (description != null) 'description': description,
    'buckets': [for (final b in buckets) b.toJson()],
  };
}

/// Per-model quota observation returned by `fetchAvailableModels`.
class AntigravityModelQuota {
  const AntigravityModelQuota({
    required this.name,
    required this.percentage,
    this.percentageKnown = true,
    this.observedRemainingFraction,
    this.primaryRemainingFraction,
    this.primaryResetTime,
    this.quotaBucketId,
    this.resetTime = '',
    this.displayName,
    this.supportsImages,
    this.supportsThinking,
    this.thinkingBudget,
    this.recommended,
    this.maxTokens,
    this.maxOutputTokens,
  });

  final String name;
  final int percentage;
  final bool percentageKnown;
  final double? observedRemainingFraction;
  final double? primaryRemainingFraction;
  final String? primaryResetTime;
  final String? quotaBucketId;
  final String resetTime;
  final String? displayName;
  final bool? supportsImages;
  final bool? supportsThinking;
  final int? thinkingBudget;
  final bool? recommended;
  final int? maxTokens;
  final int? maxOutputTokens;

  factory AntigravityModelQuota.fromJson(Map<String, Object?> json) {
    final primary = (json['primary_quota'] as Map?)?.cast<String, Object?>();
    return AntigravityModelQuota(
      name: '${json['name'] ?? ''}',
      percentage: (json['percentage'] as num?)?.toInt() ?? 0,
      percentageKnown: json['percentage_known'] != false,
      observedRemainingFraction:
          (json['observed_remaining_fraction'] as num?)?.toDouble(),
      primaryRemainingFraction:
          (primary?['remaining_fraction'] as num?)?.toDouble(),
      primaryResetTime: primary?['reset_time'] as String?,
      quotaBucketId: json['quota_bucket_id'] as String?,
      resetTime: '${json['reset_time'] ?? ''}',
      displayName: json['display_name'] as String?,
      supportsImages: json['supports_images'] as bool?,
      supportsThinking: json['supports_thinking'] as bool?,
      thinkingBudget: (json['thinking_budget'] as num?)?.toInt(),
      recommended: json['recommended'] as bool?,
      maxTokens: (json['max_tokens'] as num?)?.toInt(),
      maxOutputTokens: (json['max_output_tokens'] as num?)?.toInt(),
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'percentage': percentage,
    'percentage_known': percentageKnown,
    if (observedRemainingFraction != null)
      'observed_remaining_fraction': observedRemainingFraction,
    if (primaryRemainingFraction != null)
      'primary_quota': {
        'remaining_fraction': primaryRemainingFraction,
        'reset_time': primaryResetTime ?? '',
      },
    if (quotaBucketId != null) 'quota_bucket_id': quotaBucketId,
    'reset_time': resetTime,
    if (displayName != null) 'display_name': displayName,
    if (supportsImages != null) 'supports_images': supportsImages,
    if (supportsThinking != null) 'supports_thinking': supportsThinking,
    if (thinkingBudget != null) 'thinking_budget': thinkingBudget,
    if (recommended != null) 'recommended': recommended,
    if (maxTokens != null) 'max_tokens': maxTokens,
    if (maxOutputTokens != null) 'max_output_tokens': maxOutputTokens,
  };
}

///Resolved pool status for UI display in a selected [AntigravityQuotaWindow].
class AntigravityPoolDisplay {
  const AntigravityPoolDisplay({
    required this.pool,
    required this.percentage,
    required this.resetTime,
    required this.windowLabel,
  });

  final AntigravityQuotaPool pool;
  final int percentage;
  final String resetTime;
  final String? windowLabel; // e.g. '周' when Argon only has weekly in 5H mode
}

/// Complete quota snapshot for an Antigravity account.
class AntigravityQuotaData {
  const AntigravityQuotaData({
    this.models = const [],
    required this.lastUpdated,
    this.isForbidden = false,
    this.forbiddenReason,
    this.subscriptionTier,
    this.modelForwardingRules = const {},
    this.quotaGroups,
  });

  final List<AntigravityModelQuota> models;
  final int lastUpdated; // Unix seconds
  final bool isForbidden;
  final String? forbiddenReason;
  final String? subscriptionTier;
  final Map<String, String> modelForwardingRules;
  final List<AntigravityQuotaGroup>? quotaGroups;

  AntigravityTier get tier => AntigravityTier.fromRaw(subscriptionTier);

  /// Extracts pool quota cards for [window] (`5h` or `weekly`).
  List<AntigravityPoolDisplay> poolDisplays(AntigravityQuotaWindow window) {
    final byPool = <AntigravityQuotaPool, Map<String, AntigravityQuotaBucket>>{};
    final groups = quotaGroups ?? const [];
    for (final group in groups) {
      for (final bucket in group.buckets) {
        if (!bucket.remainingFractionKnown) continue;
        final pool = AntigravityQuotaPool.classify(
          bucket.bucketId,
          group.displayName,
        );
        if (pool == null) continue;
        byPool.putIfAbsent(pool, () => {})[bucket.window] = bucket;
      }
    }

    final displays = <AntigravityPoolDisplay>[];
    for (final pool in AntigravityQuotaPool.values) {
      final windows = byPool[pool];
      if (windows != null && windows.isNotEmpty) {
        final chosen = windows[window.id] ??
            (pool == AntigravityQuotaPool.argon ? windows['weekly'] : null) ??
            windows.values.first;
        final isFallbackWeekly =
            window == AntigravityQuotaWindow.fiveHour &&
            chosen.window == 'weekly';
        displays.add(
          AntigravityPoolDisplay(
            pool: pool,
            percentage: chosen.percentage,
            resetTime: chosen.resetTime,
            windowLabel: isFallbackWeekly ? '周' : null,
          ),
        );
        continue;
      }

      // Fallback from single-model observations when `quota_groups` is absent.
      final matching = models.where(
        (m) =>
            m.percentageKnown &&
            !m.name.endsWith('-disabled') &&
            AntigravityQuotaPool.ofModel(m.name, m.displayName ?? '') == pool,
      );
      if (matching.isNotEmpty) {
        final strictest = matching.reduce(
          (a, b) => a.percentage <= b.percentage ? a : b,
        );
        displays.add(
          AntigravityPoolDisplay(
            pool: pool,
            percentage: strictest.percentage,
            resetTime: strictest.resetTime,
            windowLabel: null,
          ),
        );
      }
    }
    return displays;
  }

  /// Strictest effective percentage for [modelId] across `5h` & `weekly`.
  int? effectivePercentageForModel(String? modelId) {
    final pool = modelId == null || modelId.isEmpty
        ? AntigravityQuotaPool.gemini
        : (AntigravityQuotaPool.ofModel(modelId) ??
              AntigravityQuotaPool.gemini);
    final groups = quotaGroups ?? const [];
    double? minFrac;
    for (final g in groups) {
      for (final b in g.buckets) {
        if (!b.remainingFractionKnown) continue;
        if (AntigravityQuotaPool.classify(b.bucketId, g.displayName) == pool) {
          minFrac = minFrac == null
              ? b.remainingFraction
              : math.min(minFrac, b.remainingFraction);
        }
      }
    }
    if (minFrac != null) return (minFrac.clamp(0.0, 1.0) * 100).round();
    final matching = models.where(
      (m) => m.percentageKnown && AntigravityQuotaPool.ofModel(m.name) == pool,
    );
    if (matching.isEmpty) return null;
    return matching.map((m) => m.percentage).reduce(math.min);
  }

  /// Lowest remaining percentage across primary pools (`Gemini` & `Claude/GPT`).
  int? get lowestPrimaryPercentage {
    final candidates = <int>[
      ?effectivePercentageForModel('gemini-4-hydrogen'),
      ?effectivePercentageForModel('claude-sonnet-5-5'),
    ];
    if (candidates.isEmpty) return null;
    return candidates.reduce(math.min);
  }

  factory AntigravityQuotaData.fromJson(Map<String, Object?> json) {
    final rawModels = json['models'];
    final rawRules = json['model_forwarding_rules'];
    final rawGroups = json['quota_groups'];
    return AntigravityQuotaData(
      models: [
        if (rawModels is List)
          for (final m in rawModels)
            if (m is Map)
              AntigravityModelQuota.fromJson(m.cast<String, Object?>()),
      ],
      lastUpdated: (json['last_updated'] as num?)?.toInt() ?? 0,
      isForbidden: json['is_forbidden'] == true,
      forbiddenReason: json['forbidden_reason'] as String?,
      subscriptionTier: json['subscription_tier'] as String?,
      modelForwardingRules: {
        if (rawRules is Map)
          for (final MapEntry(:key, :value) in rawRules.entries)
            if (key is String && value is String) key: value,
      },
      quotaGroups: rawGroups is List
          ? [
              for (final g in rawGroups)
                if (g is Map)
                  AntigravityQuotaGroup.fromJson(g.cast<String, Object?>()),
            ]
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'models': [for (final m in models) m.toJson()],
    'last_updated': lastUpdated,
    'is_forbidden': isForbidden,
    'forbidden_reason': forbiddenReason,
    'subscription_tier': subscriptionTier,
    'model_forwarding_rules': modelForwardingRules,
    'quota_groups': quotaGroups == null
        ? null
        : [for (final g in quotaGroups!) g.toJson()],
  };
}

/// Full Antigravity account record (`accounts/<id>.json`).
class AntigravityAccount {
  const AntigravityAccount({
    required this.id,
    required this.email,
    this.name,
    required this.token,
    this.deviceProfile,
    this.quota,
    this.disabled = false,
    this.disabledReason,
    this.disabledAt,
    this.protectedModels = const {},
    this.validationBlocked = false,
    this.validationBlockedUntil,
    this.validationBlockedReason,
    this.validationUrl,
    required this.createdAt,
    required this.lastUsed,
    this.customLabel,
  });

  final String id;
  final String email;
  final String? name;
  final AntigravityTokenData token;
  final AntigravityDeviceProfile? deviceProfile;
  final AntigravityQuotaData? quota;
  final bool disabled;
  final String? disabledReason;
  final int? disabledAt;
  final Set<String> protectedModels;
  final bool validationBlocked;
  final int? validationBlockedUntil;
  final String? validationBlockedReason;
  final String? validationUrl;
  final int createdAt; // Unix seconds
  final int lastUsed; // Unix seconds
  final String? customLabel;

  AntigravityTier get tier => quota?.tier ?? AntigravityTier.unknown;

  bool get isAvailable =>
      !disabled && !(quota?.isForbidden ?? false) && !validationBlocked;

  String get displayTitle {
    final custom = customLabel?.trim() ?? '';
    if (custom.isNotEmpty) return '$email ($custom)';
    final n = name?.trim() ?? '';
    if (n.isNotEmpty && n != email) return '$email ($n)';
    return email;
  }

  String get shortLabel {
    final custom = customLabel?.trim() ?? '';
    if (custom.isNotEmpty) return custom;
    final at = email.indexOf('@');
    return at > 0 ? email.substring(0, at) : email;
  }

  AntigravityAccount copyWith({
    String? email,
    String? name,
    AntigravityTokenData? token,
    AntigravityDeviceProfile? deviceProfile,
    AntigravityQuotaData? quota,
    bool? disabled,
    Object? disabledReason = _unset,
    Object? disabledAt = _unset,
    Set<String>? protectedModels,
    bool? validationBlocked,
    Object? validationBlockedUntil = _unset,
    Object? validationBlockedReason = _unset,
    Object? validationUrl = _unset,
    int? createdAt,
    int? lastUsed,
    Object? customLabel = _unset,
  }) => AntigravityAccount(
    id: id,
    email: email ?? this.email,
    name: name ?? this.name,
    token: token ?? this.token,
    deviceProfile: deviceProfile ?? this.deviceProfile,
    quota: quota ?? this.quota,
    disabled: disabled ?? this.disabled,
    disabledReason: identical(disabledReason, _unset)
        ? this.disabledReason
        : disabledReason as String?,
    disabledAt: identical(disabledAt, _unset)
        ? this.disabledAt
        : disabledAt as int?,
    protectedModels: protectedModels ?? this.protectedModels,
    validationBlocked: validationBlocked ?? this.validationBlocked,
    validationBlockedUntil: identical(validationBlockedUntil, _unset)
        ? this.validationBlockedUntil
        : validationBlockedUntil as int?,
    validationBlockedReason: identical(validationBlockedReason, _unset)
        ? this.validationBlockedReason
        : validationBlockedReason as String?,
    validationUrl: identical(validationUrl, _unset)
        ? this.validationUrl
        : validationUrl as String?,
    createdAt: createdAt ?? this.createdAt,
    lastUsed: lastUsed ?? this.lastUsed,
    customLabel: identical(customLabel, _unset)
        ? this.customLabel
        : customLabel as String?,
  );

  static const Object _unset = Object();

  factory AntigravityAccount.fromJson(Map<String, Object?> json) {
    final rawProtected = json['protected_models'];
    return AntigravityAccount(
      id: '${json['id'] ?? ''}',
      email: '${json['email'] ?? ''}',
      name: json['name'] as String?,
      token: AntigravityTokenData.fromJson(
        ((json['token'] as Map?) ?? const {}).cast<String, Object?>(),
      ),
      deviceProfile: json['device_profile'] is Map
          ? AntigravityDeviceProfile.fromJson(
              (json['device_profile'] as Map).cast<String, Object?>(),
            )
          : null,
      quota: json['quota'] is Map
          ? AntigravityQuotaData.fromJson(
              (json['quota'] as Map).cast<String, Object?>(),
            )
          : null,
      disabled: json['disabled'] == true,
      disabledReason: json['disabled_reason'] as String?,
      disabledAt: (json['disabled_at'] as num?)?.toInt(),
      protectedModels: {
        if (rawProtected is List)
          for (final p in rawProtected)
            if (p is String && p.isNotEmpty) p,
      },
      validationBlocked: json['validation_blocked'] == true,
      validationBlockedUntil:
          (json['validation_blocked_until'] as num?)?.toInt(),
      validationBlockedReason: json['validation_blocked_reason'] as String?,
      validationUrl: json['validation_url'] as String?,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      lastUsed: (json['last_used'] as num?)?.toInt() ?? 0,
      customLabel: json['custom_label'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'email': email,
    'name': name,
    'token': token.toJson(),
    if (deviceProfile != null) 'device_profile': deviceProfile!.toJson(),
    'quota': quota?.toJson(),
    'disabled': disabled,
    if (disabledReason != null) 'disabled_reason': disabledReason,
    if (disabledAt != null) 'disabled_at': disabledAt,
    if (protectedModels.isNotEmpty)
      'protected_models': protectedModels.toList()..sort(),
    'validation_blocked': validationBlocked,
    if (validationBlockedUntil != null)
      'validation_blocked_until': validationBlockedUntil,
    if (validationBlockedReason != null)
      'validation_blocked_reason': validationBlockedReason,
    if (validationUrl != null) 'validation_url': validationUrl,
    'created_at': createdAt,
    'last_used': lastUsed,
    if (customLabel case final l? when l.trim().isNotEmpty)
      'custom_label': l.trim(),
  };

  Map<String, Object?> toIndexSummaryJson() => {
    'id': id,
    'email': email,
    'name': name,
    'disabled': disabled,
    if (protectedModels.isNotEmpty)
      'protected_models': protectedModels.toList()..sort(),
    'created_at': createdAt,
    'last_used': lastUsed,
  };
}

/// Auto-switch configuration (`auto_switch.json`).
class AntigravityAutoSwitchConfig {
  const AntigravityAutoSwitchConfig({
    this.enabled = false,
    this.reservePercentage = 10,
    this.candidateMinPercentage = 25,
    this.syncExternalClients = false,
  });

  final bool enabled;
  final int reservePercentage;
  final int candidateMinPercentage;

  /// Whether switching accounts in Ayte also injects into external
  /// `Antigravity.app` / `Antigravity IDE.app` SQLite state in addition to
  /// Keychain + `agy` CLI credentials.
  final bool syncExternalClients;

  AntigravityAutoSwitchConfig copyWith({
    bool? enabled,
    int? reservePercentage,
    int? candidateMinPercentage,
    bool? syncExternalClients,
  }) => AntigravityAutoSwitchConfig(
    enabled: enabled ?? this.enabled,
    reservePercentage: reservePercentage ?? this.reservePercentage,
    candidateMinPercentage:
        candidateMinPercentage ?? this.candidateMinPercentage,
    syncExternalClients: syncExternalClients ?? this.syncExternalClients,
  );

  factory AntigravityAutoSwitchConfig.fromJson(Map<String, Object?> json) =>
      AntigravityAutoSwitchConfig(
        enabled: json['enabled'] == true,
        reservePercentage:
            ((json['reserve_percentage'] as num?)?.toInt() ?? 10).clamp(1, 95),
        candidateMinPercentage:
            ((json['candidate_min_percentage'] as num?)?.toInt() ?? 25).clamp(
              5,
              99,
            ),
        syncExternalClients: json['sync_external_clients'] == true,
      );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'reserve_percentage': reservePercentage,
    'candidate_min_percentage': candidateMinPercentage,
    'sync_external_clients': syncExternalClients,
  };
}

/// Formats an RFC3339 reset timestamp into a concise Chinese relative countdown.
String formatQuotaResetTime(String resetTime) {
  if (resetTime.isEmpty) return '';
  final dt = DateTime.tryParse(resetTime);
  if (dt == null) return '';
  final diff = dt.toUtc().difference(DateTime.now().toUtc());
  if (diff.inSeconds <= 0) return '即将重置';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分后重置';
  if (diff.inHours < 24) {
    final h = diff.inHours;
    final m = diff.inMinutes % 60;
    return m > 0 ? '$h小时$m分后重置' : '$h小时后重置';
  }
  final d = diff.inDays;
  final h = diff.inHours % 24;
  return h > 0 ? '$d天$h小时后重置' : '$d天后重置';
}
