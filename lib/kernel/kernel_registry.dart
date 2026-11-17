import 'package:flutter/material.dart';

import 'agent_kernel.dart';
import 'claude_code/claude_code_kernel.dart';
import '../remote/remote_claude.dart';

/// The kernels offered in Ayte: Antigravity (`agy`) with fallback to
/// custom API providers configured in Settings → Models.
abstract final class KernelRegistry {
  static final KernelDescriptor antigravity = KernelDescriptor(
    id: 'antigravity-cli',
    label: 'Antigravity',
    icon: Icons.rocket_launch_rounded,
    description: 'Google Antigravity coding agent (agy)',
    create: (context) => ClaudeCodeKernel(
      antigravity,
      context,
      start: startClaude,
      readHistory: readClaudeHistory,
      readHistoryPage: readClaudeHistoryPage,
      readGoal: readClaudeGoal,
      forkSession: forkClaudeSession,
      usageOffBy: () => claudeUsageOffByAt(context.cwd),
      rejectTooOld: rejectTooOldClaude,
    ),
    catalog: const ClaudeCatalog(),
  );

  static List<KernelDescriptor> _all = [antigravity];

  static List<KernelDescriptor> get all => _all;

  /// Replaces the kernels on offer, e.g. with mock ones under test.
  static void use(List<KernelDescriptor> kernels) => _all = kernels;
}
