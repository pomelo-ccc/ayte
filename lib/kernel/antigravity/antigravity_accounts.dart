import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'antigravity_account_models.dart';
import 'antigravity_oauth.dart';
import 'antigravity_quota.dart';
import 'antigravity_switcher.dart';

/// Manages Antigravity Google accounts, quotas, OAuth2 sign-ins, local
/// migration, and 1-click / smart auto-switching inside Ayte.
///
/// Storage root: `~/.ayte/antigravity_accounts/` (isolated from legacy external
/// switchers; automatically migrates `~/.antigravity_tools/` on first launch).
class AntigravityAccounts extends ChangeNotifier {
  AntigravityAccounts({String? dataDir}) : _overrideDir = dataDir;

  static final AntigravityAccounts instance = AntigravityAccounts();

  /// Hook notified whenever the active Google account switches so running
  /// `AntigravityTransport` processes recycle cleanly on the next turn.
  static FutureOr<void> Function(AntigravityAccount switched)?
  onActiveAccountSwitched;

  final String? _overrideDir;
  bool _initialized = false;
  Future<void>? _initFuture;
  Timer? _refreshTimer;
  Timer? _postTurnRefreshDebounce;

  final List<AntigravityAccount> _accounts = [];
  String? _currentAccountId;
  AntigravityAutoSwitchConfig _autoSwitch = const AntigravityAutoSwitchConfig();
  AntigravityQuotaWindow _quotaWindow = AntigravityQuotaWindow.fiveHour;

  final Set<String> _refreshingIds = {};
  bool _refreshingAll = false;
  String? _switchingId;

  List<AntigravityAccount> get accounts => List.unmodifiable(_accounts);
  String? get currentAccountId => _currentAccountId;
  AntigravityAutoSwitchConfig get autoSwitch => _autoSwitch;
  AntigravityQuotaWindow get quotaWindow => _quotaWindow;
  bool get isRefreshingAll => _refreshingAll;
  String? get switchingId => _switchingId;
  bool isRefreshing(String id) => _refreshingIds.contains(id);

  AntigravityAccount? get currentAccount {
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
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    return p.join(home, '.ayte', 'antigravity_accounts');
  }

  void setQuotaWindow(AntigravityQuotaWindow window) {
    if (_quotaWindow == window) return;
    _quotaWindow = window;
    notifyListeners();
  }

  /// Loads accounts from `~/.ayte/antigravity_accounts/`, migrating legacy
  /// `~/.antigravity_tools/` data losslessly if Ayte's store is empty.
  Future<void> ensureInitialized() {
    if (_initialized) return Future.value();
    return _initFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    try {
      final dir = Directory(dataDirectoryPath);
      await dir.create(recursive: true);
      final accountsSubdir = Directory(p.join(dir.path, 'accounts'));
      if (!accountsSubdir.existsSync() ||
          accountsSubdir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .isEmpty) {
        await _migrateFromLegacyToolsIfPresent(dir);
      }
      await _loadFromDisk(dir);
      await _reconcileActiveWithKeyring();
      _startBackgroundRefreshTimer();
      unawaited(refreshAllQuotas(silent: true));
    } finally {
      _initialized = true;
    }
    notifyListeners();
  }

  /// Losslessly copies accounts, index, quota history, and usage spans from
  /// `~/.antigravity_tools` into `~/.ayte/antigravity_accounts`.
  Future<int> migrateFromLegacyDirectory(Directory legacyDir) async {
    if (!legacyDir.existsSync()) return 0;
    final targetDir = Directory(dataDirectoryPath);
    await targetDir.create(recursive: true);
    final count = await _copyLegacyFiles(legacyDir, targetDir);
    if (count > 0) {
      await _loadFromDisk(targetDir);
      notifyListeners();
    }
    return count;
  }

  Future<void> _migrateFromLegacyToolsIfPresent(Directory targetDir) async {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return;
    final legacyDir = Directory(p.join(home, '.antigravity_tools'));
    if (!legacyDir.existsSync()) return;
    await _copyLegacyFiles(legacyDir, targetDir);
  }

  Future<int> _copyLegacyFiles(Directory srcDir, Directory dstDir) async {
    var copiedAccounts = 0;
    final dstAccountsDir = Directory(p.join(dstDir.path, 'accounts'));
    await dstAccountsDir.create(recursive: true);

    final srcAccountsDir = Directory(p.join(srcDir.path, 'accounts'));
    if (srcAccountsDir.existsSync()) {
      for (final entity in srcAccountsDir.listSync()) {
        if (entity is File && entity.path.endsWith('.json')) {
          final dstPath = p.join(dstAccountsDir.path, p.basename(entity.path));
          final content = await entity.readAsString();
          await AntigravityCredentialSwitcher.writeAtomicSecure(
            dstPath,
            content,
          );
          copiedAccounts++;
        }
      }
    }

    for (final filename in const [
      'accounts.json',
      'quota_cycle_history.json',
      'account_usage_spans.json',
      'auto_switch.json',
    ]) {
      final srcFile = File(p.join(srcDir.path, filename));
      if (srcFile.existsSync()) {
        final dstPath = p.join(dstDir.path, filename);
        if (!File(dstPath).existsSync()) {
          await AntigravityCredentialSwitcher.writeAtomicSecure(
            dstPath,
            await srcFile.readAsString(),
          );
        }
      }
    }
    return copiedAccounts;
  }

  Future<void> _loadFromDisk(Directory dir) async {
    _accounts.clear();
    final accountsDir = Directory(p.join(dir.path, 'accounts'));
    final byId = <String, AntigravityAccount>{};

    if (accountsDir.existsSync()) {
      for (final entity in accountsDir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final raw = _stripBom(await entity.readAsString());
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            final acc = AntigravityAccount.fromJson(
              decoded.cast<String, Object?>(),
            );
            if (acc.id.isNotEmpty && acc.email.isNotEmpty) {
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
    if (indexFile.existsSync()) {
      try {
        final raw = _stripBom(await indexFile.readAsString());
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _currentAccountId = decoded['current_account_id'] as String?;
          if (decoded['accounts'] case final List list) {
            for (final item in list) {
              if (item is Map && item['id'] is String) {
                orderedIds.add(item['id'] as String);
              }
            }
          }
        }
      } on Object {
        // Self-heal below from `accounts/*.json`.
      }
    }

    for (final id in orderedIds) {
      if (byId.remove(id) case final acc?) {
        _accounts.add(acc);
      }
    }
    final remaining = byId.values.toList()
      ..sort((a, b) {
        final cmp = b.lastUsed.compareTo(a.lastUsed);
        return cmp != 0 ? cmp : a.email.compareTo(b.email);
      });
    _accounts.addAll(remaining);

    if (_currentAccountId == null ||
        !_accounts.any((a) => a.id == _currentAccountId)) {
      _currentAccountId = _accounts.firstOrNull?.id;
    }

    final autoFile = File(p.join(dir.path, 'auto_switch.json'));
    if (autoFile.existsSync()) {
      try {
        final decoded = jsonDecode(_stripBom(await autoFile.readAsString()));
        if (decoded is Map) {
          _autoSwitch = AntigravityAutoSwitchConfig.fromJson(
            decoded.cast<String, Object?>(),
          );
        }
      } on Object {
        // Keep defaults.
      }
    }

    if (remaining.isNotEmpty || !indexFile.existsSync()) {
      await _saveIndex();
    }
  }

  /// Ensures `_currentAccountId` reflects the live Keychain/`agy` token if one
  /// of the managed accounts matches it.
  Future<void> _reconcileActiveWithKeyring() async {
    if (_accounts.isEmpty) return;
    final liveRt = await AntigravityCredentialSwitcher.readActiveRefreshToken();
    if (liveRt == null || liveRt.isEmpty) return;
    for (final acc in _accounts) {
      if (acc.token.refreshToken.trim() == liveRt) {
        if (_currentAccountId != acc.id) {
          _currentAccountId = acc.id;
          await _saveIndex();
        }
        return;
      }
    }
  }

  void _startBackgroundRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(refreshAllQuotas(silent: true));
    });
  }

  /// Schedules a debounced refresh of the active account's quota (e.g. right
  /// after an agent turn completes or when opening the Usage popover).
  void scheduleActiveQuotaRefresh({
    Duration delay = const Duration(seconds: 2),
  }) {
    _postTurnRefreshDebounce?.cancel();
    _postTurnRefreshDebounce = Timer(delay, () {
      final activeId = _currentAccountId ?? _accounts.firstOrNull?.id;
      if (activeId != null) {
        unawaited(refreshQuota(activeId));
      }
    });
  }

  Future<void> _saveAccount(AntigravityAccount account) async {
    final path = p.join(dataDirectoryPath, 'accounts', '${account.id}.json');
    final encoded = const JsonEncoder.withIndent('  ').convert(account.toJson());
    await AntigravityCredentialSwitcher.writeAtomicSecure(path, encoded);
  }

  Future<void> _saveIndex() async {
    final path = p.join(dataDirectoryPath, 'accounts.json');
    final payload = {
      'version': '2.0',
      'accounts': [for (final a in _accounts) a.toIndexSummaryJson()],
      'current_account_id': _currentAccountId,
      'current_target_ide': 'app',
      if (_currentAccountId != null)
        'current_ide_account_id': _currentAccountId,
    };
    final encoded = const JsonEncoder.withIndent('  ').convert(payload);
    await AntigravityCredentialSwitcher.writeAtomicSecure(path, encoded);
  }

  Future<void> _recordUsageSpan(String nextAccountId) async {
    final path = p.join(dataDirectoryPath, 'account_usage_spans.json');
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final cutoff = nowSec - 35 * 86400;
    final spans = <Map<String, Object?>>[];
    final file = File(path);
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(_stripBom(await file.readAsString()));
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final endTs = (item['end_ts'] as num?)?.toInt() ?? 0;
              if (endTs >= cutoff) {
                spans.add(Map<String, Object?>.from(item.cast<String, Object?>()));
              }
            }
          }
        }
      } on Object {
        // Ignore malformed span history.
      }
    }
    if (spans.isNotEmpty) {
      spans.last['end_ts'] = nowSec;
    }
    spans.add({
      'account_id': nextAccountId,
      'start_ts': nowSec,
      'end_ts': nowSec,
    });
    await AntigravityCredentialSwitcher.writeAtomicSecure(
      path,
      const JsonEncoder.withIndent('  ').convert(spans),
    );
  }

  /// Switches the active Antigravity account to [accountId], updating Keychain,
  /// `agy` CLI token, and notifying active Ayte sessions.
  Future<AntigravityAccount> switchAccount(String accountId) async {
    await ensureInitialized();
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx < 0) {
      throw Exception('未找到指定账号 ($accountId)');
    }
    _switchingId = accountId;
    notifyListeners();
    try {
      var acc = _accounts[idx];
      final freshToken = await AntigravityOAuth.ensureFreshToken(acc.token);
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      acc = acc.copyWith(
        token: freshToken,
        deviceProfile:
            acc.deviceProfile ?? AntigravityDeviceProfile.generate(),
        disabled: false,
        disabledReason: null,
        disabledAt: null,
        lastUsed: nowSec,
      );

      await AntigravityCredentialSwitcher.applyAccountCredentials(
        acc,
        syncExternalClients: _autoSwitch.syncExternalClients,
      );

      _accounts[idx] = acc;
      _currentAccountId = acc.id;
      await _saveAccount(acc);
      await _saveIndex();
      await _recordUsageSpan(acc.id);
      await onActiveAccountSwitched?.call(acc);

      // Refresh quota in the background right after switching if stale (>5 min).
      final lastQuota = acc.quota?.lastUpdated ?? 0;
      if (nowSec - lastQuota > 300) {
        unawaited(refreshQuota(acc.id));
      }
      return acc;
    } finally {
      _switchingId = null;
      notifyListeners();
    }
  }

  /// Refreshes quota & subscription tier for a single account.
  Future<AntigravityAccount?> refreshQuota(String accountId) async {
    await ensureInitialized();
    if (_refreshingIds.contains(accountId)) return null;
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx < 0) return null;

    _refreshingIds.add(accountId);
    notifyListeners();
    try {
      final updated = await AntigravityQuotaFetcher.refreshAccountQuota(
        _accounts[idx],
      );
      final currentIdx = _accounts.indexWhere((a) => a.id == accountId);
      if (currentIdx >= 0) {
        _accounts[currentIdx] = updated;
        await _saveAccount(updated);
        await _saveIndex();
      }
      return updated;
    } finally {
      _refreshingIds.remove(accountId);
      notifyListeners();
    }
  }

  /// Refreshes quotas for all non-disabled, non-forbidden accounts.
  Future<void> refreshAllQuotas({bool silent = false}) async {
    await ensureInitialized();
    if (_refreshingAll) return;
    _refreshingAll = true;
    if (!silent) notifyListeners();
    try {
      final targets = [
        for (final a in _accounts)
          if (!a.disabled && !(a.quota?.isForbidden ?? false)) a.id,
      ];
      for (final id in targets) {
        try {
          await refreshQuota(id);
        } on Object {
          // Continue refreshing remaining accounts.
        }
      }
    } finally {
      _refreshingAll = false;
      notifyListeners();
    }
  }

  /// Upserts an account by email (preserving ID, custom label, and device
  /// profile if the email already exists) and refreshes its quota.
  Future<AntigravityAccount> upsertAuthorizedAccount({
    required AntigravityTokenData token,
    required String email,
    String? name,
    String? customLabel,
    bool makeActive = false,
  }) async {
    await ensureInitialized();
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final existingIdx = _accounts.indexWhere(
      (a) => a.email.toLowerCase() == email.trim().toLowerCase(),
    );

    AntigravityAccount account;
    if (existingIdx >= 0) {
      final prev = _accounts[existingIdx];
      account = prev.copyWith(
        email: email.trim(),
        name: name ?? prev.name,
        token: token.copyWith(
          projectId: token.projectId ?? prev.token.projectId,
        ),
        disabled: false,
        disabledReason: null,
        disabledAt: null,
        validationBlocked: false,
        validationBlockedUntil: null,
        validationBlockedReason: null,
        validationUrl: null,
        lastUsed: nowSec,
        customLabel: customLabel ?? prev.customLabel,
      );
      _accounts[existingIdx] = account;
    } else {
      account = AntigravityAccount(
        id: _uuidV4(),
        email: email.trim(),
        name: name,
        token: token,
        deviceProfile: AntigravityDeviceProfile.generate(),
        createdAt: nowSec,
        lastUsed: nowSec,
        customLabel: customLabel,
      );
      _accounts.add(account);
    }

    if (_currentAccountId == null || makeActive) {
      _currentAccountId = account.id;
    }
    await _saveAccount(account);
    await _saveIndex();
    notifyListeners();

    try {
      final withQuota = await refreshQuota(account.id);
      if (withQuota != null) account = withQuota;
    } on Object {
      // Keep newly added account even if quota endpoint transiently fails.
    }

    if (makeActive) {
      account = await switchAccount(account.id);
    }
    return account;
  }

  /// Batch-imports accounts from Refresh Tokens (`1//...`) or exported JSON.
  Future<({int imported, int failed, List<String> errors})>
  importFromTransferText(String rawInput) async {
    await ensureInitialized();
    final items = AntigravityOAuth.parseTransferInput(rawInput);
    if (items.isEmpty) {
      throw const AntigravityAuthException(
        '未识别到有效的 Refresh Token (1//...) 或备份 JSON',
      );
    }
    var imported = 0;
    var failed = 0;
    final errors = <String>[];

    for (final item in items) {
      try {
        final seed = AntigravityTokenData(
          accessToken: '',
          refreshToken: item.refreshToken,
          expiresIn: 0,
          expiryTimestamp: 0,
          oauthClientKey:
              item.oauthClientKey ?? AntigravityOAuth.defaultClientKey,
          projectId: item.projectId,
          isGcpTos: item.isGcpTos,
        );
        final refreshed = await AntigravityOAuth.refreshAccessToken(seed);
        final user = await AntigravityOAuth.fetchUserInfo(
          refreshed.accessToken,
        );
        if (item.email != null &&
            item.email!.isNotEmpty &&
            item.email!.toLowerCase() != user.email.toLowerCase()) {
          throw AntigravityAuthException(
            '邮箱不匹配：JSON 记录为 ${item.email}，实际授权为 ${user.email}',
          );
        }
        await upsertAuthorizedAccount(
          token: refreshed.copyWith(email: user.email),
          email: user.email,
          name: item.name ?? user.name,
          customLabel: item.customLabel,
        );
        imported++;
      } on Object catch (e) {
        failed++;
        errors.add('${item.email ?? 'Token'}：$e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return (imported: imported, failed: failed, errors: errors);
  }

  /// Scans Keychain, `agy` CLI, VS Code, and local `state.vscdb` files and
  /// imports any new or updated accounts.
  Future<({int imported, int duplicates, List<String> details})>
  scanAndImportLocalAccounts() async {
    await ensureInitialized();
    final candidates = await AntigravityCredentialSwitcher.scanLocalCredentials();
    var imported = 0;
    var duplicates = 0;
    final details = <String>[];

    for (final c in candidates) {
      final alreadyHasToken = _accounts.any(
        (a) => a.token.refreshToken.trim() == c.refreshToken && !a.disabled,
      );
      if (alreadyHasToken) {
        duplicates++;
        final existing = _accounts.firstWhere(
          (a) => a.token.refreshToken.trim() == c.refreshToken,
        );
        details.add('${c.source}：已存在 (${existing.email})');
        continue;
      }
      try {
        final seed = AntigravityTokenData(
          accessToken: '',
          refreshToken: c.refreshToken,
          expiresIn: 0,
          expiryTimestamp: 0,
          oauthClientKey: AntigravityOAuth.defaultClientKey,
        );
        final refreshed = await AntigravityOAuth.refreshAccessToken(seed);
        final user = await AntigravityOAuth.fetchUserInfo(
          refreshed.accessToken,
        );
        await upsertAuthorizedAccount(
          token: refreshed.copyWith(email: user.email),
          email: user.email,
          name: user.name,
        );
        imported++;
        details.add('${c.source}：成功导入 ${user.email}');
      } on Object catch (e) {
        details.add('${c.source}：验证失败 ($e)');
      }
    }
    await _reconcileActiveWithKeyring();
    notifyListeners();
    return (imported: imported, duplicates: duplicates, details: details);
  }

  /// Exports all accounts in `schema_version: 2` JSON format.
  String exportAccountsJson() {
    final payload = {
      'schema_version': 2,
      'accounts': [
        for (final a in _accounts)
          {
            'email': a.email,
            'refresh_token': a.token.refreshToken,
            'name': a.name,
            'oauth_client_key':
                a.token.oauthClientKey ?? AntigravityOAuth.defaultClientKey,
            'is_gcp_tos': a.token.isGcpTos,
            if (a.token.projectId != null) 'project_id': a.token.projectId,
            if (a.customLabel case final l? when l.trim().isNotEmpty)
              'custom_label': l.trim(),
          },
      ],
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<void> setCustomLabel(String accountId, String? label) async {
    await ensureInitialized();
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx < 0) return;
    final trimmed = label?.trim();
    final capped = (trimmed != null && trimmed.length > 15)
        ? trimmed.substring(0, 15)
        : trimmed;
    final updated = _accounts[idx].copyWith(
      customLabel: (capped == null || capped.isEmpty) ? null : capped,
    );
    _accounts[idx] = updated;
    await _saveAccount(updated);
    notifyListeners();
  }

  Future<void> setDisabled(String accountId, bool disabled) async {
    await ensureInitialized();
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx < 0) return;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final updated = _accounts[idx].copyWith(
      disabled: disabled,
      disabledAt: disabled ? nowSec : null,
      disabledReason: disabled ? '手动停用' : null,
    );
    _accounts[idx] = updated;
    await _saveAccount(updated);
    await _saveIndex();
    notifyListeners();
  }

  Future<void> deleteAccount(String accountId) async {
    await ensureInitialized();
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx < 0) return;
    _accounts.removeAt(idx);
    final file = File(p.join(dataDirectoryPath, 'accounts', '$accountId.json'));
    if (file.existsSync()) {
      try {
        await file.delete();
      } on Object {
        // Ignore.
      }
    }
    if (_currentAccountId == accountId) {
      _currentAccountId = _accounts.firstOrNull?.id;
    }
    await _saveIndex();
    notifyListeners();
  }

  Future<void> updateAutoSwitch(AntigravityAutoSwitchConfig next) async {
    await ensureInitialized();
    _autoSwitch = next;
    final path = p.join(dataDirectoryPath, 'auto_switch.json');
    await AntigravityCredentialSwitcher.writeAtomicSecure(
      path,
      const JsonEncoder.withIndent('  ').convert(next.toJson()),
    );
    notifyListeners();
  }

  /// When [autoSwitch.enabled] is true and the active account hits quota
  /// exhaustion or drops below [autoSwitch.reservePercentage], switches to the
  /// highest-quota available backup account.
  Future<AntigravityAccount?> tryAutoFailover({String? modelId}) async {
    await ensureInitialized();
    if (!_autoSwitch.enabled || _accounts.length < 2) return null;
    final currentId = _currentAccountId;
    AntigravityAccount? best;
    var bestPct = -1;

    for (final candidate in _accounts) {
      if (candidate.id == currentId || !candidate.isAvailable) continue;
      final pct =
          candidate.quota?.effectivePercentageForModel(modelId) ??
          candidate.quota?.lowestPrimaryPercentage ??
          100;
      if (pct >= _autoSwitch.candidateMinPercentage && pct > bestPct) {
        best = candidate;
        bestPct = pct;
      }
    }
    if (best == null) return null;
    return switchAccount(best.id);
  }

  static String _stripBom(String s) {
    var out = s;
    if (out.startsWith('\uFEFF')) out = out.substring(1);
    while (out.isNotEmpty && out.codeUnitAt(0) == 0) {
      out = out.substring(1);
    }
    return out;
  }

  static String _uuidV4() {
    final rng = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int s, int e) => [
      for (var i = s; i < e; i++) bytes[i].toRadixString(16).padLeft(2, '0'),
    ].join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}
