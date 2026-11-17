import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'antigravity_account_models.dart';

/// Writes credentials and switches active Google accounts across the OS
/// keyring, `agy` CLI, and optional Antigravity Desktop / IDE SQLite stores.
abstract final class AntigravityCredentialSwitcher {
  static String get _home =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '';

  /// Atomically writes [content] to [filePath] with `0600` permissions on Unix.
  static Future<void> writeAtomicSecure(String filePath, String content) async {
    final target = File(filePath);
    await target.parent.create(recursive: true);
    final suffix =
        '${DateTime.now().microsecondsSinceEpoch}_${math.Random.secure().nextInt(1 << 30)}';
    final tmpPath = '$filePath.tmp.$suffix';
    final tmpFile = File(tmpPath);
    await tmpFile.writeAsString(content, flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', tmpPath]);
    }
    await tmpFile.rename(filePath);
  }

  /// Applies [account]'s credentials to:
  /// 1. OS credential store (`gemini` / `antigravity` in macOS Keychain, etc.)
  /// 2. `~/.gemini/antigravity-cli/antigravity-oauth-token` (if initialized)
  /// 3. Optional external Antigravity Desktop / IDE `state.vscdb` & `storage.json`
  ///    when [syncExternalClients] is true.
  static Future<void> applyAccountCredentials(
    AntigravityAccount account, {
    bool syncExternalClients = false,
  }) async {
    final payloadJson = jsonEncode(account.token.toCliCredentialJson());

    // 1. OS keyring (`gemini` / `antigravity`)
    await _writeSystemKeyring(payloadJson);

    // 2. `agy` CLI token file (`~/.gemini/antigravity-cli/antigravity-oauth-token`)
    // Only write when `~/.gemini/antigravity-cli` already exists; never touch
    // `~/.gemini/oauth_creds.json` or `~/.gemini/google_accounts.json`.
    if (_home.isNotEmpty) {
      final cliDir = Directory(p.join(_home, '.gemini', 'antigravity-cli'));
      if (cliDir.existsSync()) {
        final tokenPath = p.join(cliDir.path, 'antigravity-oauth-token');
        final type = FileSystemEntity.typeSync(tokenPath, followLinks: false);
        if (type != FileSystemEntityType.link) {
          await writeAtomicSecure(tokenPath, payloadJson);
        }
      }
    }

    // 3. Optional external Antigravity Desktop / IDE state.vscdb & device profile
    if (syncExternalClients) {
      await _injectExternalClientDatabases(account);
    }
  }

  static Future<void> _writeSystemKeyring(String payloadJson) async {
    if (Platform.isMacOS) {
      final encoded =
          'go-keyring-base64:${base64Encode(utf8.encode(payloadJson))}';
      await Process.run('security', [
        'delete-generic-password',
        '-s',
        'gemini',
        '-a',
        'antigravity',
      ]);
      final res = await Process.run('security', [
        'add-generic-password',
        '-s',
        'gemini',
        '-a',
        'antigravity',
        '-w',
        encoded,
        '-A',
      ]);
      if (res.exitCode != 0) {
        throw Exception('写入 macOS 钥匙串失败：${res.stderr}');
      }
      return;
    }

    if (Platform.isLinux) {
      try {
        final proc = await Process.start('secret-tool', [
          'store',
          "--label=Password for 'antigravity' on 'gemini'",
          'service',
          'gemini',
          'username',
          'antigravity',
        ]);
        proc.stdin.write(payloadJson);
        await proc.stdin.close();
        await proc.exitCode;
      } on Object {
        // Best-effort if secret-tool is not installed.
      }
      return;
    }
  }

  /// Reads the currently active email/refresh_token from OS keyring or `agy` CLI.
  static Future<String?> readActiveRefreshToken() async {
    if (Platform.isMacOS) {
      final res = await Process.run('security', [
        'find-generic-password',
        '-s',
        'gemini',
        '-a',
        'antigravity',
        '-w',
      ]);
      if (res.exitCode == 0) {
        final token = _extractRefreshTokenFromCredentialBlob('${res.stdout}');
        if (token != null) return token;
      }
    }
    if (_home.isNotEmpty) {
      final cliFile = File(
        p.join(_home, '.gemini', 'antigravity-cli', 'antigravity-oauth-token'),
      );
      if (cliFile.existsSync()) {
        try {
          final token = _extractRefreshTokenFromCredentialBlob(
            await cliFile.readAsString(),
          );
          if (token != null) return token;
        } on Object {
          // Ignore unreadable file.
        }
      }
    }
    return null;
  }

  /// Scans all local credential sources (Keychain, `agy` CLI, VS Code extension,
  /// and candidate `state.vscdb` SQLite databases) for importable refresh tokens.
  static Future<List<({String source, String refreshToken})>>
  scanLocalCredentials() async {
    final found = <({String source, String refreshToken})>[];
    final seen = <String>{};

    void addCandidate(String source, String? rt) {
      final trimmed = rt?.trim() ?? '';
      if (trimmed.startsWith('1//') && seen.add(trimmed)) {
        found.add((source: source, refreshToken: trimmed));
      }
    }

    // 1. macOS Keychain
    if (Platform.isMacOS) {
      try {
        final res = await Process.run('security', [
          'find-generic-password',
          '-s',
          'gemini',
          '-a',
          'antigravity',
          '-w',
        ]);
        if (res.exitCode == 0) {
          addCandidate(
            'macOS 钥匙串 (gemini/antigravity)',
            _extractRefreshTokenFromCredentialBlob('${res.stdout}'),
          );
        }
      } on Object {
        // Ignore.
      }
    }

    if (_home.isNotEmpty) {
      // 2. `agy` CLI token file
      final cliTokenFile = File(
        p.join(_home, '.gemini', 'antigravity-cli', 'antigravity-oauth-token'),
      );
      if (cliTokenFile.existsSync()) {
        try {
          addCandidate(
            'Antigravity CLI (agy)',
            _extractRefreshTokenFromCredentialBlob(
              await cliTokenFile.readAsString(),
            ),
          );
        } on Object {
          // Ignore.
        }
      }

      // 3. VS Code standalone token file
      final jetskiFile = File(
        p.join(_home, '.gemini', 'jetski-standalone-oauth-token'),
      );
      if (jetskiFile.existsSync()) {
        try {
          addCandidate(
            'VS Code 插件会话',
            _extractRefreshTokenFromCredentialBlob(
              await jetskiFile.readAsString(),
            ),
          );
        } on Object {
          // Ignore.
        }
      }

      // 4. Candidate `state.vscdb` databases
      for (final dbPath in _candidateVscdbPaths()) {
        if (!File(dbPath).existsSync()) continue;
        final rt = await _readRefreshTokenFromVscdb(dbPath);
        addCandidate('本地客户端数据库 (${p.basename(p.dirname(p.dirname(p.dirname(dbPath))))})', rt);
      }
    }

    return found;
  }

  static String? _extractRefreshTokenFromCredentialBlob(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    const prefix = 'go-keyring-base64:';
    if (trimmed.startsWith(prefix)) {
      try {
        trimmed = utf8.decode(base64Decode(trimmed.substring(prefix.length)));
      } on Object {
        return null;
      }
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final tokenMap = decoded['token'];
        if (tokenMap is Map && tokenMap['refresh_token'] is String) {
          return (tokenMap['refresh_token'] as String).trim();
        }
        if (decoded['refresh_token'] is String) {
          return (decoded['refresh_token'] as String).trim();
        }
      }
    } on Object {
      // Fallback regex scan.
    }
    return null;
  }

  static List<String> _candidateVscdbPaths() {
    if (_home.isEmpty) return const [];
    final folders = [
      'Antigravity',
      'Antigravity IDE',
      'Antigravity-IDE',
      'Code',
      'Cursor',
    ];
    final baseDir = Platform.isMacOS
        ? p.join(_home, 'Library', 'Application Support')
        : Platform.isWindows
        ? (Platform.environment['APPDATA'] ?? '')
        : (Platform.environment['XDG_CONFIG_HOME'] ??
              p.join(_home, '.config'));
    if (baseDir.isEmpty) return const [];
    return [
      for (final f in folders)
        p.join(baseDir, f, 'User', 'globalStorage', 'state.vscdb'),
    ];
  }

  static Future<String?> _readRefreshTokenFromVscdb(String dbPath) async {
    try {
      final res = await Process.run('sqlite3', [
        dbPath,
        "SELECT value FROM ItemTable WHERE key = 'antigravityUnifiedStateSync.oauthToken' LIMIT 1;",
      ]);
      if (res.exitCode == 0) {
        final b64 = '${res.stdout}'.trim();
        if (b64.isNotEmpty) {
          final topicBytes = base64Decode(b64);
          final infoB64 = _ProtobufCodec.findTopicSentinelRow(
            topicBytes,
            'oauthTokenInfoSentinelKey',
          );
          if (infoB64 != null) {
            final infoBytes = base64Decode(infoB64);
            final rt = _ProtobufCodec.readStringField(infoBytes, 3);
            if (rt != null && rt.startsWith('1//')) return rt;
          }
        }
      }
    } on Object {
      // Ignore if sqlite3 unavailable or DB locked.
    }
    return null;
  }

  static Future<void> _injectExternalClientDatabases(
    AntigravityAccount account,
  ) async {
    final profile =
        account.deviceProfile ?? AntigravityDeviceProfile.generate();
    final targetFolders = ['Antigravity', 'Antigravity IDE'];
    final baseDir = Platform.isMacOS
        ? p.join(_home, 'Library', 'Application Support')
        : Platform.isWindows
        ? (Platform.environment['APPDATA'] ?? '')
        : (Platform.environment['XDG_CONFIG_HOME'] ??
              p.join(_home, '.config'));
    if (baseDir.isEmpty) return;

    for (final folder in targetFolders) {
      final globalStorage = p.join(baseDir, folder, 'User', 'globalStorage');
      final dbFile = File(p.join(globalStorage, 'state.vscdb'));
      if (!dbFile.existsSync()) continue;

      // Update storage.json telemetry profile if present.
      final storageFile = File(p.join(globalStorage, 'storage.json'));
      if (storageFile.existsSync()) {
        try {
          final map =
              (jsonDecode(await storageFile.readAsString()) as Map?)
                  ?.cast<String, Object?>() ??
              <String, Object?>{};
          final telemetry =
              (map['telemetry'] as Map?)?.cast<String, Object?>() ??
              <String, Object?>{};
          telemetry['machineId'] = profile.machineId;
          telemetry['macMachineId'] = profile.macMachineId;
          telemetry['devDeviceId'] = profile.devDeviceId;
          telemetry['sqmId'] = profile.sqmId;
          map['telemetry'] = telemetry;
          map['telemetry.machineId'] = profile.machineId;
          map['telemetry.macMachineId'] = profile.macMachineId;
          map['telemetry.devDeviceId'] = profile.devDeviceId;
          map['telemetry.sqmId'] = profile.sqmId;
          map['storage.serviceMachineId'] = profile.devDeviceId;
          await writeAtomicSecure(
            storageFile.path,
            const JsonEncoder.withIndent('  ').convert(map),
          );
        } on Object {
          // Best-effort.
        }
      }

      // Backup & update state.vscdb via sqlite3 CLI.
      try {
        await dbFile.copy('${dbFile.path}.backup');
        final existingRes = await Process.run('sqlite3', [
          dbFile.path,
          "SELECT value FROM ItemTable WHERE key = 'antigravityUnifiedStateSync.oauthToken' LIMIT 1;",
        ]);
        Uint8List existingTopic = Uint8List(0);
        if (existingRes.exitCode == 0 && '${existingRes.stdout}'.trim().isNotEmpty) {
          try {
            existingTopic = base64Decode('${existingRes.stdout}'.trim());
          } on Object {
            existingTopic = Uint8List(0);
          }
        }

        final oauthInfoBytes = _ProtobufCodec.encodeOAuthTokenInfo(
          accessToken: account.token.accessToken,
          refreshToken: account.token.refreshToken,
          expirySeconds: account.token.expiryTimestamp,
          idToken: account.token.idToken,
          isGcpTos: account.token.effectiveIsGcpTos(account.email),
        );
        final updatedOauthTopicB64 = base64Encode(
          _ProtobufCodec.upsertTopicEntry(
            existingTopic,
            'oauthTokenInfoSentinelKey',
            oauthInfoBytes,
          ),
        );

        final userStatusB64 = base64Encode(
          _ProtobufCodec.upsertTopicEntry(
            Uint8List(0),
            'userStatusSentinelKey',
            _ProtobufCodec.encodeMinimalUserStatus(account.email),
          ),
        );

        final projectId = account.token.projectId?.trim() ?? '';
        final sqlBuffer = StringBuffer()
          ..writeln(
            'CREATE TABLE IF NOT EXISTS ItemTable (key TEXT PRIMARY KEY, value TEXT);',
          )
          ..writeln(
            "INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('storage.serviceMachineId', '${_sqlEscape(profile.devDeviceId)}');",
          )
          ..writeln(
            "INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('antigravityUnifiedStateSync.oauthToken', '${_sqlEscape(updatedOauthTopicB64)}');",
          )
          ..writeln(
            "INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('antigravityUnifiedStateSync.userStatus', '${_sqlEscape(userStatusB64)}');",
          );
        if (projectId.isNotEmpty) {
          final entB64 = base64Encode(
            _ProtobufCodec.upsertTopicEntry(
              Uint8List(0),
              'enterpriseGcpProjectId',
              _ProtobufCodec.encodeStringField3(projectId),
            ),
          );
          sqlBuffer.writeln(
            "INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('antigravityUnifiedStateSync.enterprisePreferences', '${_sqlEscape(entB64)}');",
          );
        } else {
          sqlBuffer.writeln(
            "DELETE FROM ItemTable WHERE key = 'antigravityUnifiedStateSync.enterprisePreferences';",
          );
        }
        sqlBuffer
          ..writeln(
            "INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('antigravityOnboarding', 'true');",
          )
          ..writeln(
            "DELETE FROM ItemTable WHERE key = 'jetskiStateSync.agentManagerInitState';",
          );

        final proc = await Process.start('sqlite3', [dbFile.path]);
        proc.stdin.write(sqlBuffer.toString());
        await proc.stdin.close();
        await proc.exitCode;
      } on Object {
        // Ignore if sqlite3 unavailable.
      }
    }
  }

  static String _sqlEscape(String s) => s.replaceAll("'", "''");
}

/// Minimal pure-Dart Protobuf wire-format helper for Antigravity Unified State Sync.
abstract final class _ProtobufCodec {
  static Uint8List encodeOAuthTokenInfo({
    required String accessToken,
    required String refreshToken,
    required int expirySeconds,
    String? idToken,
    required bool isGcpTos,
  }) {
    final out = BytesBuilder();
    _writeString(out, 1, accessToken);
    _writeString(out, 2, 'Bearer');
    _writeString(out, 3, refreshToken);

    final ts = BytesBuilder();
    _writeVarintField(ts, 1, expirySeconds);
    _writeVarintField(ts, 2, 0);
    _writeBytes(out, 4, ts.toBytes());

    if (idToken != null && idToken.isNotEmpty) {
      _writeString(out, 5, idToken);
    }
    if (isGcpTos) {
      _writeVarintField(out, 6, 1);
    }
    return out.toBytes();
  }

  static Uint8List encodeMinimalUserStatus(String email) {
    final out = BytesBuilder();
    _writeString(out, 3, email);
    _writeString(out, 7, email);
    return out.toBytes();
  }

  static Uint8List encodeStringField3(String value) {
    final out = BytesBuilder();
    _writeString(out, 3, value);
    return out.toBytes();
  }

  static Uint8List upsertTopicEntry(
    Uint8List existingTopic,
    String sentinelKey,
    Uint8List payloadBytes,
  ) {
    final out = BytesBuilder();
    for (final entryBytes in _iterFieldBytes(existingTopic, 1)) {
      final key = readStringField(entryBytes, 1);
      if (key != sentinelKey) {
        _writeBytes(out, 1, entryBytes);
      }
    }
    final row = BytesBuilder();
    _writeString(row, 1, base64Encode(payloadBytes));

    final entry = BytesBuilder();
    _writeString(entry, 1, sentinelKey);
    _writeBytes(entry, 2, row.toBytes());

    _writeBytes(out, 1, entry.toBytes());
    return out.toBytes();
  }

  static String? findTopicSentinelRow(
    Uint8List topicBytes,
    String sentinelKey,
  ) {
    for (final entryBytes in _iterFieldBytes(topicBytes, 1)) {
      if (readStringField(entryBytes, 1) == sentinelKey) {
        for (final rowBytes in _iterFieldBytes(entryBytes, 2)) {
          return readStringField(rowBytes, 1);
        }
      }
    }
    return null;
  }

  static String? readStringField(Uint8List bytes, int targetField) {
    for (final chunk in _iterFieldBytes(bytes, targetField)) {
      return utf8.decode(chunk, allowMalformed: true);
    }
    return null;
  }

  static Iterable<Uint8List> _iterFieldBytes(
    Uint8List bytes,
    int targetField,
  ) sync* {
    var offset = 0;
    while (offset < bytes.length) {
      final tagRes = _readVarint(bytes, offset);
      if (tagRes == null) break;
      offset = tagRes.nextOffset;
      final fieldNum = tagRes.value >> 3;
      final wireType = tagRes.value & 0x07;
      switch (wireType) {
        case 0: // varint
          final v = _readVarint(bytes, offset);
          if (v == null) return;
          offset = v.nextOffset;
        case 1: // 64-bit
          offset += 8;
        case 2: // length-delimited
          final lenRes = _readVarint(bytes, offset);
          if (lenRes == null) return;
          offset = lenRes.nextOffset;
          final end = offset + lenRes.value;
          if (end > bytes.length || lenRes.value < 0) return;
          if (fieldNum == targetField) {
            yield Uint8List.sublistView(bytes, offset, end);
          }
          offset = end;
        case 5: // 32-bit
          offset += 4;
        default:
          return;
      }
    }
  }

  static ({int value, int nextOffset})? _readVarint(
    Uint8List bytes,
    int start,
  ) {
    var result = 0;
    var shift = 0;
    var i = start;
    while (i < bytes.length && shift < 64) {
      final byte = bytes[i++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) {
        return (value: result, nextOffset: i);
      }
      shift += 7;
    }
    return null;
  }

  static void _writeVarintField(BytesBuilder out, int field, int value) {
    _writeRawVarint(out, (field << 3) | 0);
    _writeRawVarint(out, value);
  }

  static void _writeString(BytesBuilder out, int field, String value) {
    _writeBytes(out, field, utf8.encode(value));
  }

  static void _writeBytes(BytesBuilder out, int field, List<int> bytes) {
    _writeRawVarint(out, (field << 3) | 2);
    _writeRawVarint(out, bytes.length);
    out.add(bytes);
  }

  static void _writeRawVarint(BytesBuilder out, int value) {
    var v = value;
    while ((v & ~0x7f) != 0) {
      out.addByte((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
    out.addByte(v & 0x7f);
  }
}
