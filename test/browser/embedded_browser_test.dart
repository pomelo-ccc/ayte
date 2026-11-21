import 'package:baocode/browser/embedded/embedded_browser_controller.dart';
import 'package:baocode/browser/embedded/embedded_browser_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SiteRule', () {
    test('validates host, wildcard, and port patterns', () {
      expect(SiteRule.isValidPattern('localhost:3000'), isTrue);
      expect(SiteRule.isValidPattern('*.example.com'), isTrue);
      expect(SiteRule.isValidPattern('*.example.com:8443'), isTrue);
      expect(SiteRule.isValidPattern('*'), isTrue);
      expect(SiteRule.isValidPattern(''), isFalse);
      expect(SiteRule.isValidPattern('https://example.com'), isFalse);
      expect(SiteRule.isValidPattern('localhost:99999'), isFalse);
      expect(SiteRule.isValidPattern('a.*.com'), isFalse);
    });

    test('most specific site rule wins', () {
      final cfg = EmbeddedBrowserConfig(
        siteRules: const [
          SiteRule(pattern: '*', action: SiteRuleAction.system),
          SiteRule(pattern: '*.example.com', action: SiteRuleAction.embedded),
          SiteRule(
            pattern: 'admin.example.com',
            action: SiteRuleAction.block,
          ),
          SiteRule(
            pattern: 'localhost:3000',
            action: SiteRuleAction.embedded,
          ),
        ],
      );

      expect(
        cfg.resolveAction(Uri.parse('https://other.org')),
        SiteRuleAction.system,
      );
      expect(
        cfg.resolveAction(Uri.parse('https://app.example.com')),
        SiteRuleAction.embedded,
      );
      expect(
        cfg.resolveAction(Uri.parse('https://admin.example.com/secret')),
        SiteRuleAction.block,
      );
      // Block is never inverted even when Cmd/Ctrl is held.
      expect(
        cfg.resolveAction(
          Uri.parse('https://admin.example.com'),
          invertChoice: true,
        ),
        SiteRuleAction.block,
      );
      // Non-block rule flips when Cmd/Ctrl is held.
      expect(
        cfg.resolveAction(
          Uri.parse('http://localhost:3000'),
          invertChoice: true,
        ),
        SiteRuleAction.system,
      );
    });
  });

  group('EmbeddedBrowserConfig', () {
    test('eval JS depends on enabled and agentReadWriteEnabled', () {
      const base = EmbeddedBrowserConfig(
        enabled: true,
        agentReadWriteEnabled: true,
        agentEvalJsEnabled: true,
      );
      expect(base.effectiveAgentEvalJs, isTrue);
      expect(
        base.copyWith(agentReadWriteEnabled: false).effectiveAgentEvalJs,
        isFalse,
      );
      expect(base.copyWith(enabled: false).effectiveAgentEvalJs, isFalse);
    });

    test('round-trips through settings map', () {
      final orig = EmbeddedBrowserConfig(
        enabled: true,
        agentReadWriteEnabled: true,
        agentEvalJsEnabled: true,
        defaultSharePermission: EmbeddedSharePermission.read,
        jsExecutionPolicy: JsExecutionPolicy.ask,
        siteRules: const [
          SiteRule(pattern: 'localhost:5173', action: SiteRuleAction.embedded),
        ],
        profiles: const [
          BrowserProfile(id: BrowserProfile.defaultId, name: 'Default'),
          BrowserProfile(id: 'work', name: 'Work'),
        ],
        defaultProfileId: 'work',
      );
      final map = orig.toSettingsMap();
      final parsed = EmbeddedBrowserConfig.fromSettings((k) => map[k]);
      expect(parsed.agentEvalJsEnabled, isTrue);
      expect(parsed.defaultSharePermission, EmbeddedSharePermission.read);
      expect(parsed.jsExecutionPolicy, JsExecutionPolicy.ask);
      expect(parsed.siteRules.length, 1);
      expect(parsed.siteRules.first.pattern, 'localhost:5173');
      expect(parsed.profiles.length, 2);
      expect(parsed.defaultProfileId, 'work');
    });
  });

  group('EmbeddedBrowserController', () {
    test('normalizes URLs and tracks modal overlay depth', () {
      expect(
        EmbeddedBrowserController.normalizeUrl('localhost:3000'),
        'http://localhost:3000',
      );
      expect(
        EmbeddedBrowserController.normalizeUrl('example.com'),
        'https://example.com',
      );
      final ctrl = EmbeddedBrowserController.instance;
      expect(ctrl.overlayActive, isFalse);
      ctrl.pushOverlay();
      expect(ctrl.overlayActive, isTrue);
      ctrl.popOverlay();
      expect(ctrl.overlayActive, isFalse);
    });
  });
}
