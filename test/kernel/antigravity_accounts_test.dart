import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/antigravity/antigravity_account_models.dart';
import 'package:baocode/kernel/antigravity/antigravity_accounts.dart';
import 'package:baocode/kernel/antigravity/antigravity_oauth.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('AntigravityAccounts migration, transfer & quota pools', () {
    test('toCliCredentialJson emits microsecond UTC RFC3339 expiry', () {
      const token = AntigravityTokenData(
        accessToken: 'ya29.demo',
        refreshToken: '1//0gdemo',
        expiresIn: 3600,
        expiryTimestamp: 1700000000,
        idToken: 'eyJ.demo',
      );
      final json = token.toCliCredentialJson();
      final inner = json['token'] as Map<String, Object?>;
      expect(inner['access_token'], 'ya29.demo');
      expect(inner['refresh_token'], '1//0gdemo');
      expect(inner['token_type'], 'Bearer');
      expect(inner['expiry'], '2023-11-14T22:13:20.000000Z');
      expect(json['auth_method'], 'consumer');
      expect(json['id_token'], 'eyJ.demo');
    });

    test('parseTransferInput supports both raw refresh tokens and v2 JSON', () {
      final fromText = AntigravityOAuth.parseTransferInput(
        'acc1: 1//0gAlphaToken_123\nacc2: 1//0gBetaToken-456\ndup: 1//0gAlphaToken_123',
      );
      expect(fromText.map((e) => e.refreshToken).toList(), [
        '1//0gAlphaToken_123',
        '1//0gBetaToken-456',
      ]);

      final fromJson = AntigravityOAuth.parseTransferInput(
        jsonEncode({
          'schema_version': 2,
          'accounts': [
            {
              'email': 'demo@example.com',
              'refresh_token': '1//0gJsonToken_789',
              'name': 'Demo User',
              'custom_label': '主力号',
            },
          ],
        }),
      );
      expect(fromJson, hasLength(1));
      expect(fromJson.first.email, 'demo@example.com');
      expect(fromJson.first.refreshToken, '1//0gJsonToken_789');
      expect(fromJson.first.customLabel, '主力号');
    });

    test('migrateFromLegacyDirectory copies accounts, index, and quota pools', () async {
      final tmp = await Directory.systemTemp.createTemp('ayte_acc_test_');
      addTearDown(() => tmp.delete(recursive: true));

      final legacyDir = Directory(p.join(tmp.path, 'legacy_tools'));
      final legacyAccounts = Directory(p.join(legacyDir.path, 'accounts'));
      await legacyAccounts.create(recursive: true);

      const id1 = '11111111-1111-4111-8111-111111111111';
      const id2 = '22222222-2222-4222-8222-222222222222';

      await File(p.join(legacyDir.path, 'accounts.json')).writeAsString(
        jsonEncode({
          'version': '2.0',
          'accounts': [
            {
              'id': id1,
              'email': 'first@example.com',
              'name': 'First',
              'disabled': false,
              'created_at': 1700000000,
              'last_used': 1700000100,
            },
            {
              'id': id2,
              'email': 'second@example.com',
              'name': 'Second',
              'disabled': false,
              'created_at': 1700000050,
              'last_used': 1700000200,
            },
          ],
          'current_account_id': id2,
        }),
      );

      for (final (id, email, tier) in [
        (id1, 'first@example.com', 'Google AI Pro'),
        (id2, 'second@example.com', 'Google AI Ultra'),
      ]) {
        await File(p.join(legacyAccounts.path, '$id.json')).writeAsString(
          jsonEncode({
            'id': id,
            'email': email,
            'name': email.split('@').first,
            'token': {
              'access_token': 'ya29.$id',
              'refresh_token': '1//0g$id',
              'expires_in': 3600,
              'expiry_timestamp': 1900000000,
              'token_type': 'Bearer',
            },
            'quota': {
              'models': const [],
              'last_updated': 1794899444,
              'subscription_tier': tier,
              'quota_groups': [
                {
                  'display_name': 'Gemini Models',
                  'buckets': [
                    {
                      'bucket_id': 'gemini-5h',
                      'window': '5h',
                      'remaining_fraction': 0.88,
                      'remaining_fraction_known': true,
                      'reset_time': '2026-11-17T12:00:00Z',
                    },
                    {
                      'bucket_id': 'gemini-weekly',
                      'window': 'weekly',
                      'remaining_fraction': 0.62,
                      'remaining_fraction_known': true,
                      'reset_time': '2026-11-21T00:00:00Z',
                    },
                  ],
                },
                {
                  'display_name': 'Claude and GPT models',
                  'buckets': [
                    {
                      'bucket_id': '3p-5h',
                      'window': '5h',
                      'remaining_fraction': 1.0,
                      'remaining_fraction_known': true,
                      'reset_time': '2026-11-17T12:00:00Z',
                    },
                    {
                      'bucket_id': '3p-weekly',
                      'window': 'weekly',
                      'remaining_fraction': 0.49,
                      'remaining_fraction_known': true,
                      'reset_time': '2026-11-20T00:00:00Z',
                    },
                  ],
                },
              ],
            },
            'created_at': 1700000000,
            'last_used': 1700000100,
          }),
        );
      }

      final targetPath = p.join(tmp.path, 'ayte_accounts');
      final store = AntigravityAccounts(dataDir: targetPath);
      final count = await store.migrateFromLegacyDirectory(legacyDir);

      expect(count, 2);
      expect(store.accounts.map((a) => a.email).toList(), [
        'first@example.com',
        'second@example.com',
      ]);
      expect(store.accounts[0].tier, AntigravityTier.pro);
      expect(store.accounts[1].tier, AntigravityTier.ultra);
      expect(store.currentAccountId, id2);

      final fiveHourPools = store.accounts[0].quota!.poolDisplays(
        AntigravityQuotaWindow.fiveHour,
      );
      expect(
        fiveHourPools.map((p) => (p.pool, p.percentage)).toList(),
        [
          (AntigravityQuotaPool.gemini, 88),
          (AntigravityQuotaPool.thirdParty, 100),
        ],
      );

      final weeklyPools = store.accounts[0].quota!.poolDisplays(
        AntigravityQuotaWindow.weekly,
      );
      expect(
        weeklyPools.map((p) => (p.pool, p.percentage)).toList(),
        [
          (AntigravityQuotaPool.gemini, 62),
          (AntigravityQuotaPool.thirdParty, 49),
        ],
      );

      final usageGroups = store.accounts[0].quota!.resolvedUsageGroups;
      expect(usageGroups, hasLength(2));
      expect(usageGroups[0].displayName, 'Gemini Models');
      expect(
        usageGroups[0].buckets.map((b) => (b.window, b.percentage)).toList(),
        [('weekly', 62), ('5h', 88)],
      );
      expect(usageGroups[1].displayName, 'Claude and GPT models');
      expect(
        usageGroups[1].buckets.map((b) => (b.window, b.percentage)).toList(),
        [('weekly', 49), ('5h', 100)],
      );
    });

    test(
      'extractOAuthClientPairsFromText ignores bogus binary symbols and pairs 1071 enterprise client first',
      () {
        final domain = ['.apps', 'googleusercontent', 'com'].join('.');
        final pfx = ['GOC', 'SPX-'].join();
        final idOther = '884354919052-${'a' * 32}$domain';
        final idEnt = '1071006060591-${'b' * 32}$domain';
        final secOther = '$pfx${'x' * 28}';
        final secEnt = '$pfx${'y' * 28}';
        final fakeBinaryText =
            'noise OTESHA-${'z' * 28} $idOther $idEnt $secOther $secEnt ';

        final pairs = AntigravityOAuth.extractOAuthClientPairsFromText(
          fakeBinaryText,
        );
        expect(pairs, isNotEmpty);
        expect(pairs.first.clientId, idEnt);
        expect(pairs.first.clientSecret, secEnt);
        expect(
          pairs.any((p) => p.clientSecret.startsWith('OTESHA-')),
          isFalse,
        );
      },
    );

    test(
      'ensureInitialized loads disk accounts under FLUTTER_TEST without background HTTP refresh or timers, while explicit refreshAllQuotas still runs',
      () async {
        final tmp = await Directory.systemTemp.createTemp('ayte_acc_init_');
        addTearDown(() => tmp.delete(recursive: true));

        final dataDir = Directory(p.join(tmp.path, 'ayte_accounts'));
        final accountsDir = Directory(p.join(dataDir.path, 'accounts'))
          ..createSync(recursive: true);

        const id1 = '33333333-3333-4333-8333-333333333333';
        final futureExpiry =
            DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
        await File(p.join(dataDir.path, 'accounts.json')).writeAsString(
          jsonEncode({
            'version': '2.0',
            'accounts': [
              {
                'id': id1,
                'email': 'quiet@example.com',
                'name': 'Quiet',
                'disabled': false,
                'created_at': 1700000000,
                'last_used': 1700000100,
              },
            ],
            'current_account_id': id1,
          }),
        );
        await File(p.join(accountsDir.path, '$id1.json')).writeAsString(
          jsonEncode({
            'id': id1,
            'email': 'quiet@example.com',
            'name': 'Quiet',
            'token': {
              'access_token': 'ya29.quiet',
              'refresh_token': '1//0gquiet',
              'expires_in': 3600,
              'expiry_timestamp': futureExpiry,
              'token_type': 'Bearer',
            },
            'created_at': 1700000000,
            'last_used': 1700000100,
          }),
        );

        var httpOpenCount = 0;
        final savedOverrides = HttpOverrides.current;
        HttpOverrides.global = _CountingHttpOverrides(() => httpOpenCount++);
        addTearDown(() => HttpOverrides.global = savedOverrides);

        final store = AntigravityAccounts(dataDir: dataDir.path);
        addTearDown(store.dispose);

        await store.ensureInitialized();
        store.scheduleActiveQuotaRefresh(
          delay: const Duration(milliseconds: 10),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(Platform.environment.containsKey('FLUTTER_TEST'), isTrue);
        expect(store.accounts, hasLength(1));
        expect(store.currentAccount?.email, 'quiet@example.com');
        expect(httpOpenCount, 0);
        expect(store.lastRefreshError, isNull);

        await store.refreshAllQuotas();
        expect(httpOpenCount, greaterThan(0));
      },
    );

    test(
      'ensureInitialized resolves mixed-case Windows Home and UserProfile from ClaudeEnvironment without falling back to host home',
      () async {
        final tmp = await Directory.systemTemp.createTemp('ayte_acc_env_');
        addTearDown(() {
          ClaudeEnvironment.use(null);
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });

        final isoHome = Directory(p.join(tmp.path, 'iso_home'))
          ..createSync(recursive: true);
        ClaudeEnvironment.use({
          'Home': isoHome.path,
          'UserProfile': isoHome.path,
        });

        final store = AntigravityAccounts();
        addTearDown(store.dispose);
        await store.ensureInitialized();

        final expectedDir = p.join(
          isoHome.path,
          '.ayte',
          'antigravity_accounts',
        );
        expect(store.dataDirectoryPath, expectedDir);
        expect(Directory(expectedDir).existsSync(), isTrue);

        // Explicit blank Home/UserProfile must not fall back to host Platform.environment.
        ClaudeEnvironment.use({'Home': '', 'UserProfile': ''});
        final blankStore = AntigravityAccounts();
        addTearDown(blankStore.dispose);
        // Only resolve path via a sub-temp working dir? No: instead assert it does
        // not pick host USERPROFILE/HOME by checking dataDirectoryPath after init
        // when cwd is temp; use a clean temp cwd so '.ayte/antigravity_accounts'
        // is isolated inside tmp!
        final savedCwd = Directory.current;
        Directory.current = tmp;
        addTearDown(() => Directory.current = savedCwd);
        await blankStore.ensureInitialized();
        expect(
          blankStore.dataDirectoryPath,
          p.join('.ayte', 'antigravity_accounts'),
        );
      },
    );
  });

  group('AntigravityAccounts cross-zone ensureInitialized resilience', () {
    late Directory tmp;
    late AntigravityAccounts sharedAcc;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('ayte_acc_zone_');
      sharedAcc = AntigravityAccounts(dataDir: p.join(tmp.path, 'shared'));
    });

    tearDownAll(() {
      sharedAcc.dispose();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    testWidgets(
      'unawaited ensureInitialized inside FakeAsync does not deadlock later callers',
      (tester) async {
        unawaited(sharedAcc.ensureInitialized());
        await tester.pump();
      },
    );

    test(
      'ensureInitialized completes cleanly in root test zone after FakeAsync',
      () async {
        await sharedAcc.ensureInitialized().timeout(
          const Duration(seconds: 3),
        );
        expect(sharedAcc.accounts, isEmpty);
      },
    );

    test(
      'concurrent cross-zone ensureInitialized calls load disk accounts without duplicates',
      () async {
        final localTmp = Directory.systemTemp.createTempSync('ayte_acc_zones_');
        addTearDown(() {
          ClaudeEnvironment.use(null);
          if (localTmp.existsSync()) localTmp.deleteSync(recursive: true);
        });

        void seedAccountDir(Directory dataDir, String id, String email) {
          final accountsDir = Directory(p.join(dataDir.path, 'accounts'))
            ..createSync(recursive: true);
          File(p.join(accountsDir.path, '$id.json')).writeAsStringSync(
            jsonEncode({
              'id': id,
              'email': email,
              'name': id,
              'token': {
                'access_token': 'ya29.$id',
                'refresh_token': '1//0g$id',
                'expires_in': 3600,
                'expiry_timestamp': 1900000000,
                'token_type': 'Bearer',
              },
              'created_at': 1700000000,
              'last_used': 1700000100,
            }),
          );
          File(p.join(dataDir.path, 'accounts.json')).writeAsStringSync(
            jsonEncode({
              'version': '2.0',
              'accounts': [
                {
                  'id': id,
                  'email': email,
                  'name': id,
                  'disabled': false,
                  'created_at': 1700000000,
                  'last_used': 1700000100,
                },
              ],
              'current_account_id': id,
            }),
          );
        }

        final explicitDir = Directory(p.join(localTmp.path, 'explicit'));
        seedAccountDir(explicitDir, 'acc-1', 'one@example.com');
        final store = AntigravityAccounts(dataDir: explicitDir.path);
        addTearDown(store.dispose);

        await Future.wait([
          runZoned(() => store.ensureInitialized()),
          runZoned(() => store.ensureInitialized()),
          runZoned(() => store.ensureInitialized()),
        ]);

        expect(store.accounts.map((a) => a.id).toList(), ['acc-1']);
        expect(store.currentAccountId, 'acc-1');
        final exported =
            jsonDecode(store.exportAccountsJson()) as Map<String, Object?>;
        expect(exported['accounts'], hasLength(1));

        // Also verify env-resolved cross-zone reload across home1 -> home2.
        final home1 = Directory(p.join(localTmp.path, 'home1'));
        final home2 = Directory(p.join(localTmp.path, 'home2'));
        seedAccountDir(
          Directory(p.join(home1.path, '.ayte', 'antigravity_accounts')),
          'acc-h1',
          'h1@example.com',
        );
        seedAccountDir(
          Directory(p.join(home2.path, '.ayte', 'antigravity_accounts')),
          'acc-h2',
          'h2@example.com',
        );

        final envStore = AntigravityAccounts();
        addTearDown(envStore.dispose);
        ClaudeEnvironment.use({'Home': home1.path, 'UserProfile': home1.path});
        await Future.wait([
          runZoned(() => envStore.ensureInitialized()),
          runZoned(() => envStore.ensureInitialized()),
        ]);
        expect(envStore.accounts.map((a) => a.id).toList(), ['acc-h1']);

        ClaudeEnvironment.use({'Home': home2.path, 'UserProfile': home2.path});
        await Future.wait([
          runZoned(() => envStore.ensureInitialized()),
          runZoned(() => envStore.ensureInitialized()),
          runZoned(() => envStore.ensureInitialized()),
        ]);
        expect(envStore.accounts.map((a) => a.id).toList(), ['acc-h2']);
        expect(envStore.currentAccountId, 'acc-h2');
      },
    );
  });
}

class _CountingHttpOverrides extends HttpOverrides {
  _CountingHttpOverrides(this.onRequest);

  final void Function() onRequest;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _CountingHttpClient(onRequest);
  }
}

class _CountingHttpClient implements HttpClient {
  _CountingHttpClient(this.onRequest);

  final void Function() onRequest;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    onRequest();
    return Future<HttpClientRequest>.error(
      const SocketException('blocked in test'),
    );
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
