import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../claude_code/claude_environment.dart';
import 'codebuddy_account_models.dart';
import 'codebuddy_cli.dart';
import 'codebuddy_oauth.dart';
import 'codebuddy_quota.dart';

/// Manages CodeBuddy accounts (CN / Global / iOA / Enterprise / API Key),
/// OAuth sign-ins, automatic token refresh, live quota & credit tracking, and
/// 1-click / smart auto-switching inside Cyte.
///
/// Storage root: `~/.cyte/codebuddy_accounts/`.
class CodeBuddyAccounts extends ChangeNotifier {
  CodeBuddyAccounts({String? dataDir}) : _overrideDir = dataDir;

  static final CodeBuddyAccounts instance = CodeBuddyAccounts();

  /// Hook notified whenever the active CodeBuddy account switches so idle or
  /// next-turn `CodeBuddyTransport` processes respawn cleanly with the new
  /// account credentials and regional endpoint.
  static FutureOr<void> Function(CodeBuddyAccount? switched)?
  onActiveAccountSwitched;

  final String? _overrideDir;
  String? _resolvedDataDir;
  String? _loadedDir;
  String? _latestTargetDir;
  int _loadEpoch = 0;
  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _initFuture;
  Zone? _initZone;
  Timer? _refreshTimer;
  Timer? _postTurnRefreshTimer;

  final List<CodeBuddyAccount> _accounts = [];
  String? _currentAccountId;
  CodeBuddyAutoSwitchConfig _autoSwitch = const CodeBuddyAutoSwitchConfig();

  final Set<String> _refreshingIds = {};
  bool _refreshingAll = false;
  String? _switchingId;
  String? _lastRefreshError;
  int _backgroundTick = 0;

  List<CodeBuddyAccount> get accounts => List.unmodifiable(_accounts);
  String? get currentAccountId => _currentAccountId;
  CodeBuddyAutoSwitchConfig get autoSwitch => _autoSwitch;
  bool get isRefreshingAll => _refreshingAll;
  String? get switchingId => _switchingId;
  String? get lastRefreshError => _lastRefreshError;
  bool isRefreshing(String id) => _refreshingIds.contains(id);

  CodeBuddyAccount? get currentAccount {
    final id = _currentAccountId;
    if (id != null) {
      for (final a in _accounts) {
        if (a.id == id) return a;
      }
    }
    return _accounts.firstOrNull;
  }

  String get dataDirectoryPath {
    if (_overrideDir case final dir? when dir.isNotEmpty) return dir;
    if (_resolvedDataDir case final dir? when dir.isNotEmpty) return dir;
    final home = _resolveHome(
      Platform.environment,
      fallbackToPlatform: false,
    );
    return p.join(home, '.cyte', 'codebuddy_accounts');
  }

  static String? _nonEmptyEnv(String? value) =>
      (value != null && value.trim().isNotEmpty) ? value.trim() : null;

  static String? _lookupEnvVar(
    Map<String, String> env,
    String name, {
    required bool win,
  }) {
    final direct = _nonEmptyEnv(env[name]);
    if (direct != null) return direct;
    if (env.containsKey(name)) {
      return '';
    }
    final lower = name.toLowerCase();
    for (final entry in env.entries) {
      if (entry.key.toLowerCase() == lower) {
        final value = _nonEmptyEnv(entry.value);
        if (value != null) return value;
      }
    }
    for (final entry in env.entries) {
      if (entry.key.toLowerCase() == lower) {
        return '';
      }
    }
    return null;
  }

  static String _resolveHome(
    Map<String, String> env, {
    bool fallbackToPlatform = true,
  }) {
    final win = Platform.isWindows;
    final envHome = _lookupEnvVar(env, 'HOME', win: win);
    if (envHome != null && envHome.isNotEmpty) return envHome;
    final envUserProfile = _lookupEnvVar(env, 'USERPROFILE', win: win);
    if (envUserProfile != null && envUserProfile.isNotEmpty) {
      return envUserProfile;
    }
    if (!fallbackToPlatform || envHome != null || envUserProfile != null) {
      return '';
    }
    final platHome = _lookupEnvVar(Platform.environment, 'HOME', win: win);
    if (platHome != null && platHome.isNotEmpty) return platHome;
    final platProfile = _lookupEnvVar(
      Platform.environment,
      'USERPROFILE',
      win: win,
    );
    if (platProfile != null && platProfile.isNotEmpty) return platProfile;
    return '';
  }

  Future<String> _resolveDataDirectoryPath() async {
    if (_overrideDir case final dir? when dir.isNotEmpty) return dir;
    final env = await ClaudeEnvironment.of();
    final home = _resolveHome(env);
    final resolved = p.join(home, '.cyte', 'codebuddy_accounts');
    _resolvedDataDir = resolved;
    return resolved;
  }

  Future<void> ensureInitialized() {
    if (_disposed) return Future.value();
    if (_initFuture case final inFlight?
        when identical(_initZone, Zone.current)) {
      return inFlight;
    }
    if (_initialized && _overrideDir != null) return Future.value();
    final run = _ensureInitializedAsync();
    _initFuture = run;
    _initZone = Zone.current;
    return run.whenComplete(() {
      if (identical(_initFuture, run)) {
        _initFuture = null;
        _initZone = null;
      }
    });
  }

  Future<void> _ensureInitializedAsync() async {
    if (_disposed) return;
    final targetDir = await _resolveDataDirectoryPath();
    if (_disposed) return;
    if (_initialized && _loadedDir == targetDir) return;
    await _doInitialize(targetDir);
  }

  Future<void> _doInitialize(String targetDir) async {
    if (_disposed) return;
    _latestTargetDir = targetDir;
    final epoch = ++_loadEpoch;
    final dir = Directory(targetDir);
    await dir.create(recursive: true);
    if (_disposed) return;
    if (_initialized && _loadedDir == targetDir && epoch != _loadEpoch) return;
    if (_latestTargetDir != targetDir && epoch != _loadEpoch) return;
    final committed = await _loadFromDisk(dir, expectedEpoch: epoch);
    if (_disposed || !committed) return;
    _syncActiveRegionModels();
    _startBackgroundRefreshTimer();
    if (_accounts.isNotEmpty &&
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      unawaited(refreshAllQuotas(silent: true));
    }
    _safeNotify();
  }

  Future<bool> _loadFromDisk(Directory dir, {int? expectedEpoch}) async {
    final epoch = expectedEpoch ?? ++_loadEpoch;
    final accountsDir = Directory(p.join(dir.path, 'accounts'));
    final byId = <String, CodeBuddyAccount>{};

    if (accountsDir.existsSync()) {
      for (final entity in accountsDir.listSync()) {
        if (_disposed) return false;
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final raw = _stripBom(await entity.readAsString());
          if (_disposed) return false;
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            final acc = CodeBuddyAccount.fromJson(
              decoded.cast<String, Object?>(),
            );
            if (acc.id.isNotEmpty) {
              byId[acc.id] = acc;
            }
          }
        } on Object {
          // Skip unreadable file.
        }
      }
    }

    final indexFile = File(p.join(dir.path, 'accounts.json'));
    final orderedIds = <String>[];
    String? loadedCurrentId;
    if (indexFile.existsSync()) {
      try {
        final decoded = jsonDecode(_stripBom(await indexFile.readAsString()));
        if (_disposed) return false;
        if (decoded is Map) {
          loadedCurrentId = decoded['current_account_id'] as String?;
          if (decoded['accounts'] case final List list) {
            for (final item in list) {
              if (item is Map && item['id'] is String) {
                orderedIds.add(item['id'] as String);
              }
            }
          }
        }
      } on Object {
        // Self-heal below.
      }
    }

    final loadedAccounts = <CodeBuddyAccount>[];
    final seenIds = <String>{};
    for (final id in orderedIds) {
      if (!seenIds.add(id)) continue;
      if (byId.remove(id) case final acc?) {
        loadedAccounts.add(acc);
      }
    }
    final remaining = byId.values.toList()
      ..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    for (final acc in remaining) {
      if (seenIds.add(acc.id)) {
        loadedAccounts.add(acc);
      }
    }

    final resolvedCurrentId = (loadedCurrentId != null &&
            loadedAccounts.any((a) => a.id == loadedCurrentId))
        ? loadedCurrentId
        : loadedAccounts.firstOrNull?.id;

    CodeBuddyAutoSwitchConfig? loadedAutoSwitch;
    final autoFile = File(p.join(dir.path, 'auto_switch.json'));
    if (autoFile.existsSync()) {
      try {
        final decoded = jsonDecode(_stripBom(await autoFile.readAsString()));
        if (_disposed) return false;
        if (decoded is Map) {
          loadedAutoSwitch = CodeBuddyAutoSwitchConfig.fromJson(
            decoded.cast<String, Object?>(),
          );
        }
      } on Object {
        // Keep defaults.
      }
    }

    if (_disposed) return false;
    final isLatest = epoch == _loadEpoch;
    final needsFirstCommitForDir =
        _latestTargetDir == dir.path && (!_initialized || _loadedDir != dir.path);
    if (!isLatest && !needsFirstCommitForDir) {
      return false;
    }

    _accounts
      ..clear()
      ..addAll(loadedAccounts);
    _currentAccountId = resolvedCurrentId;
    if (loadedAutoSwitch != null) {
      _autoSwitch = loadedAutoSwitch;
    }
    _loadedDir = dir.path;
    _initialized = true;

    if (remaining.isNotEmpty || !indexFile.existsSync()) {
      if (_disposed) return true;
      await _saveIndex(dirPath: dir.path);
    }
    return true;
  }

  void _syncActiveRegionModels() {
    final active = currentAccount;
    if (active != null) {
      CodeBuddyModels.syncForAccount(active);
    }
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void _startBackgroundRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (_disposed || _accounts.isEmpty) return;
    if (_overrideDir == null &&
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (_disposed) return;
      _backgroundTick++;
      if (_backgroundTick % 3 == 0) {
        unawaited(refreshAllQuotas(silent: true));
      } else if (currentAccount case final active?) {
        unawaited(refreshQuota(active.id));
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _postTurnRefreshTimer?.cancel();
    _postTurnRefreshTimer = null;
    super.dispose();
  }

  Future<void> _saveAccount(CodeBuddyAccount account) async {
    if (_disposed) return;
    final filePath = p.join(
      dataDirectoryPath,
      'accounts',
      '${account.id}.json',
    );
    const encoder = JsonEncoder.withIndent('  ');
    await CodeBuddyOAuth.writeAtomicSecure(
      filePath,
      encoder.convert(account.toJson()),
    );
  }

  Future<void> _saveIndex({String? dirPath}) async {
    if (_disposed) return;
    final indexPath = p.join(dirPath ?? dataDirectoryPath, 'accounts.json');
    const encoder = JsonEncoder.withIndent('  ');
    await CodeBuddyOAuth.writeAtomicSecure(
      indexPath,
      encoder.convert({
        'current_account_id': _currentAccountId,
        'accounts': [
          for (final a in _accounts)
            {
              'id': a.id,
              'uid': a.uid,
              'nickname': a.nickname,
              'region': a.region.name,
            },
        ],
      }),
    );
  }

  /// Inserts or updates [account] and optionally makes it active.
  Future<CodeBuddyAccount> upsertAccount(
    CodeBuddyAccount account, {
    bool makeActive = true,
  }) async {
    if (_disposed) return account;
    await ensureInitialized();
    if (_disposed) return account;
    _loadEpoch++;
    final idx = _accounts.indexWhere((a) => a.id == account.id);
    final merged = idx >= 0
        ? account.copyWith(
            customLabel: account.customLabel ?? _accounts[idx].customLabel,
            quota: account.quota ?? _accounts[idx].quota,
          )
        : account;
    if (idx >= 0) {
      _accounts[idx] = merged;
    } else {
      _accounts.insert(0, merged);
    }
    await _saveAccount(merged);
    if (_disposed) return merged;
    if (makeActive || _currentAccountId == null) {
      _currentAccountId = merged.id;
      _syncActiveRegionModels();
      await _saveIndex();
      if (_disposed) return merged;
      _safeNotify();
      await onActiveAccountSwitched?.call(merged);
    } else {
      await _saveIndex();
      if (_disposed) return merged;
      _safeNotify();
    }
    if (_disposed) return merged;
    if (_refreshTimer == null) {
      _startBackgroundRefreshTimer();
    }
    unawaited(refreshQuota(merged.id));
    return merged;
  }

  /// Adds an API Key account (`CODEBUDDY_API_KEY` + region / custom baseUrl).
  Future<CodeBuddyAccount> addApiKeyAccount({
    required String apiKey,
    required CodeBuddyRegion region,
    String? nickname,
    String? baseUrl,
    String? endpoint,
  }) async {
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isEmpty) {
      throw Exception('API Key 不能为空');
    }
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tail = trimmedKey.length > 6
        ? trimmedKey.substring(trimmedKey.length - 6)
        : trimmedKey;
    final uid = 'apikey_${trimmedKey.hashCode.abs()}_$tail';
    final account = CodeBuddyAccount(
      id: CodeBuddyOAuth.buildAccountId(region: region, uid: uid),
      uid: uid,
      nickname: (nickname != null && nickname.trim().isNotEmpty)
          ? nickname.trim()
          : 'API Key (…$tail)',
      region: region,
      endpoint: CodeBuddyOAuth.normalizeEndpoint(
        endpoint ?? region.defaultEndpoint,
      ),
      auth: CodeBuddyAuthData(
        kind: CodeBuddyAuthKind.apiKey,
        apiKey: trimmedKey,
        baseUrl: baseUrl?.trim().isEmpty == true ? null : baseUrl?.trim(),
      ),
      quota: CodeBuddyQuotaData(
        edition: CodeBuddyEdition.apiKey,
        lastUpdated: nowSec,
      ),
      createdAt: nowSec,
      lastUsed: nowSec,
    );
    return upsertAccount(account, makeActive: true);
  }

  /// Adds an account directly from a Bearer Access Token (+ optional Refresh Token).
  Future<CodeBuddyAccount> addTokenAccount({
    required String accessToken,
    String? refreshToken,
    required CodeBuddyRegion region,
    String? endpoint,
    String? nickname,
  }) async {
    final trimmedAccess = accessToken.trim();
    final trimmedRefresh = refreshToken?.trim() ?? '';
    if (trimmedAccess.isEmpty && trimmedRefresh.isEmpty) {
      throw Exception('Access Token 或 Refresh Token 至少填写一项');
    }
    final normalizedEndpoint = CodeBuddyOAuth.normalizeEndpoint(
      endpoint ?? region.defaultEndpoint,
    );
    var auth = CodeBuddyAuthData(
      kind: trimmedRefresh.isNotEmpty
          ? CodeBuddyAuthKind.oauth
          : CodeBuddyAuthKind.authToken,
      accessToken: trimmedAccess,
      refreshToken: trimmedRefresh,
    );
    if (auth.accessToken.isEmpty && auth.refreshToken.isNotEmpty) {
      auth = await CodeBuddyOAuth.refreshAuthToken(
        auth: auth,
        endpoint: normalizedEndpoint,
      );
    }
    final account = await CodeBuddyOAuth.fetchAccountWithAuth(
      auth: auth,
      region: region,
      endpoint: normalizedEndpoint,
      fallbackNickname: nickname,
    );
    return upsertAccount(account, makeActive: true);
  }

  /// Ensures [account] has a fresh non-expired `accessToken` before spawning `codebuddy`.
  Future<CodeBuddyAccount> ensureFreshAccount(CodeBuddyAccount account) async {
    if (_disposed ||
        !account.auth.needsRefresh ||
        account.auth.refreshToken.isEmpty) {
      return account;
    }
    try {
      final refreshedAuth = await CodeBuddyOAuth.refreshAuthToken(
        auth: account.auth,
        endpoint: account.endpoint,
      );
      if (_disposed) return account;
      final updated = account.copyWith(auth: refreshedAuth, clearDisabled: true);
      final idx = _accounts.indexWhere((a) => a.id == account.id);
      if (idx >= 0) {
        _loadEpoch++;
        _accounts[idx] = updated;
        await _saveAccount(updated);
        if (_disposed) return updated;
        _safeNotify();
      }
      return updated;
    } on Object {
      return account;
    }
  }

  /// Switches the active CodeBuddy account to [accountId].
  Future<void> switchAccount(String accountId) async {
    if (_disposed) return;
    await ensureInitialized();
    if (_disposed) return;
    final targetIdx = _accounts.indexWhere((a) => a.id == accountId);
    if (targetIdx < 0) return;

    _switchingId = accountId;
    _safeNotify();
    try {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      var target = _accounts[targetIdx].copyWith(lastUsed: nowSec);
      target = await ensureFreshAccount(target);
      if (_disposed) return;
      final currentIdx = _accounts.indexWhere((a) => a.id == accountId);
      if (currentIdx < 0) return;
      _loadEpoch++;
      _accounts[currentIdx] = target;
      _currentAccountId = accountId;
      _syncActiveRegionModels();
      await _saveAccount(target);
      if (_disposed) return;
      await _saveIndex();
      if (_disposed) return;
      _safeNotify();
      await onActiveAccountSwitched?.call(target);
    } finally {
      _switchingId = null;
      _safeNotify();
    }
  }

  /// Clears active managed account selection? Deleting the active account
  /// switches to the next available account (or falls back to CLI default).
  Future<void> deleteAccount(String accountId) async {
    if (_disposed) return;
    await ensureInitialized();
    if (_disposed) return;
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx < 0) return;
    _loadEpoch++;
    _accounts.removeAt(idx);
    final file = File(p.join(dataDirectoryPath, 'accounts', '$accountId.json'));
    if (file.existsSync()) {
      await file.delete();
      if (_disposed) return;
    }
    final wasActive = _currentAccountId == accountId;
    if (wasActive) {
      _currentAccountId = _accounts.firstOrNull?.id;
      _syncActiveRegionModels();
    }
    if (_accounts.isEmpty) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
    await _saveIndex();
    if (_disposed) return;
    _safeNotify();
    if (wasActive) {
      await onActiveAccountSwitched?.call(currentAccount);
    }
  }

  Future<void> setCustomLabel(String accountId, String label) async {
    if (_disposed) return;
    await ensureInitialized();
    if (_disposed) return;
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx < 0) return;
    _loadEpoch++;
    final trimmed = label.trim();
    final updated = trimmed.isEmpty
        ? _accounts[idx].copyWith(clearCustomLabel: true)
        : _accounts[idx].copyWith(customLabel: trimmed);
    _accounts[idx] = updated;
    await _saveAccount(updated);
    if (_disposed) return;
    _safeNotify();
  }

  Future<void> setAutoSwitch(CodeBuddyAutoSwitchConfig config) async {
    if (_disposed) return;
    await ensureInitialized();
    if (_disposed) return;
    _loadEpoch++;
    _autoSwitch = config;
    const encoder = JsonEncoder.withIndent('  ');
    await CodeBuddyOAuth.writeAtomicSecure(
      p.join(dataDirectoryPath, 'auto_switch.json'),
      encoder.convert(config.toJson()),
    );
    _safeNotify();
  }

  /// Records live credit & token usage reported by `codebuddy` stream-json
  /// (`codebuddy.ai/turnUsage`), updates remaining credits immediately,
  /// schedules a background server balance sync, and triggers smart auto-switch
  /// if quota is exhausted (`429` / `insufficient_quota` / `6005` / `14018`).
  Future<void> recordTurnUsage({
    double credits = 0.0,
    int tokens = 0,
    bool quotaExhausted = false,
  }) async {
    if (_disposed) return;
    final active = currentAccount;
    if (active == null) return;
    final idx = _accounts.indexWhere((a) => a.id == active.id);
    if (idx < 0) return;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final prev = active.quota ?? CodeBuddyQuotaData(lastUpdated: nowSec);
    final delta = credits > 0 ? credits : 0.0;
    final nextRemain = prev.remainingCredits != null && delta > 0
        ? (prev.remainingCredits! - delta).clamp(0.0, double.infinity)
        : prev.remainingCredits;
    final nextQuota = prev.copyWith(
      sessionCreditsUsed: prev.sessionCreditsUsed + delta,
      remainingCredits: nextRemain,
      usedCredits: prev.usedCredits != null && delta > 0
          ? prev.usedCredits! + delta
          : prev.usedCredits,
      turnCount: prev.turnCount + 1,
      totalTokensUsed: prev.totalTokensUsed + (tokens > 0 ? tokens : 0),
      quotaExhausted: quotaExhausted ? true : prev.quotaExhausted,
      lastUpdated: nowSec,
    );
    final updated = active.copyWith(quota: nextQuota, lastUsed: nowSec);
    _loadEpoch++;
    _accounts[idx] = updated;
    await _saveAccount(updated);
    if (_disposed) return;
    _safeNotify();

    if (quotaExhausted && _autoSwitch.enabled) {
      await _tryAutoSwitchFrom(updated);
      return;
    }
    if (_disposed) return;

    // Sync authoritative server credit balance after turn settles.
    if (updated.auth.kind != CodeBuddyAuthKind.apiKey &&
        updated.auth.accessToken.isNotEmpty) {
      _postTurnRefreshTimer?.cancel();
      final targetId = updated.id;
      _postTurnRefreshTimer = Timer(const Duration(milliseconds: 2200), () {
        if (_disposed) return;
        unawaited(refreshQuota(targetId));
      });
    }
  }

  /// Auto-imports the CLI's own logged-in account when Cyte has no managed
  /// accounts yet, so users who ran `codebuddy login` in terminal immediately
  /// see their remaining credits without signing in twice.
  Future<void> syncFromCliInitializeAccount(
    Map<String, Object?> rawAccount,
  ) async {
    if (_disposed) return;
    await ensureInitialized();
    if (_disposed || _accounts.isNotEmpty) return;
    _loadEpoch++;
    final uid =
        (rawAccount['uid'] ?? rawAccount['userId'] ?? rawAccount['id'])
            as String? ??
        '';
    final token =
        (rawAccount['accessToken'] ??
                rawAccount['access_token'] ??
                rawAccount['token'])
            as String? ??
        '';
    if (uid.isEmpty || token.isEmpty) return;
    final domain =
        (rawAccount['domain'] ?? rawAccount['endpoint']) as String? ?? '';
    final region = CodeBuddyRegion.fromDomain(domain);
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final account = CodeBuddyAccount(
      id: CodeBuddyOAuth.buildAccountId(region: region, uid: uid),
      uid: uid,
      nickname:
          (rawAccount['nickname'] ?? rawAccount['userName']) as String? ?? uid,
      email: rawAccount['email'] as String?,
      enterpriseId: rawAccount['enterpriseId'] as String?,
      enterpriseName: rawAccount['enterpriseName'] as String?,
      region: region,
      endpoint: CodeBuddyOAuth.normalizeEndpoint(
        domain.startsWith('http') ? domain : region.defaultEndpoint,
      ),
      auth: CodeBuddyAuthData(
        kind: CodeBuddyAuthKind.authToken,
        accessToken: token,
        refreshToken:
            (rawAccount['refreshToken'] ?? rawAccount['refresh_token'])
                as String? ??
            '',
        domain: domain.isNotEmpty ? domain : null,
      ),
      createdAt: nowSec,
      lastUsed: nowSec,
    );
    _accounts.add(account);
    _currentAccountId = account.id;
    await _saveAccount(account);
    if (_disposed) return;
    await _saveIndex();
    if (_disposed) return;
    _startBackgroundRefreshTimer();
    _safeNotify();
    if (_disposed) return;
    unawaited(refreshQuota(account.id));
  }

  Future<void> _tryAutoSwitchFrom(CodeBuddyAccount exhausted) async {
    final candidates = _accounts.where(
      (a) =>
          a.id != exhausted.id &&
          !a.disabled &&
          (a.quota?.quotaExhausted != true),
    );
    if (candidates.isEmpty) return;
    CodeBuddyAccount? pick;
    if (_autoSwitch.preferSameRegion) {
      for (final c in candidates) {
        if (c.region == exhausted.region) {
          pick = c;
          break;
        }
      }
    }
    pick ??= candidates.first;
    await switchAccount(pick.id);
  }

  Future<void> refreshQuota(String accountId) async {
    if (_disposed) return;
    await ensureInitialized();
    if (_disposed) return;
    if (_refreshingIds.contains(accountId)) return;
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx < 0) return;

    _refreshingIds.add(accountId);
    _lastRefreshError = null;
    _safeNotify();
    try {
      final (:updatedAccount, :quota) = await CodeBuddyQuotaService.fetchQuota(
        _accounts[idx],
      );
      if (_disposed) return;
      final newIdx = _accounts.indexWhere((a) => a.id == accountId);
      if (newIdx >= 0) {
        final latest = _accounts[newIdx];
        final latestQuota = latest.quota;
        final mergedQuota = quota.copyWith(
          totalCredits: quota.totalCredits ?? latestQuota?.totalCredits,
          remainingCredits:
              quota.remainingCredits ?? latestQuota?.remainingCredits,
          usedCredits: quota.usedCredits ?? latestQuota?.usedCredits,
          sessionCreditsUsed:
              latestQuota != null &&
                  latestQuota.sessionCreditsUsed > quota.sessionCreditsUsed
              ? latestQuota.sessionCreditsUsed
              : quota.sessionCreditsUsed,
          turnCount:
              latestQuota != null && latestQuota.turnCount > quota.turnCount
              ? latestQuota.turnCount
              : quota.turnCount,
          totalTokensUsed:
              latestQuota != null &&
                  latestQuota.totalTokensUsed > quota.totalTokensUsed
              ? latestQuota.totalTokensUsed
              : quota.totalTokensUsed,
        );
        final mergedAccount = updatedAccount.copyWith(
          customLabel: latest.customLabel,
          quota: mergedQuota,
        );
        _loadEpoch++;
        _accounts[newIdx] = mergedAccount;
        await _saveAccount(mergedAccount);
        if (_disposed) return;
        if (_currentAccountId == accountId &&
            mergedQuota.availableModelIds.isNotEmpty) {
          CodeBuddyModels.syncForAccount(mergedAccount);
        }
      }
    } on CodeBuddyUnauthorizedException catch (e) {
      if (_disposed) return;
      final newIdx = _accounts.indexWhere((a) => a.id == accountId);
      if (newIdx >= 0) {
        final marked = _accounts[newIdx].copyWith(
          disabled: true,
          disabledReason: e.message,
        );
        _accounts[newIdx] = marked;
        await _saveAccount(marked);
        if (_disposed) return;
      }
      _lastRefreshError = e.message;
    } on Object catch (e) {
      if (_disposed) return;
      _lastRefreshError = '$e';
    } finally {
      _refreshingIds.remove(accountId);
      _safeNotify();
    }
  }

  Future<void> refreshAllQuotas({bool silent = false}) async {
    if (_disposed) return;
    await ensureInitialized();
    if (_disposed) return;
    if (_refreshingAll || _accounts.isEmpty) return;
    _refreshingAll = true;
    if (!silent) _lastRefreshError = null;
    _safeNotify();
    try {
      for (final acc in [..._accounts]) {
        if (_disposed) return;
        await refreshQuota(acc.id);
      }
    } finally {
      _refreshingAll = false;
      _safeNotify();
    }
  }

  String exportAccountsJson() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert({
      'version': 1,
      'current_account_id': _currentAccountId,
      'accounts': [for (final a in _accounts) a.toJson()],
    });
  }

  Future<int> importAccountsJson(String rawJson) async {
    if (_disposed) return 0;
    await ensureInitialized();
    if (_disposed) return 0;
    final decoded = jsonDecode(_stripBom(rawJson));
    final items = <Map<String, Object?>>[];
    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map) items.add(item.cast<String, Object?>());
      }
    } else if (decoded is Map) {
      if (decoded['accounts'] case final List list) {
        for (final item in list) {
          if (item is Map) items.add(item.cast<String, Object?>());
        }
      } else if (decoded['id'] is String || decoded['auth'] is Map) {
        items.add(decoded.cast<String, Object?>());
      }
    }
    var count = 0;
    for (final map in items) {
      if (_disposed) break;
      final acc = CodeBuddyAccount.fromJson(map);
      if (acc.id.isEmpty) continue;
      await upsertAccount(acc, makeActive: count == 0 && _accounts.isEmpty);
      if (_disposed) break;
      count++;
    }
    return count;
  }

  static String _stripBom(String s) =>
      s.startsWith('\uFEFF') ? s.substring(1) : s;
}
