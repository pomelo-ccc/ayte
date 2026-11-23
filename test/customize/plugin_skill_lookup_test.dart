import 'dart:convert';
import 'dart:io';

import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String home;
  late String configDir;
  late String projectDir;
  late CustomizationStore store;

  void writeFile(String path, String content) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('plugin_skill_lookup_');
    home = p.join(temp.path, 'home');
    configDir = p.join(home, '.gemini', 'config');
    projectDir = p.join(temp.path, 'repo');
    Directory(configDir).createSync(recursive: true);
    Directory(projectDir).createSync(recursive: true);
    store = CustomizationStore(configDir: configDir, homeDir: home);
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test(
    'resolves bare plugin skills by folder name and frontmatter name',
    () async {
      final contextSkill = p.join(
        configDir,
        'plugins',
        'agy-context',
        'skills',
        'context',
        'SKILL.md',
      );
      final chemblSkill = p.join(
        configDir,
        'plugins',
        'chemistry',
        'skills',
        'chembl_database',
        'SKILL.md',
      );
      final pubchemSkill = p.join(
        configDir,
        'plugins',
        'chemistry',
        'skills',
        'pubchem_database',
        'SKILL.md',
      );
      writeFile(
        p.join(configDir, 'plugins', 'agy-context', 'plugin.json'),
        jsonEncode({'name': 'agy-context'}),
      );
      writeFile(contextSkill, '---\nname: context\n---\nBody\n');
      writeFile(
        p.join(configDir, 'plugins', 'chemistry', 'plugin.json'),
        jsonEncode({'name': 'chemistry'}),
      );
      writeFile(chemblSkill, '---\nname: chembl-database\n---\nBody\n');
      writeFile(pubchemSkill, '---\nname: "pubchem-database"\n---\nBody\n');

      expect(await store.commandFile('context'), contextSkill);
      expect(await store.commandFile('/context'), contextSkill);
      expect(await store.commandFile('chembl-database'), chemblSkill);
      expect(await store.commandFile('chembl_database'), chemblSkill);
      expect(await store.commandFile('pubchem-database'), pubchemSkill);
    },
  );

  test(
    'resolves colon plugin:skill, plugin:command, and plugin:workflow by dirName or manifest name',
    () async {
      final pluginRoot = p.join(configDir, 'plugins', 'chem-pkg');
      final skillFile = p.join(
        pluginRoot,
        'skills',
        'chembl_database',
        'SKILL.md',
      );
      final cmdFile = p.join(pluginRoot, 'commands', 'git', 'ship.md');
      final wfFile = p.join(pluginRoot, 'workflows', 'release.md');
      writeFile(
        p.join(pluginRoot, 'plugin.json'),
        jsonEncode({'name': 'chemistry'}),
      );
      writeFile(skillFile, '---\nname: chembl-database\n---\n');
      writeFile(cmdFile, '---\ndescription: Ship it\n---\n');
      writeFile(wfFile, '---\ndescription: Release workflow\n---\n');

      // Plugin without plugin.json falls back to dirName
      final noManifestSkill = p.join(
        configDir,
        'plugins',
        'raw-plugin',
        'skills',
        'raw-skill',
        'SKILL.md',
      );
      writeFile(noManifestSkill, '---\nname: raw-alias\n---\n');

      expect(await store.commandFile('chem-pkg:chembl-database'), skillFile);
      expect(await store.commandFile('chemistry:chembl-database'), skillFile);
      expect(await store.commandFile('chemistry:chembl_database'), skillFile);
      expect(await store.commandFile('/chemistry:chembl-database'), skillFile);
      expect(await store.commandFile('chemistry:ship'), cmdFile);
      expect(await store.commandFile('chem-pkg:release'), wfFile);
      expect(await store.commandFile('raw-plugin:raw-alias'), noManifestSkill);
      expect(await store.commandFile('raw-plugin:raw-skill'), noManifestSkill);
      expect(await store.commandFile('chemistry:missing'), isNull);
    },
  );

  test(
    'excludes disabled plugins via disabledPlugins and plugins.<name>.enabled=false',
    () async {
      final disabledByDir = p.join(configDir, 'plugins', 'a-disabled-dir');
      final disabledByManifest = p.join(configDir, 'plugins', 'b-dir');
      final enabledPlugin = p.join(configDir, 'plugins', 'c-enabled');

      writeFile(
        p.join(configDir, 'config.json'),
        jsonEncode({
          'disabledPlugins': ['a-disabled-dir'],
          'plugins': {
            'manifest-off': {'enabled': false},
            'c-enabled': {'enabled': true},
          },
        }),
      );

      writeFile(
        p.join(disabledByDir, 'plugin.json'),
        jsonEncode({'name': 'alpha-off'}),
      );
      writeFile(
        p.join(disabledByDir, 'skills', 'shared', 'SKILL.md'),
        '---\nname: shared-skill\n---\n',
      );
      writeFile(
        p.join(disabledByDir, 'skills', 'only-off', 'SKILL.md'),
        '---\nname: only-off\n---\n',
      );

      writeFile(
        p.join(disabledByManifest, 'plugin.json'),
        jsonEncode({'name': 'manifest-off'}),
      );
      writeFile(
        p.join(disabledByManifest, 'commands', 'deploy.md'),
        'Disabled deploy\n',
      );

      final enabledSkill = p.join(
        enabledPlugin,
        'skills',
        'shared',
        'SKILL.md',
      );
      final enabledDeploy = p.join(enabledPlugin, 'workflows', 'deploy.md');
      writeFile(
        p.join(enabledPlugin, 'plugin.json'),
        jsonEncode({'name': 'c-enabled'}),
      );
      writeFile(enabledSkill, '---\nname: shared-skill\n---\n');
      writeFile(enabledDeploy, 'Enabled deploy workflow\n');

      // Disabled plugin items are excluded and do not shadow enabled plugins
      expect(await store.commandFile('only-off'), isNull);
      expect(await store.commandFile('a-disabled-dir:only-off'), isNull);
      expect(await store.commandFile('alpha-off:only-off'), isNull);
      expect(await store.commandFile('manifest-off:deploy'), isNull);
      expect(await store.commandFile('b-dir:deploy'), isNull);

      expect(await store.commandFile('shared-skill'), enabledSkill);
      expect(await store.commandFile('deploy'), enabledDeploy);

      final listedSkills = await store.list(CustomizationKind.skills);
      expect(
        listedSkills.map((s) => s.path).toList(),
        [enabledSkill],
      );

      // Disabled plugins' MCP servers and rules are also excluded.
      writeFile(
        p.join(disabledByDir, 'mcp_config.json'),
        jsonEncode({
          'mcpServers': {
            'alpha-srv': {'command': 'npx', 'args': ['alpha']},
          },
        }),
      );
      writeFile(
        p.join(disabledByDir, 'rules', 'alpha-rule.md'),
        '# Alpha disabled rule\n',
      );
      writeFile(
        p.join(disabledByManifest, 'mcp.json'),
        jsonEncode({
          'mcpServers': {
            'beta-srv': {'command': 'npx', 'args': ['beta']},
          },
        }),
      );
      writeFile(
        p.join(disabledByManifest, 'rules', 'beta-rule.md'),
        '# Beta disabled rule\n',
      );
      writeFile(
        p.join(enabledPlugin, 'mcp_config.json'),
        jsonEncode({
          'mcpServers': {
            'gamma-srv': {'command': 'npx', 'args': ['gamma']},
          },
        }),
      );
      writeFile(
        p.join(enabledPlugin, 'rules', 'gamma-rule.md'),
        '# Gamma enabled rule\n',
      );

      final listedMcps = await store.list(CustomizationKind.mcps);
      expect(listedMcps.map((m) => m.name).toList(), ['gamma-srv']);

      final listedRules = await store.list(CustomizationKind.rules);
      expect(
        listedRules.map((r) => r.name).toList(),
        [p.join('c-enabled', 'rules', 'gamma-rule.md')],
      );

      // Plugins tab still lists disabled plugins with enabled: false
      final listedPlugins = await store.list(CustomizationKind.plugins);
      final pluginEnabled = {
        for (final pl in listedPlugins) pl.name: pl.enabled,
      };
      expect(pluginEnabled['alpha-off'], isFalse);
      expect(pluginEnabled['manifest-off'], isFalse);
      expect(pluginEnabled['c-enabled'], isTrue);
    },
  );

  test(
    'enforces project > user > plugin precedence and .agent/.agents frontmatter lookup',
    () async {
      final projectAgentsSkill = p.join(
        projectDir,
        '.agents',
        'skills',
        'proj_folder',
        'SKILL.md',
      );
      final projectDotAgentSkill = p.join(
        projectDir,
        '.agent',
        'skills',
        'legacy_folder',
        'SKILL.md',
      );
      final userSkill = p.join(configDir, 'skills', 'proj_folder', 'SKILL.md');
      final userGlobalWorkflow = p.join(
        home,
        '.gemini',
        'antigravity',
        'global_workflows',
        'release.md',
      );
      final pluginSkill = p.join(
        configDir,
        'plugins',
        'p1',
        'skills',
        'proj_folder',
        'SKILL.md',
      );
      final pluginWorkflow = p.join(
        configDir,
        'plugins',
        'p1',
        'workflows',
        'release.md',
      );

      writeFile(projectAgentsSkill, '---\nname: custom-proj\n---\n');
      writeFile(projectDotAgentSkill, '---\nname: legacy-alias\n---\n');
      writeFile(userSkill, '---\nname: custom-proj\n---\n');
      writeFile(userGlobalWorkflow, 'User release\n');
      writeFile(pluginSkill, '---\nname: custom-proj\n---\n');
      writeFile(pluginWorkflow, 'Plugin release\n');

      // Project beats user and plugin even when user also defines custom-proj
      expect(
        await store.commandFile('custom-proj', project: projectDir),
        projectAgentsSkill,
      );
      expect(
        await store.commandFile('legacy-alias', project: projectDir),
        projectDotAgentSkill,
      );
      // Without project, user beats plugin
      expect(await store.commandFile('custom-proj'), userSkill);
      expect(await store.commandFile('release'), userGlobalWorkflow);
    },
  );

  test('skips broken symlink unreachable skills and rejects invalid names', () async {
    Directory(p.join(configDir, 'skills')).createSync(recursive: true);
    final deadLink = p.join(configDir, 'skills', 'dead-link');
    Link(deadLink).createSync(p.join(temp.path, 'does-not-exist'));

    final fallbackPluginSkill = p.join(
      configDir,
      'plugins',
      'p1',
      'skills',
      'dead-link',
      'SKILL.md',
    );
    writeFile(fallbackPluginSkill, '---\nname: dead-link\n---\n');

    // Does not return non-existent <dead-link>/SKILL.md; falls through to valid plugin skill
    expect(await store.commandFile('dead-link'), fallbackPluginSkill);

    // Invalid, built-in, and traversal names return null
    for (final invalid in const [
      '',
      '/',
      'compact',
      '.',
      '..',
      '.hidden',
      '../secret',
      'foo/bar',
      r'foo\bar',
      ':skill',
      'plugin:',
      'plugin:../secret',
      'plugin:.hidden',
      'plugin:sub:name',
      'bad\x00name',
    ]) {
      expect(await store.commandFile(invalid, project: projectDir), isNull);
    }
  });
}
