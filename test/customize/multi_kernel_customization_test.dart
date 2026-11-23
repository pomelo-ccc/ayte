import 'dart:convert';
import 'dart:io';

import 'package:baocode/customize/customization_disk.dart';
import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:baocode/kernel/extension_switches.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _MemoryPosixDisk implements CustomizationDisk {
  _MemoryPosixDisk(this.files, {required this.home, required this.config});

  final Map<String, String> files;
  final String home;
  final String config;

  @override
  bool get isLocal => false;

  @override
  p.Context get paths => p.posix;

  @override
  Future<String> configDir() async => config;

  @override
  Future<String?> homeDir() async => home;

  @override
  Future<String?> read(String path) async => files[p.posix.normalize(path)];

  @override
  Future<List<({String path, bool directory})>> children(
    String directory,
  ) async {
    final norm = p.posix.normalize(directory);
    final prefix = norm == '/' ? '/' : '$norm/';
    final seen = <String, bool>{};
    for (final key in files.keys) {
      if (!key.startsWith(prefix)) continue;
      final rest = key.substring(prefix.length);
      if (rest.isEmpty) continue;
      final slash = rest.indexOf('/');
      if (slash < 0) {
        seen[key] = false;
      } else {
        seen['$prefix${rest.substring(0, slash)}'] = true;
      }
    }
    return [
      for (final entry in seen.entries) (path: entry.key, directory: entry.value),
    ];
  }

  @override
  Future<bool?> isDirectory(String path) async {
    final norm = p.posix.normalize(path);
    if (files.containsKey(norm)) return false;
    final prefix = norm == '/' ? '/' : '$norm/';
    if (files.keys.any((k) => k.startsWith(prefix))) return true;
    return null;
  }

  @override
  Future<void> write(String path, String text) async {
    files[p.posix.normalize(path)] = text;
  }

  @override
  Future<void> delete(String path) async {
    final norm = p.posix.normalize(path);
    files.remove(norm);
    final prefix = '$norm/';
    files.removeWhere((k, _) => k.startsWith(prefix));
  }
}

void main() {
  late Directory temp;
  late String home;
  late String agyConfig;
  late String project;
  late CustomizationStore store;

  void writeFile(String path, String content) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('multi_kernel_custom_');
    home = p.join(temp.path, 'home');
    agyConfig = p.join(home, '.gemini', 'config');
    project = p.join(temp.path, 'workspace');
    Directory(agyConfig).createSync(recursive: true);
    Directory(project).createSync(recursive: true);
    store = CustomizationStore(configDir: agyConfig, homeDir: home);
  });

  tearDown(() {
    ExtensionSwitches.current = () => ExtensionSwitches.none;
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('aggregates skills, subagents, commands, rules, and memory across all 4 kernels', () async {
    // Antigravity
    writeFile(
      p.join(agyConfig, 'skills', 'agy-skill', 'SKILL.md'),
      '---\nname: agy-skill\ndescription: Agy skill\n---\n',
    );
    writeFile(p.join(agyConfig, 'GEMINI.md'), 'Agy global rule\n');
    writeFile(p.join(project, '.agents', 'rules', 'repo.md'), 'Repo rule\n');

    // Claude Code
    writeFile(
      p.join(home, '.claude', 'skills', 'claude-skill', 'SKILL.md'),
      '---\nname: claude-skill\ndescription: Claude skill\n---\n',
    );
    writeFile(
      p.join(home, '.claude', 'skills', 'synced', 'b1', 'synced-skill', 'SKILL.md'),
      '---\nname: synced-skill\n---\n',
    );
    writeFile(
      p.join(home, '.claude', 'agents', 'claude-agent.md'),
      '---\nname: claude-agent\n---\n',
    );
    writeFile(
      p.join(project, '.claude', 'commands', 'ship.md'),
      'Ship via Claude\n',
    );
    writeFile(p.join(project, 'CLAUDE.md'), 'Claude project rule\n');
    writeFile(
      p.join(home, '.claude', 'projects', claudeProjectDirName(project), 'memory', 'notes.md'),
      'Remember Claude notes\n',
    );

    // CodeBuddy
    writeFile(
      p.join(home, '.codebuddy', 'skills', 'cb-skill', 'SKILL.md'),
      '---\nname: cb-skill\n---\n',
    );
    writeFile(
      p.join(project, '.codebuddy', 'agents', 'cb-agent.md'),
      '---\nname: cb-agent\n---\n',
    );
    writeFile(p.join(home, '.codebuddy', 'CODEBUDDY.md'), 'CodeBuddy rule\n');
    writeFile(
      p.join(home, '.codebuddy', 'projects', claudeProjectDirName(project), 'memory', 'cb.md'),
      'CodeBuddy memory\n',
    );

    // Codex
    writeFile(
      p.join(home, '.codex', 'skills', 'codex-skill', 'SKILL.md'),
      '---\nname: codex-skill\n---\n',
    );
    writeFile(p.join(home, '.codex', 'AGENTS.override.md'), 'Codex override\n');
    writeFile(p.join(project, '.codex', 'skills', 'proj-codex', 'SKILL.md'), 'Body\n');

    final skills = await store.list(CustomizationKind.skills, project: project);
    expect(
      skills.map((s) => (s.scope, s.name)).toSet(),
      containsAll({
        (CustomizationScope.user, 'agy-skill'),
        (CustomizationScope.user, 'claude-skill'),
        (CustomizationScope.user, 'cb-skill'),
        (CustomizationScope.user, 'codex-skill'),
        (CustomizationScope.synced, 'synced-skill'),
        (CustomizationScope.project, 'proj-codex'),
      }),
    );

    final subagents = await store.list(CustomizationKind.subagents, project: project);
    expect(
      subagents.map((s) => s.name),
      containsAll(['claude-agent', 'cb-agent']),
    );

    final commands = await store.list(CustomizationKind.commands, project: project);
    expect(commands.map((c) => c.name), contains('/ship'));

    final rules = await store.list(CustomizationKind.rules, project: project);
    expect(
      rules.map((r) => r.name).toSet(),
      containsAll([
        'GEMINI.md',
        'CODEBUDDY.md',
        'AGENTS.override.md',
        'CLAUDE.md',
        p.join('.agents', 'rules', 'repo.md'),
      ]),
    );

    final memories = await store.list(CustomizationKind.memory, project: project);
    expect(memories.map((m) => m.name).toSet(), {'notes.md', 'cb.md'});
  });

  test('parses Codex TOML [mcp_servers.*] alongside Antigravity, Claude, and CodeBuddy MCPs & hooks', () async {
    writeFile(
      p.join(agyConfig, 'mcp_config.json'),
      jsonEncode({
        'mcpServers': {
          'agy-fs': {'command': 'npx', 'args': ['fs-mcp']},
        },
      }),
    );
    writeFile(
      p.join(home, '.claude.json'),
      jsonEncode({
        'mcpServers': {
          'claude-gh': {'type': 'http', 'url': 'https://gh.example/mcp'},
        },
        'claudeAiMcpEverConnected': ['claude.ai Docs'],
        'projects': {
          project: {
            'mcpServers': {
              'local-db': {'command': 'sqlite-mcp'},
            },
          },
        },
      }),
    );
    writeFile(
      p.join(home, '.codebuddy', 'mcp.json'),
      jsonEncode({
        'mcpServers': {
          'cb-mcp': {'command': 'cb-server'},
        },
      }),
    );
    writeFile(
      p.join(home, '.codex', 'config.toml'),
      '''
# Top comment
model = "gpt-5"

[mcp_servers.context7]
command = "npx"
args = [
  "-y",
  "@upstash/context7-mcp", # inline comment
]
enabled = false

[mcp_servers.context7.env]
API_KEY = "tok#1"

[mcp_servers."my.remote"]
url = "https://remote.example/mcp"
''',
    );
    writeFile(
      p.join(project, '.codex', 'config.toml'),
      '''
[mcp_servers.proj_codex]
command = "python"
args = ["-m", "mcp_srv"]
''',
    );
    writeFile(
      p.join(project, '.codebuddy', 'settings.json'),
      jsonEncode({
        'hooks': {
          'PreToolUse': [
            {
              'matcher': 'Bash',
              'hooks': [
                {'type': 'command', 'command': 'check.sh'},
              ],
            },
          ],
        },
      }),
    );

    final mcps = await store.list(CustomizationKind.mcps, project: project);
    final byName = {for (final m in mcps) m.name: m};
    expect(byName.keys, containsAll([
      'agy-fs',
      'claude-gh',
      'claude.ai Docs',
      'local-db',
      'cb-mcp',
      'context7',
      'my.remote',
      'proj_codex',
    ]));
    expect(byName['context7']!.enabled, isFalse);
    expect(byName['context7']!.description, 'npx -y @upstash/context7-mcp');
    expect(byName['context7']!.server?['env'], {'API_KEY': 'tok#1'});
    expect(byName['my.remote']!.description, 'https://remote.example/mcp');
    expect(byName['proj_codex']!.scope, CustomizationScope.project);

    final hooks = await store.list(CustomizationKind.hooks, project: project);
    expect(hooks.single.name, 'PreToolUse · Bash');
    expect(hooks.single.description, 'check.sh');
  });

  test('ExtensionSwitches trims names, optimizes equality/hashCode, and filters commandFile', () async {
    final skillFile = p.join(agyConfig, 'skills', 'deploy-app', 'SKILL.md');
    writeFile(skillFile, '---\nname: deploy-app\n---\nDeploy\n');
    final otherSkill = p.join(agyConfig, 'skills', 'lint-app', 'SKILL.md');
    writeFile(otherSkill, '---\nname: lint-app\n---\nLint\n');

    final parsed = ExtensionSwitches.parse(const {
      ExtensionSwitches.skillsKey: ['  deploy-app  ', '   ', 42],
      ExtensionSwitches.serversKey: [' claude.ai Docs ', ''],
      ExtensionSwitches.toolsKey: {
        ' git ': [' push ', '   '],
        '   ': ['ignored'],
      },
    });
    expect(parsed.disabledSkills, {'deploy-app'});
    expect(parsed.disabledServers, {'claude.ai Docs'});
    expect(parsed.disabledTools, {'git': {'push'}});

    const equivalent = ExtensionSwitches(
      disabledSkills: {'deploy-app'},
      disabledServers: {'claude.ai Docs'},
      disabledTools: {'git': {'push'}},
    );
    expect(parsed, equivalent);
    expect(parsed.hashCode, equivalent.hashCode);

    expect(parsed.matchesServerDisabled('claude.ai Docs'), isTrue);
    expect(parsed.matchesServerDisabled('claude_ai_Docs'), isTrue);
    expect(parsed.matchesServerDisabled('other'), isFalse);
    expect(parsed.matchesSkillDisabled('/deploy-app'), isTrue);
    expect(parsed.codexMcpOverrides, {'claude.ai Docs': false});

    expect(
      parsed.allowsCustomization(
        const Customization(
          kind: CustomizationKind.skills,
          scope: CustomizationScope.user,
          name: 'deploy-app',
          path: '/a',
        ),
      ),
      isFalse,
    );
    expect(
      parsed.allowsCustomization(
        const Customization(
          kind: CustomizationKind.mcps,
          scope: CustomizationScope.user,
          name: 'claude_ai_Docs',
          path: '/b',
        ),
      ),
      isFalse,
    );

    ExtensionSwitches.current = () => parsed;
    expect(await store.commandFile('deploy-app'), isNull);
    expect(await store.commandFile('lint-app'), otherSkill);

    final filtered = parsed.filterEnabled([
      const Customization(
        kind: CustomizationKind.skills,
        scope: CustomizationScope.user,
        name: 'deploy-app',
        path: '/a',
      ),
      const Customization(
        kind: CustomizationKind.skills,
        scope: CustomizationScope.user,
        name: 'lint-app',
        path: '/b',
      ),
      const Customization(
        kind: CustomizationKind.mcps,
        scope: CustomizationScope.user,
        name: 'context7',
        path: '/c',
        enabled: false,
      ),
    ]);
    expect(filtered.map((c) => c.name).toList(), ['lint-app']);
  });

  test('supports CodeBuddy plugins, Codex inline TOML tables, and kernel-specific configFile/create scopes', () async {
    final cbConfig = p.join(home, '.codebuddy');
    writeFile(
      p.join(cbConfig, 'plugins', 'cb-tools', 'plugin.json'),
      jsonEncode({'name': 'cb-tools', 'version': '2.0.0'}),
    );
    final cbSkill = p.join(
      cbConfig,
      'plugins',
      'cb-tools',
      'skills',
      'audit',
      'SKILL.md',
    );
    writeFile(cbSkill, '---\nname: cb-audit\n---\nAudit\n');
    writeFile(
      p.join(home, '.codex', 'config.toml'),
      '''
[mcp_servers.inline_srv]
command = "node"
args = ["srv.js",]
env = { MODE = "prod", PORT = "8080" }
''',
    );

    final cbStore = CustomizationStore(configDir: cbConfig, homeDir: home);
    expect(await cbStore.commandFile('cb-tools:cb-audit'), cbSkill);
    expect(
      await cbStore.configFile(CustomizationKind.mcps, CustomizationScope.project, project: project),
      p.join(project, '.codebuddy', 'mcp.json'),
    );
    expect(
      await cbStore.configFile(CustomizationKind.hooks, CustomizationScope.local, project: project),
      p.join(project, '.codebuddy', 'settings.local.json'),
    );

    final created = await cbStore.create(
      CustomizationKind.rules,
      CustomizationScope.project,
      'style',
      project: project,
    );
    expect(created, p.join(project, '.codebuddy', 'rules', 'style.md'));

    final mcps = await cbStore.list(CustomizationKind.mcps, project: project);
    final inlineSrv = mcps.singleWhere((m) => m.name == 'inline_srv');
    expect(inlineSrv.server?['args'], ['srv.js']);
    expect(inlineSrv.server?['env'], {'MODE': 'prod', 'PORT': '8080'});
  });

  test('handles malformed Codex TOML brackets, dotted subkeys, POSIX trailing slashes, skill vs command precedence, and ExtensionSwitches trimming/folder matching', () async {
    // D-04 & D-05: Malformed unclosed TOML lines + dotted subkeys
    writeFile(
      p.join(home, '.codex', 'config.toml'),
      '''
[mcp_servers.broken_unclosed]
args = ["unclosed

[mcp_servers.broken_array]
args = [
  "one",

[mcp_servers.after_broken]
command = "node"

[mcp_servers.dotted]
url = "https://dotted.example/mcp"
env.TOKEN = "secret"
headers."X-Api-Key" = "val"
''',
    );
    final mcps = await store.list(CustomizationKind.mcps);
    final byName = {for (final m in mcps) m.name: m};
    expect(byName.keys, containsAll(['broken_unclosed', 'broken_array', 'after_broken', 'dotted']));
    expect(byName['after_broken']!.server?['command'], 'node');
    expect(byName['dotted']!.server?['env'], {'TOKEN': 'secret'});
    expect(byName['dotted']!.server?['headers'], {'X-Api-Key': 'val'});

    // D-06: POSIX ~/.claude.json projects trailing slash normalization + case sensitivity
    final posixDisk = _MemoryPosixDisk(
      {
        '/home/alice/.claude.json': jsonEncode({
          'projects': {
            '/home/alice/proj/': {
              'mcpServers': {
                'local_posix_mcp': {'command': 'posix-srv'},
              },
            },
          },
        }),
      },
      home: '/home/alice',
      config: '/home/alice/.claude',
    );
    final posixStore = CustomizationStore(
      configDir: '/home/alice/.claude',
      homeDir: '/home/alice',
      disk: posixDisk,
    );
    final posixMcps = await posixStore.list(
      CustomizationKind.mcps,
      project: '/home/alice/proj',
    );
    expect(posixMcps.map((m) => m.name), contains('local_posix_mcp'));
    final wrongCaseMcps = await posixStore.list(
      CustomizationKind.mcps,
      project: '/Home/Alice/Proj',
    );
    expect(wrongCaseMcps.map((m) => m.name), isNot(contains('local_posix_mcp')));

    // D-07: commandFile does not block .claude/commands/review.md or plugin:command when skill 'review' is disabled
    final reviewCmd = p.join(project, '.claude', 'commands', 'review.md');
    writeFile(reviewCmd, 'Project review command\n');
    final reviewSkill = p.join(agyConfig, 'skills', 'review', 'SKILL.md');
    writeFile(reviewSkill, '---\nname: review\n---\nSkill body\n');
    writeFile(
      p.join(agyConfig, 'plugins', 'myplug', 'plugin.json'),
      jsonEncode({'name': 'myplug'}),
    );
    final plugReviewCmd = p.join(
      agyConfig,
      'plugins',
      'myplug',
      'commands',
      'review.md',
    );
    writeFile(plugReviewCmd, 'Plugin review command\n');

    ExtensionSwitches.current = () =>
        const ExtensionSwitches(disabledSkills: {'review'});
    expect(await store.commandFile('review', project: project), reviewCmd);
    expect(await store.commandFile('myplug:review'), plugReviewCmd);

    // D-08: allowsCustomization checks skill folderName on both POSIX and Windows paths
    const folderSwitches = ExtensionSwitches(disabledSkills: {'dir_s1'});
    expect(
      folderSwitches.allowsCustomization(
        const Customization(
          kind: CustomizationKind.skills,
          scope: CustomizationScope.plugin,
          name: 's1',
          path: 'plugins/on-plug/skills/dir_s1/SKILL.md',
        ),
      ),
      isFalse,
    );
    expect(
      folderSwitches.allowsCustomization(
        const Customization(
          kind: CustomizationKind.skills,
          scope: CustomizationScope.plugin,
          name: 's1',
          path: r'C:\Users\alice\.gemini\config\plugins\on-plug\skills\dir_s1\SKILL.md',
        ),
      ),
      isFalse,
    );

    // D-09: withSkills / withServer / withTool trim whitespace and ignore empty entries
    final mutated = ExtensionSwitches.none
        .withServer('  claude.ai Docs  ', false)
        .withServer('   ', false)
        .withSkills(['  deploy-app  ', '  ', ''], false)
        .withTool('  git  ', '  push  ', false)
        .withTool('  ', 'ignored', false)
        .withTool('git', '   ', false);
    expect(mutated.serverEnabled('claude.ai Docs'), isFalse);
    expect(mutated.skillEnabled('deploy-app'), isFalse);
    expect(mutated.toolEnabled('git', 'push'), isFalse);
    expect(mutated.disabledServers, {'claude.ai Docs'});
    expect(mutated.disabledSkills, {'deploy-app'});
    expect(mutated.disabledTools, {
      'git': {'push'},
    });
    expect(ExtensionSwitches.parse(mutated.toSettings()), mutated);

    final reenabled = mutated
        .withServer(' claude.ai Docs ', true)
        .withSkills([' deploy-app '], true)
        .withTool(' git ', ' push ', true);
    expect(reenabled, ExtensionSwitches.none);
  });

  test('CustomizationStore.list enforces ExtensionSwitches on skills and MCPs while preserving metadata', () async {
    final disabledSkillPath = p.join(agyConfig, 'skills', 'disabled-skill', 'SKILL.md');
    writeFile(
      disabledSkillPath,
      '---\nname: disabled-skill\ndescription: Disabled skill desc\n---\nBody\n',
    );
    writeFile(
      p.join(agyConfig, 'skills', 'folder-match-skill', 'SKILL.md'),
      '---\nname: display-alias\ndescription: Folder matched skill\n---\nBody\n',
    );
    writeFile(
      p.join(agyConfig, 'skills', 'active-skill', 'SKILL.md'),
      '---\nname: active-skill\ndescription: Active skill desc\n---\nBody\n',
    );

    final mcpConfigPath = p.join(agyConfig, 'mcp_config.json');
    writeFile(
      mcpConfigPath,
      jsonEncode({
        'mcpServers': {
          'disabled-mcp': {'command': 'npx', 'args': ['a']},
          'active-mcp': {'command': 'npx', 'args': ['b']},
        },
      }),
    );
    writeFile(
      p.join(home, '.claude.json'),
      jsonEncode({
        'claudeAiMcpEverConnected': ['claude.ai Docs'],
      }),
    );
    writeFile(
      p.join(home, '.codex', 'config.toml'),
      '''
[mcp_servers.codex-active]
command = "node"
''',
    );

    ExtensionSwitches.current = () => const ExtensionSwitches(
      disabledSkills: {'disabled-skill', 'folder-match-skill'},
      disabledServers: {'disabled-mcp', 'claude_ai_Docs'},
    );

    final skills = await store.list(CustomizationKind.skills, project: project);
    final skillByName = {for (final s in skills) s.name: s};
    final disabledSkill = skillByName['disabled-skill']!;
    expect(disabledSkill.enabled, isFalse);
    expect(disabledSkill.path, disabledSkillPath);
    expect(disabledSkill.description, 'Disabled skill desc');
    expect(disabledSkill.scope, CustomizationScope.user);
    expect(disabledSkill.editable, isTrue);
    expect(disabledSkill.removePath, p.dirname(disabledSkillPath));
    expect(skillByName['display-alias']!.enabled, isFalse);
    expect(skillByName['active-skill']!.enabled, isNot(false));

    final mcps = await store.list(CustomizationKind.mcps, project: project);
    final mcpByName = {for (final m in mcps) m.name: m};
    final disabledMcp = mcpByName['disabled-mcp']!;
    expect(disabledMcp.enabled, isFalse);
    expect(disabledMcp.path, mcpConfigPath);
    expect(disabledMcp.description, 'npx a');
    expect(disabledMcp.scope, CustomizationScope.user);
    expect(disabledMcp.editable, isTrue);
    expect(disabledMcp.server, {'command': 'npx', 'args': ['a']});
    expect(mcpByName['claude.ai Docs']!.enabled, isFalse);
    expect(mcpByName['claude.ai Docs']!.scope, CustomizationScope.synced);
    expect(mcpByName['active-mcp']!.enabled, isNot(false));
    expect(mcpByName['codex-active']!.enabled, isNot(false));

    ExtensionSwitches.current = () => ExtensionSwitches.none;
    final reenabledSkills = {
      for (final s in await store.list(CustomizationKind.skills, project: project))
        s.name: s,
    };
    final reenabledMcps = {
      for (final m in await store.list(CustomizationKind.mcps, project: project))
        m.name: m,
    };
    expect(reenabledSkills['disabled-skill']!.enabled, isNot(false));
    expect(reenabledSkills['display-alias']!.enabled, isNot(false));
    expect(reenabledMcps['disabled-mcp']!.enabled, isNot(false));
    expect(reenabledMcps['claude.ai Docs']!.enabled, isNot(false));
  });

  test('CustomizationStore.list marks plugin:skill disabled in ExtensionSwitches while leaving sibling plugins enabled', () async {
    // Directory plugin (dirName 'my-plug-dir', manifest name 'my-plug')
    final plugDir = p.join(agyConfig, 'plugins', 'my-plug-dir');
    writeFile(
      p.join(plugDir, 'plugin.json'),
      jsonEncode({'name': 'my-plug'}),
    );
    final dirPlugSkill = p.join(plugDir, 'skills', 'plug-folder', 'SKILL.md');
    writeFile(dirPlugSkill, '---\nname: plug-skill\ndescription: Dir plugin skill\n---\n');

    // Sibling plugin sharing skill name 'plug-skill' (must remain enabled)
    final siblingDir = p.join(agyConfig, 'plugins', 'other-plug');
    writeFile(
      p.join(siblingDir, 'plugin.json'),
      jsonEncode({'name': 'other-plug'}),
    );
    final siblingSkill = p.join(siblingDir, 'skills', 'other-folder', 'SKILL.md');
    writeFile(siblingSkill, '---\nname: plug-skill\ndescription: Other plugin skill\n---\n');

    // Claude installed_plugins.json plugin (cache path unrelated to pluginKey)
    final claudeRoot = p.join(home, '.claude');
    final cfInstall = p.join(claudeRoot, 'plugins', 'cache', 'cf-cache');
    final cfSkill = p.join(cfInstall, 'skills', 'cf-folder', 'SKILL.md');
    writeFile(cfSkill, '---\nname: cf-skill\ndescription: CF skill\n---\n');
    writeFile(
      p.join(claudeRoot, 'plugins', 'installed_plugins.json'),
      jsonEncode({
        'version': 2,
        'plugins': {
          'cloudflare@market': [
            {'scope': 'user', 'installPath': cfInstall, 'version': '1.0.0'},
          ],
        },
      }),
    );

    ExtensionSwitches.current = () => const ExtensionSwitches(
      disabledSkills: {'my-plug:plug-skill', 'cloudflare:cf-folder'},
    );

    final skills = await store.list(CustomizationKind.skills);
    final byPath = {for (final s in skills) s.path: s};
    expect(byPath[dirPlugSkill]!.enabled, isFalse);
    expect(byPath[dirPlugSkill]!.description, 'Dir plugin skill');
    expect(byPath[cfSkill]!.enabled, isFalse);
    expect(byPath[siblingSkill]!.enabled, isNot(false));

    expect(await store.commandFile('my-plug:plug-skill'), isNull);
    expect(await store.commandFile('my-plug-dir:plug-skill'), isNull);
    expect(await store.commandFile('cloudflare:cf-skill'), isNull);
    expect(await store.commandFile('other-plug:plug-skill'), siblingSkill);
    expect(await store.commandFile('plug-skill'), siblingSkill);

    // Alias-clearing helpers on ExtensionSwitches
    final clearedSkills = ExtensionSwitches.current()
        .withSkillMatched(
          'plug-skill',
          true,
          folderName: 'plug-folder',
          pluginNames: const {'my-plug', 'my-plug-dir'},
        )
        .withSkillMatched(
          'cf-skill',
          true,
          folderName: 'cf-folder',
          pluginNames: const {'cloudflare', 'cloudflare@market'},
        );
    expect(clearedSkills.disabledSkills, isEmpty);

    const normMcp = ExtensionSwitches(disabledServers: {'claude_ai_Docs'});
    expect(normMcp.withServer('claude.ai Docs', true).disabledServers, isEmpty);
  });
}
