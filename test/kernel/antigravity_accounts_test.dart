import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/antigravity/antigravity_account_models.dart';
import 'package:baocode/kernel/antigravity/antigravity_accounts.dart';
import 'package:baocode/kernel/antigravity/antigravity_oauth.dart';
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
    });
  });
}
