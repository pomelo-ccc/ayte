import 'package:baocode/kernel/agent_message_parser.dart';
import 'package:baocode/kernel/claude_code/claude_code_translator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('agent_message_parser', () {
    test('formats and parses simple and multiline messages with session/thread', () {
      final formatted = formatAgentMessage(
        'Lead Agent',
        'Line 1\nLine 2',
        session: 'sess-123',
      );
      expect(
        formatted,
        '<agent-message from="Lead Agent" session="sess-123">Line 1\nLine 2</agent-message>',
      );

      final parsed = parseAgentMessage('  $formatted  ');
      expect(parsed, isNotNull);
      expect(parsed!.from, 'Lead Agent');
      expect(parsed.session, 'sess-123');
      expect(parsed.thread, 'sess-123');
      expect(parsed.text, 'Line 1\nLine 2');

      final withThread = parseAgentMessage(
        '<agent-message thread="thr-9" from="Worker">\nHello\n</agent-message>',
      );
      expect(withThread, isNotNull);
      expect(withThread!.from, 'Worker');
      expect(withThread.session, 'thr-9');
      expect(withThread.thread, 'thr-9');
      expect(withThread.text, 'Hello');
    });

    test('escapes and unescapes XML entities cleanly without double-unescaping', () {
      const sender = 'A & "B" <C> \'D\'\nLine';
      const sess = 's&"1"<2>';
      const body = 'Body with <tags>, "quotes", and &amp; literal';

      final formatted = formatAgentMessage(sender, body, session: sess);
      expect(formatted, isNot(contains('from="A & "')));

      final parsed = parseAgentMessage(formatted);
      expect(parsed, isNotNull);
      expect(parsed!.from, sender);
      expect(parsed.session, sess);
      expect(parsed.text, body);

      // Single-pass unescaping: &amp;lt; must become &lt;, never <.
      final doubleEscaped = parseAgentMessage(
        '<agent-message from="A &amp;lt; B">hi</agent-message>',
      );
      expect(doubleEscaped, isNotNull);
      expect(doubleEscaped!.from, 'A &lt; B');

      // Single-pass numeric unescaping: &amp;#32; must become &#32;, not space.
      final doubleNumeric = parseAgentMessage(
        '<agent-message from="A&amp;#32;B">hi</agent-message>',
      );
      expect(doubleNumeric, isNotNull);
      expect(doubleNumeric!.from, 'A&#32;B');

      // Valid decimal & hex character references decode cleanly, while invalid
      // NUL / surrogate / out-of-range references stay literal.
      final numericValid = parseAgentMessage(
        '<agent-message from="A &#x1F680; &#34;B&#34; &#0; &#xD800; &#x110000;">hi</agent-message>',
      );
      expect(numericValid, isNotNull);
      expect(numericValid!.from, 'A 🚀 "B" &#0; &#xD800; &#x110000;');
    });

    test('handles nested <agent-message> quotes inside body and single-quoted attributes', () {
      final nested = parseAgentMessage(
        "<agent-message from='Coordinator' session='s-1'>\n"
        'Quoted: <agent-message from="Sub">inner</agent-message>\n'
        'Done.\n'
        '</agent-message>',
      );
      expect(nested, isNotNull);
      expect(nested!.from, 'Coordinator');
      expect(nested.session, 's-1');
      expect(
        nested.text,
        'Quoted: <agent-message from="Sub">inner</agent-message>\nDone.',
      );
    });

    test('rejects malformed, empty/whitespace-only from, trailing-text, or concatenated blocks', () {
      expect(parseAgentMessage('plain text'), isNull);
      expect(parseAgentMessage('<agent-message>no from</agent-message>'), isNull);
      expect(parseAgentMessage('<agent-message from="">empty</agent-message>'), isNull);
      expect(parseAgentMessage('<agent-message from="   ">hi</agent-message>'), isNull);
      expect(
        parseAgentMessage('<agent-message from="&#10;&#13; ">hi</agent-message>'),
        isNull,
      );
      expect(
        parseAgentMessage('<agent-message from="&#9;&#32;">hi</agent-message>'),
        isNull,
      );
      expect(
        parseAgentMessage('<agent-message from="&#x09;&#x20;">hi</agent-message>'),
        isNull,
      );
      expect(
        parseAgentMessage('<agent-message from="&#x0A;&#x0D;">hi</agent-message>'),
        isNull,
      );
      expect(
        parseAgentMessage('<agent-message from="&#09;&#0032;">hi</agent-message>'),
        isNull,
      );
      expect(
        parseAgentMessage('<agent-message from="\t\n">hi</agent-message>'),
        isNull,
      );
      expect(
        ClaudeTranslator.agentMessage(
          '<agent-message from="&#9;&#32;">hi</agent-message>',
        ),
        isNull,
      );
      expect(
        ClaudeTranslator.agentMessage(
          '<agent-message from="   ">hi</agent-message>',
        ),
        isNull,
      );
      expect(parseAgentMessage('<agent-message from="A">unclosed'), isNull);
      expect(
        parseAgentMessage('<agent-messages from="A">wrong tag</agent-messages>'),
        isNull,
      );
      expect(
        parseAgentMessage('<agent-message from="A">x</agent-message> trailing'),
        isNull,
      );
      expect(
        parseAgentMessage(
          '<agent-message from="A">one</agent-message>\n'
          '<agent-message from="B">two</agent-message>',
        ),
        isNull,
      );
    });

    test('ClaudeTranslator.agentMessage delegates to shared parser consistently', () {
      final formatted = formatAgentMessage(
        'Worker "1"',
        'Result:\n- ok',
        session: 'conv-42',
      );
      final translated = ClaudeTranslator.agentMessage(formatted);
      expect(translated, (
        from: 'Worker "1"',
        session: 'conv-42',
        text: 'Result:\n- ok',
      ));
      expect(
        ClaudeTranslator.agentMessage('<agent-message from="">bad</agent-message>'),
        isNull,
      );
    });

    test('preserves CJK/emoji, handles extra attributes and whitespace around =, and normalizes empty session', () {
      const sender = '协调员 🚀';
      const body = '已完成检查 ✅\nNext: test';
      final formatted = formatAgentMessage(sender, body, session: 'sess-中文-1');
      final parsed = parseAgentMessage(formatted);
      expect(parsed, isNotNull);
      expect(parsed!.from, sender);
      expect(parsed.session, 'sess-中文-1');
      expect(parsed.text, body);

      final extraAttr = parseAgentMessage(
        '<agent-message role="coordinator" from = "Lead" session="">  hello  </agent-message>',
      );
      expect(extraAttr, isNotNull);
      expect(extraAttr!.from, 'Lead');
      expect(extraAttr.session, isNull);
      expect(extraAttr.text, 'hello');

      expect(parseAgentMessage('<agent-message from="A" />'), isNull);
    });
  });
}
