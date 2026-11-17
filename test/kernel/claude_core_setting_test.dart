@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:baocode/kernel/antigravity/antigravity_cli.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/claude_code/dart_core_transport_io.dart';
import 'package:baocode/network/network_proxy_io.dart';
import 'package:baocode/network/proxy_settings.dart';
import 'package:baocode/remote/remote_claude.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('the core: as picked; unset, Antigravity CLI where agy is '
      'installed, else built-in', () {
    ClaudeCore.antigravityInstalled = () => false;
    expect(ClaudeCore.parse(null), ClaudeCore.builtin);
    expect(ClaudeCore.parse('builtin'), ClaudeCore.builtin);
    expect(ClaudeCore.parse('antigravity'), ClaudeCore.antigravity);
    expect(ClaudeCore.parse('nonsense'), ClaudeCore.builtin);
    expect(ClaudeCore.parse(true), ClaudeCore.builtin);

    ClaudeCore.antigravityInstalled = () => true;
    addTearDown(() => ClaudeCore.antigravityInstalled = () => false);
    expect(ClaudeCore.parse(null), ClaudeCore.antigravity);
    expect(ClaudeCore.parse('nonsense'), ClaudeCore.antigravity);
    expect(ClaudeCore.parse('builtin'), ClaudeCore.builtin);
    expect(ClaudeCore.parse('antigravity'), ClaudeCore.antigravity);
  });

  group('what runs a session here', () {
    late Directory root;
    late String cwd;

    setUp(() {
      root = Directory.systemTemp.createTempSync('ayte-core-');
      cwd = p.join(root.resolveSymbolicLinksSync(), 'project');
      Directory(cwd).createSync();
      final fake = File(p.join(root.path, 'agy'))
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      Process.runSync('chmod', ['+x', fake.path]);
      AntigravityPathSetting.current = () => fake.path;
      NetworkProxy.instance.follow(
        ValueNotifier(0),
        (key) => key == ProxyMode.settingKey ? ProxyMode.off.value : null,
      );
    });

    tearDown(() {
      AntigravityPathSetting.current = () => null;
      ClaudeCore.current = () => ClaudeCore.fallback;
      ClaudeEnvironment.use(null);
      root.deleteSync(recursive: true);
    });

    void environment({String? key}) => ClaudeEnvironment.use({
      'HOME': root.path,
      'PATH': '/usr/bin:/bin',
      ClaudeEnvironment.dataPathVariable: p.join(root.path, 'config'),
      'ANTHROPIC_API_KEY': ?key,
    });

    Future<ClaudeCodeTransport> start({Map<String, String>? env}) async {
      final transport = await startClaude(ClaudeLaunch(cwd: cwd, env: env));
      addTearDown(() async {
        transport.close();
        await transport.exited.timeout(const Duration(seconds: 20));
      });
      return transport;
    }

    test('the built-in core, on a custom provider\'s model', () async {
      environment();
      ClaudeCore.current = () => ClaudeCore.builtin;
      expect(
        await start(env: {'ANTHROPIC_AUTH_TOKEN': 'token'}),
        isA<DartCoreTransport>(),
      );
    });

    test('the built-in core on none: tells user to add a provider or use agy', () async {
      environment(key: 'sk-user');
      ClaudeCore.current = () => ClaudeCore.builtin;
      await expectLater(
        startClaude(ClaudeLaunch(cwd: cwd)),
        throwsA(
          isA<ClaudeUnavailable>().having(
            (error) => error.message,
            'message',
            allOf(contains('Settings → Models'), contains('Antigravity CLI')),
          ),
        ),
      );
    });

    test('Antigravity CLI picked: starts AntigravityTransport', () async {
      environment();
      ClaudeCore.current = () => ClaudeCore.antigravity;
      expect(await start(), isA<AntigravityTransport>());
    });
  });
}
