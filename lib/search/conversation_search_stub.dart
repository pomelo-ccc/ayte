import 'conversation_search.dart';

/// No kept conversations on the web.
class ClaudeConversationSearch extends NoConversationSearch {
  ClaudeConversationSearch({
    this.configDir,
    String? homeDir,
    String? claudeConfigDir,
    String? codebuddyConfigDir,
    String? codexHome,
    String? antigravityDir,
  });

  final String? configDir;
}
