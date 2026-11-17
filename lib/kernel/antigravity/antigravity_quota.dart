import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'antigravity_account_models.dart';
import 'antigravity_oauth.dart';

/// Fetches live Antigravity subscription tiers, model quotas, and 5h/weekly
/// quota buckets from Google Cloud Code PA endpoints.
abstract final class AntigravityQuotaFetcher {
  static const _loadCodeAssistEndpoints = [
    'https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:loadCodeAssist',
    'https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist',
    'https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist',
  ];

  static const _fetchModelsEndpoints = [
    'https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels',
    'https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels',
    'https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels',
  ];

  static const _quotaSummaryEndpoints = [
    'https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary',
    'https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary',
    'https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary',
  ];

  /// Refreshes token if needed and fetches a complete [AntigravityAccount]
  /// update with fresh quota & tier metadata.
  static Future<AntigravityAccount> refreshAccountQuota(
    AntigravityAccount account,
  ) async {
    AntigravityTokenData token;
    try {
      token = await AntigravityOAuth.ensureFreshToken(account.token);
    } on AntigravityAuthException catch (e) {
      if (e.isInvalidGrant) {
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        return account.copyWith(
          disabled: true,
          disabledAt: nowSec,
          disabledReason: e.message,
        );
      }
      if (_isValidationOrRateLimitError(e.message)) {
        return account.copyWith(
          validationBlocked: true,
          validationBlockedReason: e.message,
        );
      }
      rethrow;
    }

    try {
      final res = await _fetchQuotaOnce(
        token: token,
        previousTier: account.quota?.subscriptionTier,
      );
      return account.copyWith(
        token: res.token,
        quota: res.quota,
        validationBlocked: false,
        validationBlockedUntil: null,
        validationBlockedReason: null,
        validationUrl: null,
      );
    } on _UnauthorizedQuotaException {
      // Force-refresh token once on 401 and retry.
      try {
        token = await AntigravityOAuth.ensureFreshToken(token, force: true);
      } on AntigravityAuthException catch (e) {
        if (e.isInvalidGrant) {
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          return account.copyWith(
            disabled: true,
            disabledAt: nowSec,
            disabledReason: e.message,
          );
        }
        rethrow;
      }
      final res = await _fetchQuotaOnce(
        token: token,
        previousTier: account.quota?.subscriptionTier,
      );
      return account.copyWith(
        token: res.token,
        quota: res.quota,
        validationBlocked: false,
        validationBlockedUntil: null,
        validationBlockedReason: null,
        validationUrl: null,
      );
    } on Object catch (e) {
      final msg = '$e';
      if (_isValidationOrRateLimitError(msg)) {
        return account.copyWith(
          token: token,
          validationBlocked: true,
          validationBlockedReason: msg,
        );
      }
      rethrow;
    }
  }

  static bool _isValidationOrRateLimitError(String raw) {
    final lower = raw.toLowerCase();
    const keywords = [
      'verify your account',
      'further action is required',
      'validation_url',
      'appeal_url',
      'validation required',
      'too many requests',
      'resource_exhausted',
      'resource has been exhausted',
    ];
    return keywords.any(lower.contains);
  }

  static Future<({AntigravityTokenData token, AntigravityQuotaData quota})>
  _fetchQuotaOnce({
    required AntigravityTokenData token,
    String? previousTier,
  }) async {
    final ua = AntigravityOAuth.nativeUserAgent;

    // Step 1: Resolve project_id and subscription_tier via loadCodeAssist.
    final projectMeta = await _loadCodeAssist(
      accessToken: token.accessToken,
      userAgent: ua,
    );
    final projectId =
        (projectMeta.projectId != null && projectMeta.projectId!.isNotEmpty)
        ? projectMeta.projectId
        : token.projectId;
    final updatedToken = projectId != null && projectId != token.projectId
        ? token.copyWith(projectId: projectId)
        : token;
    final subscriptionTier = projectMeta.subscriptionTier ?? previousTier;

    // Step 2: Fetch per-model quotas via fetchAvailableModels.
    final modelsResult = await _fetchAvailableModels(
      accessToken: updatedToken.accessToken,
      projectId: projectId,
      userAgent: ua,
    );

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (modelsResult.isForbidden) {
      return (
        token: updatedToken,
        quota: AntigravityQuotaData(
          lastUpdated: nowSec,
          isForbidden: true,
          forbiddenReason: modelsResult.forbiddenReason,
          subscriptionTier: subscriptionTier,
        ),
      );
    }

    // Step 3: Fetch 5h & weekly grouped buckets via retrieveUserQuotaSummary.
    final groups = await _fetchQuotaSummaryGroups(
      accessToken: updatedToken.accessToken,
      projectId: projectId,
      userAgent: ua,
    );

    // Step 4: Fuse model quotas with group buckets (one-way tightening).
    final fusedModels = _fuseModelQuotas(modelsResult.models, groups);

    return (
      token: updatedToken,
      quota: AntigravityQuotaData(
        models: fusedModels,
        lastUpdated: nowSec,
        isForbidden: false,
        subscriptionTier: subscriptionTier,
        modelForwardingRules: modelsResult.forwardingRules,
        quotaGroups: groups,
      ),
    );
  }

  static Future<({String? projectId, String? subscriptionTier})> _loadCodeAssist({
    required String accessToken,
    required String userAgent,
  }) async {
    for (final endpoint in _loadCodeAssistEndpoints) {
      final resp = await _postJson(
        endpoint,
        accessToken: accessToken,
        userAgent: userAgent,
        body: const {
          'metadata': {'ideType': 'ANTIGRAVITY'},
        },
      );
      if (resp.statusCode == HttpStatus.unauthorized) {
        throw const _UnauthorizedQuotaException();
      }
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final json = _decodeMap(resp.body);
        final rawProj = json['cloudaicompanionProject'];
        final proj = switch (rawProj) {
          final String s when s.trim().isNotEmpty => s.trim(),
          final Map m when m['id'] is String => (m['id'] as String).trim(),
          _ => null,
        };
        final tier = _extractSubscriptionTier(json);
        return (projectId: proj, subscriptionTier: tier);
      }
    }
    return (projectId: null, subscriptionTier: null);
  }

  static String? _extractSubscriptionTier(Map<String, Object?> json) {
    String? tierLabel(Object? raw) {
      if (raw is! Map) return null;
      final name = (raw['name'] as String?)?.trim() ?? '';
      if (name.isNotEmpty) return name;
      final id = (raw['id'] as String?)?.trim() ?? '';
      return id.isNotEmpty ? id : null;
    }

    final paid = tierLabel(json['paidTier']);
    if (paid != null) return paid;

    final ineligible = json['ineligibleTiers'];
    final isIneligible = ineligible is List && ineligible.isNotEmpty;

    String? defaultAllowed;
    if (json['allowedTiers'] case final List allowed) {
      for (final item in allowed) {
        if (item is Map && item['isDefault'] == true) {
          defaultAllowed = tierLabel(item);
          if (defaultAllowed != null) break;
        }
      }
    }

    final current = tierLabel(json['currentTier']);
    if (!isIneligible) {
      return current ?? defaultAllowed;
    }
    final base = defaultAllowed ?? current;
    return base == null ? null : '$base (Restricted)';
  }

  static Future<
    ({
      List<AntigravityModelQuota> models,
      Map<String, String> forwardingRules,
      bool isForbidden,
      String? forbiddenReason,
    })
  >
  _fetchAvailableModels({
    required String accessToken,
    required String? projectId,
    required String userAgent,
  }) async {
    var sawAllForbidden = true;
    String? lastForbiddenBody;

    for (final endpoint in _fetchModelsEndpoints) {
      final hasProject = projectId != null && projectId.isNotEmpty;
      var resp = await _postJson(
        endpoint,
        accessToken: accessToken,
        userAgent: userAgent,
        body: hasProject ? {'project': projectId} : const {},
      );
      if (resp.statusCode == HttpStatus.unauthorized) {
        throw const _UnauthorizedQuotaException();
      }
      if (resp.statusCode == HttpStatus.forbidden && hasProject) {
        resp = await _postJson(
          endpoint,
          accessToken: accessToken,
          userAgent: userAgent,
          body: const {},
        );
        if (resp.statusCode == HttpStatus.unauthorized) {
          throw const _UnauthorizedQuotaException();
        }
      }

      if (resp.statusCode == HttpStatus.forbidden) {
        lastForbiddenBody = resp.body;
        continue;
      }
      sawAllForbidden = false;

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final json = _decodeMap(resp.body);
        final modelsMap = (json['models'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
        final parsed = <AntigravityModelQuota>[];

        for (final MapEntry(key: modelName, value: rawInfo)
            in modelsMap.entries) {
          final lower = modelName.toLowerCase();
          if (!lower.startsWith('gemini') &&
              !lower.startsWith('claude') &&
              !lower.startsWith('gpt') &&
              !lower.startsWith('image') &&
              !lower.startsWith('imagen')) {
            continue;
          }
          if (rawInfo is! Map) continue;
          final info = rawInfo.cast<String, Object?>();
          final quotaInfo =
              (info['quotaInfo'] as Map?)?.cast<String, Object?>();
          final rawFrac = quotaInfo?['remainingFraction'];
          final known =
              rawFrac is num &&
              rawFrac.isFinite &&
              rawFrac >= 0.0 &&
              rawFrac <= 1.0;
          final frac = known ? rawFrac.toDouble() : null;
          final resetTime = '${quotaInfo?['resetTime'] ?? ''}';

          parsed.add(
            AntigravityModelQuota(
              name: modelName,
              percentage: frac != null ? (frac * 100).round() : 0,
              percentageKnown: known,
              observedRemainingFraction: frac,
              primaryRemainingFraction: frac,
              primaryResetTime: frac != null ? resetTime : null,
              resetTime: resetTime,
              displayName: info['displayName'] as String?,
              supportsImages: info['supportsImages'] as bool?,
              supportsThinking: info['supportsThinking'] as bool?,
              thinkingBudget: (info['thinkingBudget'] as num?)?.toInt(),
              recommended: info['recommended'] as bool?,
              maxTokens: (info['maxTokens'] as num?)?.toInt(),
              maxOutputTokens: (info['maxOutputTokens'] as num?)?.toInt(),
            ),
          );
        }

        final forwarding = <String, String>{};
        if (json['deprecatedModelIds'] case final Map dep) {
          for (final MapEntry(:key, :value) in dep.entries) {
            if (key is String &&
                value is Map &&
                value['newModelId'] is String) {
              forwarding[key] = value['newModelId'] as String;
            }
          }
        }

        return (
          models: parsed,
          forwardingRules: forwarding,
          isForbidden: false,
          forbiddenReason: null,
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 600));
    }

    if (sawAllForbidden) {
      return (
        models: const <AntigravityModelQuota>[],
        forwardingRules: const <String, String>{},
        isForbidden: true,
        forbiddenReason: lastForbiddenBody,
      );
    }

    throw Exception('无法拉取模型配额列表（所有 Cloud Code 端点均不可达）');
  }

  static Future<List<AntigravityQuotaGroup>?> _fetchQuotaSummaryGroups({
    required String accessToken,
    required String? projectId,
    required String userAgent,
  }) async {
    final defaultProject = (projectId != null && projectId.isNotEmpty)
        ? projectId
        : 'aicode-consumers';
    List<AntigravityQuotaGroup>? partialFallback;

    for (final endpoint in _quotaSummaryEndpoints) {
      final attempts = <({String ua, Map<String, Object?> body})>[
        (ua: userAgent, body: {'project': defaultProject}),
        (ua: 'antigravity', body: {'project': defaultProject}),
        (ua: userAgent, body: const {}),
      ];

      for (var i = 0; i < attempts.length; i++) {
        final attempt = attempts[i];
        final resp = await _postJson(
          endpoint,
          accessToken: accessToken,
          userAgent: attempt.ua,
          body: attempt.body,
        );
        if (resp.statusCode == HttpStatus.unauthorized) {
          throw const _UnauthorizedQuotaException();
        }
        if (resp.statusCode == HttpStatus.forbidden) {
          continue;
        }
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          final json = _decodeMap(resp.body);
          final rawGroups = json['groups'];
          if (rawGroups is! List || rawGroups.isEmpty) break;
          final groups = [
            for (final g in rawGroups)
              if (g is Map)
                AntigravityQuotaGroup.fromJson(g.cast<String, Object?>()),
          ];
          final hasGeminiPool = groups.any(
            (g) => g.buckets.any(
              (b) =>
                  AntigravityQuotaPool.classify(b.bucketId, g.displayName) ==
                  AntigravityQuotaPool.gemini,
            ),
          );
          if (hasGeminiPool) return groups;
          partialFallback ??= groups;
          if (i == 1) continue; // Try attempt 3 (`{}` with full hub UA).
          break;
        }
        break;
      }
    }
    return partialFallback;
  }

  static List<AntigravityModelQuota> _fuseModelQuotas(
    List<AntigravityModelQuota> models,
    List<AntigravityQuotaGroup>? groups,
  ) {
    if (groups == null || groups.isEmpty) return models;

    final strictestByPool = <AntigravityQuotaPool, AntigravityQuotaBucket>{};
    for (final group in groups) {
      for (final bucket in group.buckets) {
        if (!bucket.remainingFractionKnown) continue;
        final pool = AntigravityQuotaPool.classify(
          bucket.bucketId,
          group.displayName,
        );
        if (pool == null) continue;
        final prev = strictestByPool[pool];
        if (prev == null ||
            bucket.remainingFraction < prev.remainingFraction) {
          strictestByPool[pool] = bucket;
        }
      }
    }

    return [
      for (final m in models)
        if (m.name.endsWith('-disabled'))
          m
        else
          _fuseOneModel(m, strictestByPool),
    ];
  }

  static AntigravityModelQuota _fuseOneModel(
    AntigravityModelQuota model,
    Map<AntigravityQuotaPool, AntigravityQuotaBucket> strictestByPool,
  ) {
    final pool = AntigravityQuotaPool.ofModel(
      model.name,
      model.displayName ?? '',
    );
    final bucket = pool == null ? null : strictestByPool[pool];
    if (bucket == null) return model;

    final primary = model.primaryRemainingFraction;
    if (primary != null && primary < bucket.remainingFraction) {
      final clamped = math.min(primary, bucket.remainingFraction);
      return AntigravityModelQuota(
        name: model.name,
        percentage: (clamped * 100).round(),
        percentageKnown: true,
        observedRemainingFraction: clamped,
        primaryRemainingFraction: model.primaryRemainingFraction,
        primaryResetTime: model.primaryResetTime,
        quotaBucketId: bucket.bucketId,
        resetTime: model.primaryResetTime ?? model.resetTime,
        displayName: model.displayName,
        supportsImages: model.supportsImages,
        supportsThinking: model.supportsThinking,
        thinkingBudget: model.thinkingBudget,
        recommended: model.recommended,
        maxTokens: model.maxTokens,
        maxOutputTokens: model.maxOutputTokens,
      );
    }

    return AntigravityModelQuota(
      name: model.name,
      percentage: bucket.percentage,
      percentageKnown: true,
      observedRemainingFraction: bucket.remainingFraction,
      primaryRemainingFraction: model.primaryRemainingFraction,
      primaryResetTime: model.primaryResetTime,
      quotaBucketId: bucket.bucketId,
      resetTime: bucket.resetTime.isNotEmpty
          ? bucket.resetTime
          : model.resetTime,
      displayName: model.displayName,
      supportsImages: model.supportsImages,
      supportsThinking: model.supportsThinking,
      thinkingBudget: model.thinkingBudget,
      recommended: model.recommended,
      maxTokens: model.maxTokens,
      maxOutputTokens: model.maxOutputTokens,
    );
  }

  static Future<({int statusCode, String body})> _postJson(
    String url, {
    required String accessToken,
    required String userAgent,
    required Map<String, Object?> body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client.postUrl(Uri.parse(url));
      final bytes = utf8.encode(jsonEncode(body));
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $accessToken')
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.userAgentHeader, userAgent)
        ..contentLength = bytes.length;
      req.add(bytes);
      final resp = await req.close().timeout(const Duration(seconds: 18));
      final respBody = await utf8.decodeStream(resp);
      return (statusCode: resp.statusCode, body: respBody);
    } on Object {
      return (statusCode: 599, body: '');
    } finally {
      client.close(force: true);
    }
  }

  static Map<String, Object?> _decodeMap(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on Object {
      // Ignore invalid JSON.
    }
    return const {};
  }
}

class _UnauthorizedQuotaException implements Exception {
  const _UnauthorizedQuotaException();
}
