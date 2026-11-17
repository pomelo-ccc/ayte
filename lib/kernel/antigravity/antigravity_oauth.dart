import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'antigravity_account_models.dart';
import 'antigravity_cli.dart';
import 'antigravity_switcher.dart';

/// Google OAuth2 client & transfer utilities for Antigravity accounts.
///
/// Installed-app OAuth client parameters are resolved dynamically at runtime
/// from environment overrides, local `~/.ayte/antigravity_accounts/oauth_client.json`,
/// or the user's installed `agy` CLI binary — keeping zero OAuth client
/// credentials in source control.
abstract final class AntigravityOAuth {
  static const defaultClientKey = 'antigravity_enterprise';

  static const authUrl = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const tokenUrl = 'https://oauth2.googleapis.com/token';
  static const userInfoUrl = 'https://www.googleapis.com/oauth2/v2/userinfo';

  static const scopes = [
    'openid',
    'https://www.googleapis.com/auth/cloud-platform',
    'https://www.googleapis.com/auth/userinfo.email',
    'https://www.googleapis.com/auth/userinfo.profile',
    'https://www.googleapis.com/auth/cclog',
    'https://www.googleapis.com/auth/experimentsandconfigs',
  ];

  static ({String clientId, String clientSecret})? _cachedClient;

  static final RegExp _clientIdRegex = RegExp(
    r'\d{10,15}-[a-z0-9]{20,40}\.[a-z]+\.[a-z]+\.com',
  );
  static final RegExp _clientSecretRegex = RegExp(
    r'[A-Z]{6}-[A-Za-z0-9_\-]{24,36}',
  );

  /// Resolves the installed-app OAuth client pair from env vars, local cache,
  /// or the locally installed `agy` CLI binary.
  static Future<({String clientId, String clientSecret})>
  resolveOAuthClient() async {
    if (_cachedClient case final c?) return c;

    final envId = Platform.environment['ANTIGRAVITY_OAUTH_CLIENT_ID']?.trim();
    final envSec =
        Platform.environment['ANTIGRAVITY_OAUTH_CLIENT_SECRET']?.trim();
    if (envId != null &&
        envId.isNotEmpty &&
        envSec != null &&
        envSec.isNotEmpty) {
      return _cachedClient = (clientId: envId, clientSecret: envSec);
    }

    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final cachePath = home.isEmpty
        ? null
        : p.join(home, '.ayte', 'antigravity_accounts', 'oauth_client.json');

    if (cachePath != null && File(cachePath).existsSync()) {
      try {
        final decoded = jsonDecode(await File(cachePath).readAsString());
        if (decoded is Map) {
          final id = '${decoded['client_id'] ?? ''}'.trim();
          final sec = '${decoded['client_secret'] ?? ''}'.trim();
          if (id.isNotEmpty && sec.isNotEmpty) {
            return _cachedClient = (clientId: id, clientSecret: sec);
          }
        }
      } on Object {
        // Re-extract below.
      }
    }

    final located = await LocalAntigravity.locate();
    final text = latin1.decode(
      await File(located.executable).readAsBytes(),
      allowInvalid: true,
    );
    final ids = <String>[];
    for (final m in _clientIdRegex.allMatches(text)) {
      final v = m.group(0)!;
      if (v.endsWith('.googleusercontent.com') && !ids.contains(v)) {
        ids.add(v);
      }
    }
    final secrets = <String>[];
    for (final m in _clientSecretRegex.allMatches(text)) {
      final v = m.group(0)!;
      if (!secrets.contains(v)) secrets.add(v);
    }

    if (ids.isEmpty || secrets.isEmpty) {
      throw const AntigravityAuthException(
        '未能在本地 agy CLI 中定位到 OAuth 客户端配置，请确认已安装最新 agy CLI',
      );
    }

    var idx = ids.indexWhere((s) => s.startsWith('1071'));
    if (idx < 0 || idx >= secrets.length) idx = 0;
    final resolved = (clientId: ids[idx], clientSecret: secrets[idx]);
    _cachedClient = resolved;

    if (cachePath != null) {
      try {
        await AntigravityCredentialSwitcher.writeAtomicSecure(
          cachePath,
          const JsonEncoder.withIndent('  ').convert({
            'client_id': resolved.clientId,
            'client_secret': resolved.clientSecret,
          }),
        );
      } on Object {
        // Non-fatal cache write failure.
      }
    }
    return resolved;
  }

  static String get nativeUserAgent {
    final os = Platform.isMacOS
        ? 'macos'
        : Platform.isWindows
        ? 'windows'
        : 'linux';
    final arch = _detectArch();
    return 'antigravity/hub/4.10.17 (os_type=$os; arch=$arch)';
  }

  static String _detectArch() {
    final version = Platform.version.toLowerCase();
    if (version.contains('arm64') || version.contains('aarch64')) {
      return 'arm64';
    }
    return 'amd64';
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

  /// Starts a local loopback OAuth2 session and returns a [PendingOAuthFlow]
  /// containing the authorization URL, manual code fallback, and completion
  /// future.
  static Future<PendingOAuthFlow> startOAuthFlow() async {
    HttpServer? ipv6Server;
    HttpServer? ipv4Server;
    late final int port;
    late final String redirectUri;

    try {
      ipv6Server = await HttpServer.bind(InternetAddress.loopbackIPv6, 0);
      port = ipv6Server.port;
      try {
        ipv4Server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        redirectUri = 'http://localhost:$port/oauth-callback';
      } on Object {
        redirectUri = 'http://[::1]:$port/oauth-callback';
      }
    } on Object {
      ipv4Server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = ipv4Server.port;
      try {
        ipv6Server = await HttpServer.bind(InternetAddress.loopbackIPv6, port);
        redirectUri = 'http://localhost:$port/oauth-callback';
      } on Object {
        redirectUri = 'http://127.0.0.1:$port/oauth-callback';
      }
    }

    final oauthClient = await resolveOAuthClient();
    final state = _uuidV4();
    final authUri = Uri.parse(authUrl).replace(
      queryParameters: {
        'client_id': oauthClient.clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': scopes.join(' '),
        'access_type': 'offline',
        'prompt': 'consent',
        'include_granted_scopes': 'true',
        'state': state,
      },
    );

    final codeCompleter = Completer<String>();

    Future<void> handleRequest(HttpRequest req) async {
      try {
        if (req.method != 'GET' || req.uri.path != '/oauth-callback') {
          req.response
            ..statusCode = HttpStatus.notFound
            ..write('Not Found');
          await req.response.close();
          return;
        }
        final params = req.uri.queryParameters;
        final gotState = params['state'];
        final code = params['code']?.trim() ?? '';
        final err = params['error'];
        if (err != null && err.isNotEmpty) {
          req.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.html
            ..write(_callbackHtml(success: false, detail: err));
          await req.response.close();
          if (!codeCompleter.isCompleted) {
            codeCompleter.completeError(
              AntigravityAuthException('Google OAuth 授权被拒绝：$err'),
            );
          }
          return;
        }
        if (gotState != state || code.isEmpty) {
          req.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.html
            ..write(
              _callbackHtml(success: false, detail: '无效的回调参数或 State 不匹配'),
            );
          await req.response.close();
          return;
        }
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(_callbackHtml(success: true));
        await req.response.close();
        if (!codeCompleter.isCompleted) {
          codeCompleter.complete(code);
        }
      } on Object {
        // Ignore transient browser preconnect socket errors.
      }
    }

    final sub6 = ipv6Server?.listen(handleRequest);
    final sub4 = ipv4Server?.listen(handleRequest);

    Future<void> closeServers() async {
      await sub6?.cancel();
      await sub4?.cancel();
      await ipv6Server?.close(force: true);
      await ipv4Server?.close(force: true);
    }

    final timeout = Timer(const Duration(minutes: 5), () {
      if (!codeCompleter.isCompleted) {
        codeCompleter.completeError(
          const AntigravityAuthException('OAuth 授权等待超时（5 分钟）'),
        );
      }
    });

    final tokenFuture = codeCompleter.future.whenComplete(() {
      timeout.cancel();
      unawaited(closeServers());
    }).then(
      (code) => exchangeAuthorizationCode(code: code, redirectUri: redirectUri),
    );

    return PendingOAuthFlow(
      authorizationUrl: authUri.toString(),
      redirectUri: redirectUri,
      expectedState: state,
      result: tokenFuture,
      submitManualInput: (rawInput) {
        final extracted = extractCodeFromInput(rawInput, expectedState: state);
        if (extracted == null || extracted.isEmpty) {
          throw const AntigravityAuthException('未能从输入中解析出有效的授权 Code');
        }
        if (!codeCompleter.isCompleted) {
          codeCompleter.complete(extracted);
        }
      },
      cancel: () {
        timeout.cancel();
        if (!codeCompleter.isCompleted) {
          codeCompleter.completeError(
            const AntigravityAuthException('已取消 OAuth 登录'),
          );
        }
        unawaited(closeServers());
      },
    );
  }

  static String? extractCodeFromInput(
    String rawInput, {
    String? expectedState,
  }) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('http://') ||
        trimmed.startsWith('https://') ||
        trimmed.contains('code=')) {
      final uri = Uri.tryParse(
        trimmed.startsWith('http') ? trimmed : 'http://localhost/?$trimmed',
      );
      if (uri != null) {
        final state = uri.queryParameters['state'];
        if (expectedState != null &&
            state != null &&
            state.isNotEmpty &&
            state != expectedState) {
          throw const AntigravityAuthException('回调 URL 的 state 与当前会话不匹配');
        }
        final code = uri.queryParameters['code']?.trim();
        if (code != null && code.isNotEmpty) return code;
      }
    }
    return trimmed;
  }

  /// Exchanges an authorization `code` for an [AntigravityTokenData] + user profile.
  static Future<({AntigravityTokenData token, String email, String? name})>
  exchangeAuthorizationCode({
    required String code,
    required String redirectUri,
  }) async {
    final oauthClient = await resolveOAuthClient();
    final resp = await _postForm(tokenUrl, {
      'client_id': oauthClient.clientId,
      'client_secret': oauthClient.clientSecret,
      'code': code,
      'redirect_uri': redirectUri,
      'grant_type': 'authorization_code',
    });
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw AntigravityAuthException(
        'OAuth Token 交换失败 (${resp.statusCode})：${resp.body}',
      );
    }
    final json = _decodeMap(resp.body);
    final accessToken = '${json['access_token'] ?? ''}'.trim();
    final refreshToken = '${json['refresh_token'] ?? ''}'.trim();
    if (accessToken.isEmpty || refreshToken.isEmpty) {
      throw const AntigravityAuthException(
        'Google 未返回 refresh_token，请在 Google 账号安全设置中移除旧授权后重试',
      );
    }
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3599;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final idToken = json['id_token'] as String?;

    final user = await fetchUserInfo(accessToken);
    final token = AntigravityTokenData(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresIn: expiresIn,
      expiryTimestamp: nowSec + expiresIn,
      tokenType: (json['token_type'] as String?) ?? 'Bearer',
      email: user.email,
      oauthClientKey: defaultClientKey,
      isGcpTos: false,
      idToken: idToken,
    );
    return (token: token, email: user.email, name: user.name);
  }

  /// Refreshes [current] if expiring within [skewSeconds] (or unconditionally
  /// when [force] is true). Confirms `invalid_grant` with a second attempt.
  static Future<AntigravityTokenData> ensureFreshToken(
    AntigravityTokenData current, {
    bool force = false,
    int skewSeconds = 900,
  }) async {
    if (!force && current.isFresh(skewSeconds: skewSeconds)) {
      return current;
    }
    return refreshAccessToken(current);
  }

  static Future<AntigravityTokenData> refreshAccessToken(
    AntigravityTokenData current,
  ) async {
    if (current.refreshToken.trim().isEmpty) {
      throw const AntigravityAuthException(
        'invalid_grant: 缺少 refresh_token',
        isInvalidGrant: true,
      );
    }

    final oauthClient = await resolveOAuthClient();
    for (var attempt = 0; attempt < 2; attempt++) {
      final resp = await _postForm(tokenUrl, {
        'client_id': oauthClient.clientId,
        'client_secret': oauthClient.clientSecret,
        'refresh_token': current.refreshToken.trim(),
        'grant_type': 'refresh_token',
      });
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final json = _decodeMap(resp.body);
        final accessToken = '${json['access_token'] ?? ''}'.trim();
        if (accessToken.isEmpty) {
          throw const AntigravityAuthException('刷新成功但返回的 access_token 为空');
        }
        final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3599;
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final nextRefresh =
            (json['refresh_token'] as String?)?.trim().isNotEmpty == true
            ? (json['refresh_token'] as String).trim()
            : current.refreshToken;
        final nextIdToken =
            (json['id_token'] as String?)?.trim().isNotEmpty == true
            ? (json['id_token'] as String).trim()
            : current.idToken;
        return current.copyWith(
          accessToken: accessToken,
          refreshToken: nextRefresh,
          expiresIn: expiresIn,
          expiryTimestamp: nowSec + expiresIn,
          idToken: nextIdToken,
        );
      }

      final lower = resp.body.toLowerCase();
      final isInvalidGrant = lower.contains('invalid_grant');
      if (isInvalidGrant && attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }
      throw AntigravityAuthException(
        '刷新 Token 失败 (${resp.statusCode})：${resp.body}',
        isInvalidGrant: isInvalidGrant,
        statusCode: resp.statusCode,
      );
    }

    throw const AntigravityAuthException(
      'invalid_grant: Token 已被撤销或失效',
      isInvalidGrant: true,
    );
  }

  /// Queries Google OAuth2 userinfo (`email`, `name`).
  static Future<({String email, String? name})> fetchUserInfo(
    String accessToken,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(userInfoUrl));
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $accessToken')
        ..set(HttpHeaders.userAgentHeader, nativeUserAgent);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await utf8.decodeStream(resp);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw AntigravityAuthException(
          '获取 Google 用户信息失败 (${resp.statusCode})：$body',
        );
      }
      final json = _decodeMap(body);
      final email = '${json['email'] ?? ''}'.trim();
      if (email.isEmpty) {
        throw const AntigravityAuthException('Google 用户信息未包含邮箱');
      }
      final rawName = (json['name'] as String?)?.trim();
      final given = (json['given_name'] as String?)?.trim() ?? '';
      final family = (json['family_name'] as String?)?.trim() ?? '';
      final fallbackName = '$given $family'.trim();
      final name = (rawName != null && rawName.isNotEmpty)
          ? rawName
          : (fallbackName.isNotEmpty ? fallbackName : null);
      return (email: email, name: name);
    } finally {
      client.close(force: true);
    }
  }

  /// Parses either structured JSON export (`schema_version: 2`, array, or single
  /// account object) or free-form text containing one or more `1//...` refresh
  /// tokens.
  static List<AntigravityTransferItem> parseTransferInput(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return const [];

    final seenTokens = <String>{};
    final items = <AntigravityTransferItem>[];

    void addItem(AntigravityTransferItem item) {
      final rt = item.refreshToken.trim();
      if (!_refreshTokenPattern.hasMatch(rt)) return;
      if (seenTokens.add(rt)) {
        items.add(item.copyWithRefreshToken(rt));
      }
    }

    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      final decoded = jsonDecode(trimmed);
      final List<Object?> list = switch (decoded) {
        final List<Object?> arr => arr,
        final Map map when map['accounts'] is List =>
          map['accounts'] as List<Object?>,
        final Map map => [map],
        _ => const [],
      };
      for (final entry in list) {
        if (entry is! Map) continue;
        final m = entry.cast<String, Object?>();
        final tokenMap = (m['token'] as Map?)?.cast<String, Object?>();
        final rt =
            (m['refresh_token'] as String?) ??
            (tokenMap?['refresh_token'] as String?) ??
            '';
        addItem(
          AntigravityTransferItem(
            refreshToken: rt,
            email: (m['email'] as String?)?.trim(),
            name: (m['name'] as String?)?.trim(),
            oauthClientKey:
                (m['oauth_client_key'] as String?) ??
                (tokenMap?['oauth_client_key'] as String?),
            projectId:
                (m['project_id'] as String?) ??
                (tokenMap?['project_id'] as String?),
            isGcpTos: m['is_gcp_tos'] == true || tokenMap?['is_gcp_tos'] == true,
            customLabel: (m['custom_label'] as String?)?.trim(),
          ),
        );
      }
      return items;
    }

    for (final match in _refreshTokenExtractPattern.allMatches(trimmed)) {
      addItem(AntigravityTransferItem(refreshToken: match.group(0)!));
    }
    return items;
  }

  static final RegExp _refreshTokenPattern = RegExp(r'^1//[a-zA-Z0-9_\-]+$');
  static final RegExp _refreshTokenExtractPattern = RegExp(
    r'1//[a-zA-Z0-9_\-]+',
  );

  static Future<({int statusCode, String body})> _postForm(
    String url,
    Map<String, String> fields,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(Uri.parse(url));
      final encoded = fields.entries
          .map(
            (e) =>
                '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
          )
          .join('&');
      final bytes = utf8.encode(encoded);
      req.headers
        ..set(
          HttpHeaders.contentTypeHeader,
          'application/x-www-form-urlencoded',
        )
        ..set(HttpHeaders.userAgentHeader, nativeUserAgent)
        ..contentLength = bytes.length;
      req.add(bytes);
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final body = await utf8.decodeStream(resp);
      return (statusCode: resp.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  }

  static Map<String, Object?> _decodeMap(String body) {
    final decoded = jsonDecode(body);
    if (decoded is Map) return decoded.cast<String, Object?>();
    return const {};
  }

  static String _callbackHtml({required bool success, String? detail}) {
    final title = success ? 'Ayte 账号授权成功' : 'Ayte 账号授权失败';
    final msg = success
        ? 'Google 账号已成功连接至 Ayte，你可以直接关闭此浏览器标签页并返回 Ayte。'
        : '授权未完成：${detail ?? '未知错误'}';
    final accent = success ? '#10B981' : '#EF4444';
    return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>$title</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0B1017; color: #F3F4F6; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
  .card { background: #131B26; border: 1px solid rgba(255,255,255,0.08); border-radius: 16px; padding: 32px 36px; max-width: 420px; text-align: center; box-shadow: 0 20px 50px rgba(0,0,0,0.45); }
  .dot { width: 12px; height: 12px; border-radius: 50%; background: $accent; display: inline-block; margin-bottom: 14px; }
  h2 { margin: 0 0 10px; font-size: 19px; }
  p { margin: 0; font-size: 14px; color: #9CA3AF; line-height: 1.6; }
</style>
</head>
<body>
  <div class="card">
    <div class="dot"></div>
    <h2>$title</h2>
    <p>$msg</p>
  </div>
  ${success ? '<script>setTimeout(() => window.close(), 1200);</script>' : ''}
</body>
</html>''';
  }
}

class PendingOAuthFlow {
  const PendingOAuthFlow({
    required this.authorizationUrl,
    required this.redirectUri,
    required this.expectedState,
    required this.result,
    required this.submitManualInput,
    required this.cancel,
  });

  final String authorizationUrl;
  final String redirectUri;
  final String expectedState;
  final Future<({AntigravityTokenData token, String email, String? name})>
  result;
  final void Function(String rawUrlOrCode) submitManualInput;
  final void Function() cancel;
}

class AntigravityTransferItem {
  const AntigravityTransferItem({
    required this.refreshToken,
    this.email,
    this.name,
    this.oauthClientKey,
    this.projectId,
    this.isGcpTos = false,
    this.customLabel,
  });

  final String refreshToken;
  final String? email;
  final String? name;
  final String? oauthClientKey;
  final String? projectId;
  final bool isGcpTos;
  final String? customLabel;

  AntigravityTransferItem copyWithRefreshToken(String next) =>
      AntigravityTransferItem(
        refreshToken: next,
        email: email,
        name: name,
        oauthClientKey: oauthClientKey,
        projectId: projectId,
        isGcpTos: isGcpTos,
        customLabel: customLabel,
      );
}

class AntigravityAuthException implements Exception {
  const AntigravityAuthException(
    this.message, {
    this.isInvalidGrant = false,
    this.statusCode,
  });

  final String message;
  final bool isInvalidGrant;
  final int? statusCode;

  @override
  String toString() => message;
}
