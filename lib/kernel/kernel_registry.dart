import 'package:flutter/material.dart';

import 'agent_kernel.dart';
import 'antigravity/antigravity_catalog.dart';
import 'antigravity/antigravity_cli.dart' show antigravityBuiltinProviderId;
import 'claude_code/claude_code_kernel.dart';
import 'codebuddy/codebuddy_cli.dart' show codebuddyBuiltinProviderId;
import 'codex/codex_catalog.dart';
import 'codex/codex_kernel.dart';
import 'codex/codex_process_transport.dart';
import '../remote/remote_claude.dart';

/// Native kernel ids offered directly in Ayte.
const claudeCodeKernelId = 'claude-code';
const codexKernelId = 'codex';

/// The four native kernels directly selectable in Ayte:
/// Antigravity (`agy`), CodeBuddy (`codebuddy`), Claude Code (`claude`),
/// and Codex (`codex`).
abstract final class KernelRegistry {
  static final KernelDescriptor antigravity = KernelDescriptor(
    id: antigravityBuiltinProviderId,
    label: 'Antigravity',
    icon: Icons.rocket_launch_rounded,
    description: 'Google Antigravity CLI (agy)',
    create: (context) => ClaudeCodeKernel(
      antigravity,
      context,
      start: startAntigravitySession,
      readHistory: readClaudeHistory,
      readHistoryPage: readClaudeHistoryPage,
      readGoal: readClaudeGoal,
      forkSession: forkClaudeSession,
      usageOffBy: () => claudeUsageOffByAt(context.cwd),
      rejectTooOld: rejectTooOldClaude,
    ),
    catalog: const AntigravityCatalog(),
  );

  static final KernelDescriptor codebuddy = KernelDescriptor(
    id: codebuddyBuiltinProviderId,
    label: 'CodeBuddy',
    icon: Icons.auto_awesome_rounded,
    description: 'Tencent CodeBuddy Code CLI (codebuddy)',
    create: (context) => ClaudeCodeKernel(
      codebuddy,
      context,
      start: startCodeBuddySession,
      readHistory: readClaudeHistory,
      readHistoryPage: readClaudeHistoryPage,
      readGoal: readClaudeGoal,
      forkSession: forkClaudeSession,
      usageOffBy: () => claudeUsageOffByAt(context.cwd),
      rejectTooOld: rejectTooOldClaude,
    ),
    catalog: const ClaudeCatalog(),
  );

  static final KernelDescriptor claudeCode = KernelDescriptor(
    id: claudeCodeKernelId,
    label: 'Claude Code',
    icon: Icons.terminal_rounded,
    description: 'Anthropic Claude Code CLI (claude)',
    create: (context) => ClaudeCodeKernel(
      claudeCode,
      context,
      start: startClaudeCliSession,
      readHistory: readClaudeHistory,
      readHistoryPage: readClaudeHistoryPage,
      readGoal: readClaudeGoal,
      forkSession: forkClaudeSession,
      usageOffBy: () => claudeUsageOffByAt(context.cwd),
      rejectTooOld: rejectTooOldClaude,
    ),
    catalog: const ClaudeCatalog(),
  );

  static final KernelDescriptor codex = KernelDescriptor(
    id: codexKernelId,
    label: 'Codex',
    icon: Icons.bolt_rounded,
    description: 'OpenAI Codex CLI (codex app-server)',
    create: (context) => CodexKernel(
      codex,
      ProcessCodexTransport(cwd: context.cwd),
      context: context,
      loadLocalCatalog: true,
    ),
    catalog: const CodexCatalog(),
  );

  static List<KernelDescriptor> _all = [
    antigravity,
    codebuddy,
    claudeCode,
    codex,
  ];

  static List<KernelDescriptor> get all => _all;

  /// Replaces the kernels on offer, e.g. with mock ones under test.
  static void use(List<KernelDescriptor> kernels) => _all = kernels;
}
