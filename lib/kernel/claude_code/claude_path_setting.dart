/// Executable discovery status shown in Settings → General.
sealed class LocalClaudeStatus {
  const LocalClaudeStatus();
}

/// [path] runs, at [version] (null when it does not say).
class LocalClaudeFound extends LocalClaudeStatus {
  const LocalClaudeFound(this.path, this.version, {this.downloaded = false});

  final String path;
  final String? version;
  final bool downloaded;
}

/// Not found on this machine.
class LocalClaudeMissing extends LocalClaudeStatus {
  const LocalClaudeMissing();
}

/// Configured path does not exist or failed to run.
class LocalClaudeFailed extends LocalClaudeStatus {
  const LocalClaudeFailed(this.message);

  final String message;
}
