/// Prepares Markdown / chat replies for natural text-to-speech playback.
abstract final class VoiceTextCleaner {
  static final _fencedCode = RegExp(r'```[\s\S]*?```');
  static final _inlineCode = RegExp(r'`([^`]+)`');
  static final _markdownImage = RegExp(r'!\[[^\]]*\]\([^\)]*\)');
  static final _markdownLink = RegExp(r'\[([^\]]+)\]\([^\)]*\)');
  static final _url = RegExp(r'https?://\S+');
  static final _voiceCue = RegExp(r"\[[a-z][a-z ,'-]{0,30}\]");
  static final _htmlTag = RegExp(r'<[^>]+>');
  static final _markdownTokens = RegExp(r'[#*|>~_]+');
  static final _multiSpace = RegExp(r'[ \t]{2,}');
  static final _multiNewline = RegExp(r'\n{2,}');

  /// Cleans [text] for full-reply speech playback, stripping fenced code blocks,
  /// raw URLs, and Markdown punctuation while keeping readable prose.
  ///
  /// When [maxChars] is provided and the cleaned result exceeds it, truncates
  /// gracefully at a sentence boundary when possible.
  static String cleanForSpeech(
    String text, {
    int maxChars = 4000,
    bool isZh = false,
  }) {
    var s = text
        .replaceAll(_fencedCode, isZh ? '，代码片段已略过，' : ' (code block omitted) ')
        .replaceAll(_markdownImage, '')
        .replaceAllMapped(_markdownLink, (m) => m.group(1) ?? '')
        .replaceAllMapped(_inlineCode, (m) => m.group(1) ?? '')
        .replaceAll(_url, '')
        .replaceAll(_voiceCue, '')
        .replaceAll(_htmlTag, ' ')
        .replaceAll(_markdownTokens, ' ')
        .replaceAll('\r\n', '\n')
        .replaceAll(_multiSpace, ' ')
        .replaceAll(_multiNewline, '\n')
        .trim();

    if (s.length > maxChars) {
      final cut = s.substring(0, maxChars);
      final lastStop = cut.lastIndexOf(RegExp(r'[。！？.!?\n]'));
      s = lastStop > maxChars ~/ 2 ? cut.substring(0, lastStop + 1) : cut;
    }
    return s.trim();
  }

  /// Cleans [text] into a short 1-sentence summary for task completion alerts.
  static String cleanForSummary(String text, {int maxChars = 60}) {
    var s = text
        .replaceAll(_fencedCode, '')
        .replaceAll(_markdownImage, '')
        .replaceAllMapped(_markdownLink, (m) => m.group(1) ?? '')
        .replaceAll(_inlineCode, '')
        .replaceAll(_url, '')
        .replaceAll(_voiceCue, '')
        .replaceAll(_htmlTag, ' ')
        .replaceAll(_markdownTokens, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.length > maxChars) {
      s = s.substring(0, maxChars).trimRight();
    }
    return s;
  }

  /// Heuristic to detect whether [text] is predominantly CJK characters.
  static bool containsCjk(String text) =>
      RegExp(r'[\u4e00-\u9fff]').hasMatch(text);
}
