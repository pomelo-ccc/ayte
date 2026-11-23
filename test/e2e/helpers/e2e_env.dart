import 'dart:async';
import 'dart:io';

import 'package:baocode/acp/ayte_ipc_server.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_account_models.dart';
import 'package:baocode/kernel/antigravity/antigravity_accounts.dart';
import 'package:baocode/kernel/antigravity/antigravity_cli.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/claude_code/claude_settings_file.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_account_models.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_accounts.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_cli.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_transport.dart';
import 'package:baocode/kernel/commit_attribution.dart';
import 'package:baocode/kernel/extension_switches.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/usage/usage_ledger.dart';
import 'package:baocode/workspace/session_tools.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fake_cli_harness.dart';

/// Isolated temporary sandbox for opaque-box E2E tests.
///
/// Creates isolated `HOME`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`,
/// `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `VOLTA_HOME` (empty so `enrichedPath`
/// does not fall back to the host's `VOLTA_HOME`), `BAOCODE_DATA_DIR`,
/// `AYTE_DATA_DIR`, `AYTE_SESSION_DATA_PATH` (stripping legacy
/// `BAOCODE_CLAUDE_DATA_PATH`), and project workspace folders, snapshots all
/// relevant process-global statics, and restores everything in [dispose].
class E2eSandbox {
  E2eSandbox._({
    required this.rootDir,
    required this.homeDir,
    required this.appDataDir,
    required this.localAppDataDir,
    required this.dataDir,
    required this.sessionDataDir,
    required this.projectDir,
    required this._realHttp,
  }) : _savedDataDirectory = DataDirectory.current,
       _savedClaudeCoreCurrent = ClaudeCore.current,
       _savedAntigravityInstalled = ClaudeCore.antigravityInstalled,
       _savedKernelRegistry = List<KernelDescriptor>.of(KernelRegistry.all),
       _savedSessionToolsCurrent = SessionToolsSetting.current,
       _savedAntigravityPathCurrent = AntigravityPathSetting.current,
       _savedCodeBuddyPathCurrent = CodeBuddyPathSetting.current,
       _savedExtensionSwitchesCurrent = ExtensionSwitches.current,
       _savedExtensionSwitchesChanges = ExtensionSwitches.changes,
       _savedExtensionSwitchesSave = ExtensionSwitches.save,
       _savedCommitAttributionCurrent = CommitAttribution.current,
       _savedSdkGate = ClaudeSdkTools.gate,
       _savedModelProviders = ModelProviders.current,
       _savedUsageLedger = UsageLedger.current,
       _savedIpcHomeOverride = AyteIpcServer.instance.homeOverride,
       _savedClaudeSettingsParent = ClaudeSettingsFile.parent,
       _savedCodeBuddyModels = CodeBuddyModels.current,
       _savedAgyAccountSwitched = AntigravityAccounts.onActiveAccountSwitched,
       _savedCbAccountSwitched = CodeBuddyAccounts.onActiveAccountSwitched,
       _savedClaudeEnv = _activeClaudeEnv,
       _savedHttpOverrides = HttpOverrides.current,
       _sandboxUsageLedger = UsageLedger(MemoryUsageStorage()) {
    if (_realHttp) {
      HttpOverrides.global = null;
    }
    ClaudeSettingsFile.parent = rootDir;
    DataDirectory.current = DataDirectory(dataDir.path);
    CodeBuddyTransport.registry = CodeBuddyProcessRegistry(
      file: File(DataDirectory(dataDir.path).processRegistryFile('codebuddy')),
    );
    AyteIpcServer.instance.homeOverride = homeDir.path;
    UsageLedger.current = _sandboxUsageLedger;
    _activeClaudeEnv = processEnv;
    ClaudeEnvironment.use(processEnv);
  }

  /// Creates an isolated [E2eSandbox] and automatically registers [dispose]
  /// with `flutter_test`'s [addTearDown] when [autoTearDown] is true.
  factory E2eSandbox.create({
    bool realHttp = false,
    bool autoTearDown = true,
    String prefix = 'ayte_e2e_',
  }) {
    final root = Directory(
      Directory.systemTemp.createTempSync(prefix).resolveSymbolicLinksSync(),
    );
    final home = Directory(p.join(root.path, 'home'))
      ..createSync(recursive: true);
    for (final sub in const [
      '.claude',
      '.gemini/antigravity-cli',
      '.gemini/config',
      '.codebuddy',
      '.codex',
      '.ayte',
      '.cyte',
    ]) {
      Directory(p.join(home.path, sub)).createSync(recursive: true);
    }
    final appData = Directory(p.join(root.path, 'appdata'))
      ..createSync(recursive: true);
    final localAppData = Directory(p.join(root.path, 'localappdata'))
      ..createSync(recursive: true);
    final data = Directory(p.join(root.path, 'data'))
      ..createSync(recursive: true);
    final sessionData = Directory(p.join(root.path, 'session_data'))
      ..createSync(recursive: true);
    final project = Directory(p.join(root.path, 'project'))
      ..createSync(recursive: true);

    final sandbox = E2eSandbox._(
      rootDir: root,
      homeDir: home,
      appDataDir: appData,
      localAppDataDir: localAppData,
      dataDir: data,
      sessionDataDir: sessionData,
      projectDir: project,
      realHttp: realHttp,
    );
    if (autoTearDown) {
      addTearDown(sandbox.dispose);
    }
    return sandbox;
  }

  static Map<String, String>? _activeClaudeEnv;

  final Directory rootDir;
  final Directory homeDir;
  final Directory appDataDir;
  final Directory localAppDataDir;
  final Directory dataDir;
  final Directory sessionDataDir;
  final Directory projectDir;

  final bool _realHttp;
  final DataDirectory _savedDataDirectory;
  final ClaudeCore Function() _savedClaudeCoreCurrent;
  final bool Function() _savedAntigravityInstalled;
  final List<KernelDescriptor> _savedKernelRegistry;
  final bool Function() _savedSessionToolsCurrent;
  final String? Function() _savedAntigravityPathCurrent;
  final String? Function() _savedCodeBuddyPathCurrent;
  final ExtensionSwitches Function() _savedExtensionSwitchesCurrent;
  final Listenable? _savedExtensionSwitchesChanges;
  final Future<void> Function(ExtensionSwitches)? _savedExtensionSwitchesSave;
  final CommitAttribution Function() _savedCommitAttributionCurrent;
  final ClaudeSdkGate? _savedSdkGate;
  final ModelProviders _savedModelProviders;
  final UsageLedger _savedUsageLedger;
  final UsageLedger _sandboxUsageLedger;
  final String? _savedIpcHomeOverride;
  final Directory? _savedClaudeSettingsParent;
  final List<CodeBuddyModel> _savedCodeBuddyModels;
  final FutureOr<void> Function(AntigravityAccount)? _savedAgyAccountSwitched;
  final FutureOr<void> Function(CodeBuddyAccount?)? _savedCbAccountSwitched;
  final Map<String, String>? _savedClaudeEnv;
  final HttpOverrides? _savedHttpOverrides;

  final Set<String> _registeredTools = {};
  final Set<String> _registeredFeatures = {};
  final List<FutureOr<void> Function()> _extraCleanups = [];
  bool _disposed = false;

  /// Isolated environment map for child CLI processes.
  ///
  /// Sets BOTH `HOME` and `USERPROFILE` so libraries checking either variable on
  /// Windows stay strictly inside [homeDir].
  Map<String, String> get processEnv => {
    ...Platform.environment,
    'HOME': homeDir.path,
    'USERPROFILE': homeDir.path,
    'APPDATA': appDataDir.path,
    'LOCALAPPDATA': localAppDataDir.path,
    'CLAUDE_CONFIG_DIR': p.join(homeDir.path, '.claude'),
    'CODEX_HOME': p.join(homeDir.path, '.codex'),
    'VOLTA_HOME': '',
    'BAOCODE_DATA_DIR': dataDir.path,
    'AYTE_DATA_DIR': dataDir.path,
    'AYTE_SESSION_DATA_PATH': sessionDataDir.path,
  }..remove('BAOCODE_CLAUDE_DATA_PATH');

  /// Overrides [ClaudeEnvironment] for this sandbox and restores the prior
  /// E2E environment on [dispose].
  void useClaudeEnvironment(Map<String, String> env) {
    _activeClaudeEnv = env;
    ClaudeEnvironment.use(env);
  }

  /// Creates an in-memory [ModelProviders] store without touching disk.
  ModelProviders memoryProviders([
    List<ModelProvider> providers = const [],
  ]) => ModelProviders.memory(providers: providers);

  /// Registers [tool] into [ClaudeSdkTools] and automatically unregisters it
  /// on [dispose].
  void registerSdkTool(ClaudeSdkTool tool) {
    _registeredTools.add(tool.name);
    ClaudeSdkTools.register(tool);
  }

  /// Sets [ClaudeSdkTools.instruct] for [feature] and clears it on [dispose].
  void instructSdkFeature(String feature, String? text) {
    _registeredFeatures.add(feature);
    ClaudeSdkTools.instruct(feature, text);
  }

  /// Registers an additional cleanup callback executed during [dispose].
  void onDispose(FutureOr<void> Function() cleanup) {
    _extraCleanups.add(cleanup);
  }

  /// Stops live transports, reaps tracked fake CLI PIDs, cancels sandbox timers,
  /// restores all snapshotted statics, and deletes [rootDir].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    for (final cleanup in _extraCleanups.reversed) {
      try {
        await cleanup();
      } on Object {
        // Best-effort teardown.
      }
    }

    try {
      await CodeBuddyTransport.stopAll().timeout(
        const Duration(seconds: 4),
        onTimeout: () {},
      );
    } on Object {
      // Best-effort teardown.
    }
    try {
      await AntigravityTransport.stopAll();
    } on Object {
      // Best-effort teardown.
    }

    try {
      await FakeCliExecutable.terminateRecordedPids(rootDir);
    } on Object {
      // Best-effort teardown.
    }

    try {
      await CodeBuddyTransport.registry.flush().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    } on Object {
      // Best-effort teardown.
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    for (final name in _registeredTools) {
      ClaudeSdkTools.unregister(name);
    }
    for (final feature in _registeredFeatures) {
      ClaudeSdkTools.instruct(feature, null);
    }

    if (!identical(UsageLedger.current, _savedUsageLedger) &&
        !identical(UsageLedger.current, _sandboxUsageLedger)) {
      UsageLedger.current.dispose();
    }
    _sandboxUsageLedger.dispose();

    DataDirectory.current = _savedDataDirectory;
    ClaudeCore.current = _savedClaudeCoreCurrent;
    ClaudeCore.antigravityInstalled = _savedAntigravityInstalled;
    KernelRegistry.use(_savedKernelRegistry);
    SessionToolsSetting.current = _savedSessionToolsCurrent;
    AntigravityPathSetting.current = _savedAntigravityPathCurrent;
    CodeBuddyPathSetting.current = _savedCodeBuddyPathCurrent;
    ExtensionSwitches.current = _savedExtensionSwitchesCurrent;
    ExtensionSwitches.changes = _savedExtensionSwitchesChanges;
    ExtensionSwitches.save = _savedExtensionSwitchesSave;
    CommitAttribution.current = _savedCommitAttributionCurrent;
    ClaudeSdkTools.gate = _savedSdkGate;
    ModelProviders.current = _savedModelProviders;
    UsageLedger.current = _savedUsageLedger;
    AyteIpcServer.instance.homeOverride = _savedIpcHomeOverride;
    ClaudeSettingsFile.parent = _savedClaudeSettingsParent;
    CodeBuddyTransport.registry = CodeBuddyProcessRegistry(
      file: File(_savedDataDirectory.processRegistryFile('codebuddy')),
    );
    if (!identical(CodeBuddyModels.current, _savedCodeBuddyModels)) {
      CodeBuddyModels.syncForRegion(
        identical(_savedCodeBuddyModels, CodeBuddyModels.globalDefaults)
            ? CodeBuddyRegion.global
            : CodeBuddyRegion.cn,
      );
    }
    AntigravityAccounts.onActiveAccountSwitched = _savedAgyAccountSwitched;
    CodeBuddyAccounts.onActiveAccountSwitched = _savedCbAccountSwitched;
    _activeClaudeEnv = _savedClaudeEnv;
    ClaudeEnvironment.use(_savedClaudeEnv);
    if (_realHttp) {
      HttpOverrides.global = _savedHttpOverrides;
    }

    Object? lastError;
    for (var attempt = 0; attempt < 15; attempt++) {
      if (!rootDir.existsSync()) return;
      try {
        await rootDir.delete(recursive: true);
        lastError = null;
        break;
      } on FileSystemException catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(milliseconds: 20 * (attempt + 1)));
      }
    }
    if (rootDir.existsSync()) {
      throw StateError(
        'E2eSandbox.dispose failed to delete ${rootDir.path}: $lastError',
      );
    }
  }
}
