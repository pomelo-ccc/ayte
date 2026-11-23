/// Canonical `<agent-message>` serialization and parsing shared across kernels
/// (`ClaudeTranslator`, `SessionTools`, and `CodexKernel`).
class AgentMessage {
  const AgentMessage({
    required this.from,
    required this.text,
    this.session,
  });

  final String from;
  final String? session;
  final String text;

  /// Alias for [session] when parsed from a `thread="..."` attribute.
  String? get thread => session;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentMessage &&
          other.from == from &&
          other.session == session &&
          other.text == text;

  @override
  int get hashCode => Object.hash(from, session, text);

  @override
  String toString() =>
      'AgentMessage(from: $from, session: $session, text: $text)';
}

/// Formats an inter-agent message as `<agent-message from="..." [session="..."]>...</agent-message>`.
///
/// Attribute values (`from`, `session`/`thread`) are XML-escaped while [text]
/// is preserved verbatim so Markdown, code blocks, and quotes remain intact.
String formatAgentMessage(
  String from,
  String text, {
  String? session,
  String? thread,
}) {
  final resolvedSession = session ?? thread;
  final escapedFrom = _escapeXmlAttr(from);
  final sessionAttr = switch (resolvedSession) {
    final String s when s.isNotEmpty => ' session="${_escapeXmlAttr(s)}"',
    _ => '',
  };
  return '<agent-message from="$escapedFrom"$sessionAttr>$text</agent-message>';
}

/// Parses a single `<agent-message from="..." [session|thread="..."]>...</agent-message>`
/// block from [raw].
///
/// Returns `null` if [raw] is not a single well-formed `<agent-message>` block
/// (for example: missing/empty `from`, unclosed tag, trailing content after
/// the closing tag, or multiple concatenated `<agent-message>` blocks).
AgentMessage? parseAgentMessage(String raw) {
  final trimmed = raw.trim();
  const openPrefix = '<agent-message';
  const closeTag = '</agent-message>';

  if (!trimmed.startsWith(openPrefix) || !trimmed.endsWith(closeTag)) {
    return null;
  }
  if (trimmed.length < openPrefix.length + 1 + closeTag.length) {
    return null;
  }

  // Must be followed by whitespace or '>' (not e.g. '<agent-messages>').
  final afterPrefix = trimmed.codeUnitAt(openPrefix.length);
  if (afterPrefix != 0x3E /* > */ && !_isWhitespace(afterPrefix)) {
    return null;
  }

  // Locate the closing '>' of the opening tag, respecting quoted attribute values.
  final openTagEnd = _findOpenTagEnd(trimmed, openPrefix.length);
  if (openTagEnd < 0) return null;

  final attrSource = trimmed.substring(openPrefix.length, openTagEnd);
  final attrs = _parseAttributes(attrSource);
  if (attrs == null) return null;

  final rawFrom = attrs['from'];
  if (rawFrom == null || rawFrom.trim().isEmpty) return null;

  final rawSession = attrs['session'] ?? attrs['thread'];
  final session = (rawSession != null && rawSession.isNotEmpty)
      ? rawSession
      : null;

  final bodyStart = openTagEnd + 1;
  final bodyEnd = trimmed.length - closeTag.length;
  if (bodyEnd < bodyStart) return null;

  // Verify no premature closing tag terminates the outer <agent-message>
  // before the final </agent-message> (e.g. two concatenated blocks).
  if (!_hasBalancedOuterBlock(trimmed, bodyStart, bodyEnd)) {
    return null;
  }

  final body = trimmed.substring(bodyStart, bodyEnd).trim();
  return AgentMessage(
    from: rawFrom,
    session: session,
    text: body,
  );
}

bool _isWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;

int _findOpenTagEnd(String s, int start) {
  int? quote;
  for (var i = start; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (quote != null) {
      if (c == quote) quote = null;
    } else if (c == 0x22 /* " */ || c == 0x27 /* ' */) {
      quote = c;
    } else if (c == 0x3E /* > */) {
      return i;
    }
  }
  return -1;
}

Map<String, String>? _parseAttributes(String attrSource) {
  final attrs = <String, String>{};
  var i = 0;
  final n = attrSource.length;
  while (i < n) {
    while (i < n && _isWhitespace(attrSource.codeUnitAt(i))) {
      i++;
    }
    if (i >= n) break;

    final nameStart = i;
    while (i < n && _isAttrNameChar(attrSource.codeUnitAt(i))) {
      i++;
    }
    if (i == nameStart) return null;
    final name = attrSource.substring(nameStart, i);

    while (i < n && _isWhitespace(attrSource.codeUnitAt(i))) {
      i++;
    }
    if (i >= n || attrSource.codeUnitAt(i) != 0x3D /* = */) return null;
    i++;

    while (i < n && _isWhitespace(attrSource.codeUnitAt(i))) {
      i++;
    }
    if (i >= n) return null;
    final quote = attrSource.codeUnitAt(i);
    if (quote != 0x22 /* " */ && quote != 0x27 /* ' */) return null;
    i++;

    final valueStart = i;
    while (i < n && attrSource.codeUnitAt(i) != quote) {
      i++;
    }
    if (i >= n) return null;
    final rawValue = attrSource.substring(valueStart, i);
    i++;

    attrs[name] = _unescapeXmlAttr(rawValue);
  }
  return attrs;
}

bool _isAttrNameChar(int c) =>
    (c >= 0x61 && c <= 0x7A) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x30 && c <= 0x39) ||
    c == 0x5F ||
    c == 0x2D;

bool _hasBalancedOuterBlock(String s, int bodyStart, int bodyEnd) {
  const openPrefix = '<agent-message';
  const closeTag = '</agent-message>';
  var depth = 1;
  var pos = bodyStart;
  while (pos < bodyEnd) {
    final nextOpen = s.indexOf(openPrefix, pos);
    final nextClose = s.indexOf(closeTag, pos);
    if (nextClose < 0 || nextClose >= bodyEnd) break;

    if (nextOpen >= 0 && nextOpen < nextClose) {
      final afterIdx = nextOpen + openPrefix.length;
      if (afterIdx < bodyEnd) {
        final after = s.codeUnitAt(afterIdx);
        if (after == 0x3E /* > */ || _isWhitespace(after)) {
          final tagEnd = _findOpenTagEnd(s, afterIdx);
          if (tagEnd >= 0 && tagEnd < bodyEnd) {
            depth++;
            pos = tagEnd + 1;
            continue;
          }
        }
      }
      pos = afterIdx;
      continue;
    }

    depth--;
    if (depth == 0) {
      // Closed before the outer </agent-message> at bodyEnd.
      return false;
    }
    pos = nextClose + closeTag.length;
  }
  return true;
}

String _escapeXmlAttr(String value) {
  final out = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    switch (value.codeUnitAt(i)) {
      case 0x26 /* & */:
        out.write('&amp;');
      case 0x22 /* " */:
        out.write('&quot;');
      case 0x27 /* ' */:
        out.write('&apos;');
      case 0x3C /* < */:
        out.write('&lt;');
      case 0x3E /* > */:
        out.write('&gt;');
      case 0x0A /* \n */:
        out.write('&#10;');
      case 0x0D /* \r */:
        out.write('&#13;');
      default:
        out.writeCharCode(value.codeUnitAt(i));
    }
  }
  return out.toString();
}

final _xmlEntityPattern = RegExp(
  r'&(amp|quot|apos|lt|gt|#\d+|#x[0-9a-fA-F]+);',
);

String _decodeNumericXmlEntity(int? codePoint, String fallback) {
  if (codePoint == null ||
      codePoint < 0x01 ||
      codePoint > 0x10FFFF ||
      (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
    return fallback;
  }
  return String.fromCharCode(codePoint);
}

String _unescapeXmlAttr(String value) => value.replaceAllMapped(
  _xmlEntityPattern,
  (match) {
    final entity = match[1]!;
    return switch (entity) {
      'quot' => '"',
      'apos' => "'",
      'lt' => '<',
      'gt' => '>',
      'amp' => '&',
      _ when entity.startsWith('#x') => _decodeNumericXmlEntity(
        int.tryParse(entity.substring(2), radix: 16),
        match[0]!,
      ),
      _ when entity.startsWith('#') => _decodeNumericXmlEntity(
        int.tryParse(entity.substring(1)),
        match[0]!,
      ),
      _ => match[0]!,
    };
  },
);
