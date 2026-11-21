import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart' show ToolKind;
import '../../kernel/claude_code/claude_sdk_tools.dart';
import '../../kernel/kernel_types.dart'
    show ApprovalDecision, ApprovalRequest;
import 'embedded_browser_controller.dart';
import 'embedded_browser_native.dart';
import 'embedded_browser_settings.dart';

/// Exposes Ayte's workspace Embedded Browser to agents via [ClaudeSdkTools]
/// (`mcp__baocode__embedded_browser_*`).
abstract final class EmbeddedBrowserTools {
  static bool _registered = false;
  static bool _started = false;

  static const _feature = 'embedded_browser';

  static const _instructions = '''
Ayte Built-in Browser tools (`embedded_browser_*`) operate on web pages inside Ayte's workspace Browser panel.
- Call `embedded_browser_list_tabs` to see open tabs and each tab's permission (`none`, `read`, `readWrite`).
- Call `embedded_browser_open` to open a URL in a new workspace tab.
- Call `embedded_browser_read` to read visible page text, interactive elements, and optional PNG screenshot from a shared tab.
- Call `embedded_browser_act` to navigate, click CSS selectors, fill inputs, or scroll in a `readWrite` tab.
- Call `embedded_browser_eval` only when JavaScript execution is enabled in Settings → Browser; it may prompt the user for confirmation.
''';

  static void start() {
    if (_started) return;
    _started = true;
    final ctrl = EmbeddedBrowserController.instance;
    void sync() {
      if (ctrl.config.enabled && ctrl.config.agentReadWriteEnabled) {
        register();
      } else {
        unregister();
      }
    }

    sync();
    ctrl.addListener(sync);
  }

  static void register() {
    if (_registered) return;
    _registered = true;
    ClaudeSdkTools.instruct(_feature, _instructions);
    for (final tool in _tools) {
      ClaudeSdkTools.register(tool);
    }
  }

  static void unregister() {
    if (!_registered) return;
    _registered = false;
    for (final tool in _tools) {
      ClaudeSdkTools.unregister(tool.name);
    }
    ClaudeSdkTools.instruct(_feature, null);
  }

  static EmbeddedBrowserTab _requireTab(
    Map<String, Object?> input, {
    required bool write,
  }) {
    final ctrl = EmbeddedBrowserController.instance;
    final tabId = input['tabId'] as String?;
    final tab = tabId == null || tabId.isEmpty
        ? ctrl.activeTab
        : ctrl.tabById(tabId);
    if (tab == null) {
      throw StateError(
        'No embedded browser tab is open. Call embedded_browser_open first.',
      );
    }
    if (write && !tab.permission.canOperate) {
      throw StateError(
        'Tab ${tab.id} (${tab.url}) does not have "Read & Operate" permission.',
      );
    }
    if (!write && !tab.permission.canRead) {
      throw StateError(
        'Tab ${tab.id} (${tab.url}) is not shared with agents.',
      );
    }
    return tab;
  }

  static List<ClaudeSdkTool> get _tools => [
    ClaudeSdkTool(
      name: 'embedded_browser_list_tabs',
      description:
          'List all open tabs in Ayte\'s built-in workspace browser with their URLs, titles, profiles, and share permissions.',
      kind: ToolKind.browser,
      inputSchema: const {'type': 'object', 'properties': <String, Object?>{}},
      summary: (_, _) => 'List built-in browser tabs',
      run: (input, call) async {
        final ctrl = EmbeddedBrowserController.instance;
        return jsonEncode({
          'activeTabId': ctrl.activeTabId,
          'evalJsEnabled': ctrl.config.effectiveAgentEvalJs,
          'tabs': [for (final t in ctrl.tabs) t.toJson()],
        });
      },
    ),
    ClaudeSdkTool(
      name: 'embedded_browser_open',
      description:
          'Open a URL in a new tab inside Ayte\'s built-in workspace browser (respects site block rules).',
      kind: ToolKind.browser,
      inputSchema: const {
        'type': 'object',
        'required': ['url'],
        'properties': {
          'url': {'type': 'string', 'description': 'The http(s) URL to open.'},
          'profileId': {
            'type': 'string',
            'description': 'Optional browser profile ID.',
          },
        },
      },
      summary: (input, _) => 'Open ${input['url']} in built-in browser',
      run: (input, call) async {
        final ctrl = EmbeddedBrowserController.instance;
        final raw = (input['url'] as String? ?? '').trim();
        if (raw.isEmpty) throw ArgumentError('url is required.');
        final normalized = EmbeddedBrowserController.normalizeUrl(raw);
        final uri = Uri.tryParse(normalized);
        if (uri != null &&
            ctrl.config.matchSiteRule(uri)?.action == SiteRuleAction.block) {
          throw StateError('Site $normalized is blocked by Browser Site Rules.');
        }
        final tab = ctrl.openTab(
          normalized,
          profileId: input['profileId'] as String?,
        );
        tab.recordActivity('Opened $normalized');
        return jsonEncode(tab.toJson());
      },
    ),
    ClaudeSdkTool(
      name: 'embedded_browser_read',
      description:
          'Read title, URL, visible text, and interactive elements from a shared built-in browser tab, plus an optional PNG screenshot.',
      kind: ToolKind.browser,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'tabId': {
            'type': 'string',
            'description': 'Tab ID (defaults to active tab).',
          },
          'includeScreenshot': {
            'type': 'boolean',
            'description': 'Also capture a PNG screenshot (default false).',
          },
          'maxChars': {
            'type': 'integer',
            'description': 'Max visible text characters to return (default 8000).',
          },
        },
      },
      summary: (input, _) => 'Read built-in browser tab ${input['tabId'] ?? ''}',
      run: (input, call) async {
        final tab = _requireTab(input, write: false);
        final maxChars = ((input['maxChars'] as num?)?.toInt() ?? 8000).clamp(
          500,
          40000,
        );
        const script = r'''
(() => {
  const text = (document.body && document.body.innerText) ? document.body.innerText : '';
  const items = Array.from(document.querySelectorAll('a,button,input,textarea,select,[role="button"]'))
    .slice(0, 60)
    .map((el, idx) => ({
      index: idx,
      tag: el.tagName.toLowerCase(),
      id: el.id || undefined,
      name: el.getAttribute('name') || undefined,
      type: el.getAttribute('type') || undefined,
      text: (el.innerText || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '').trim().slice(0, 80),
      href: el.getAttribute('href') || undefined,
    }));
  return JSON.stringify({
    url: location.href,
    title: document.title,
    text: text.slice(0, MAX_CHARS),
    interactive: items
  });
})()
''';
        final raw = await EmbeddedBrowserNative.evalJs(
          tab.id,
          script.replaceFirst('MAX_CHARS', '$maxChars'),
        );
        tab.recordActivity('Read page content');
        final blocks = <Map<String, Object?>>[claudeSdkText(raw)];
        if (input['includeScreenshot'] == true) {
          final tmp = p.join(
            Directory.systemTemp.path,
            'ayte_web_${tab.id}_${DateTime.now().millisecondsSinceEpoch}.png',
          );
          try {
            await EmbeddedBrowserNative.takeSnapshot(tab.id, tmp);
            final file = File(tmp);
            if (file.existsSync()) {
              final bytes = await file.readAsBytes();
              blocks.add(claudeSdkImage(base64Encode(bytes), 'image/png'));
              file.deleteSync();
            }
          } on Object catch (e) {
            blocks.add(claudeSdkText('Screenshot note: $e'));
          }
        }
        return blocks;
      },
    ),
    ClaudeSdkTool(
      name: 'embedded_browser_act',
      description:
          'Operate on a built-in browser tab with "Read & Operate" permission: navigate, click a CSS selector, fill text into an input, scroll, or go back/forward/reload.',
      kind: ToolKind.browser,
      inputSchema: const {
        'type': 'object',
        'required': ['action'],
        'properties': {
          'tabId': {'type': 'string'},
          'action': {
            'type': 'string',
            'enum': [
              'navigate',
              'click',
              'fill',
              'scroll',
              'back',
              'forward',
              'reload',
            ],
          },
          'url': {'type': 'string'},
          'selector': {'type': 'string'},
          'value': {'type': 'string'},
          'deltaY': {'type': 'number'},
        },
      },
      summary: (input, _) => 'Built-in browser ${input['action']}',
      run: (input, call) async {
        final tab = _requireTab(input, write: true);
        final ctrl = EmbeddedBrowserController.instance;
        final action = input['action'] as String? ?? '';
        switch (action) {
          case 'navigate':
            final url = (input['url'] as String? ?? '').trim();
            if (url.isEmpty) throw ArgumentError('url is required for navigate.');
            ctrl.navigateTab(tab.id, url);
            tab.recordActivity('Navigated to $url');
            return 'Navigated ${tab.id} to $url';
          case 'back':
            ctrl.goBack(tab.id);
            tab.recordActivity('Navigated back');
            return 'OK (back)';
          case 'forward':
            ctrl.goForward(tab.id);
            tab.recordActivity('Navigated forward');
            return 'OK (forward)';
          case 'reload':
            ctrl.reload(tab.id);
            tab.recordActivity('Reloaded page');
            return 'OK (reload)';
          case 'click':
            final sel = input['selector'] as String? ?? '';
            if (sel.isEmpty) {
              throw ArgumentError('selector is required for click.');
            }
            final res = await EmbeddedBrowserNative.evalJs(
              tab.id,
              '''(() => {
                const el = document.querySelector(${jsonEncode(sel)});
                if (!el) return 'NOT_FOUND';
                el.scrollIntoView({block:'center'});
                el.click();
                return 'CLICKED';
              })()''',
            );
            tab.recordActivity('Clicked $sel ($res)');
            return res;
          case 'fill':
            final sel = input['selector'] as String? ?? '';
            final val = input['value'] as String? ?? '';
            if (sel.isEmpty) {
              throw ArgumentError('selector is required for fill.');
            }
            final res = await EmbeddedBrowserNative.evalJs(
              tab.id,
              '''(() => {
                const el = document.querySelector(${jsonEncode(sel)});
                if (!el) return 'NOT_FOUND';
                el.focus();
                el.value = ${jsonEncode(val)};
                el.dispatchEvent(new Event('input', {bubbles:true}));
                el.dispatchEvent(new Event('change', {bubbles:true}));
                return 'FILLED';
              })()''',
            );
            tab.recordActivity('Filled $sel ($res)');
            return res;
          case 'scroll':
            final dy = (input['deltaY'] as num?)?.toDouble() ?? 500;
            await EmbeddedBrowserNative.evalJs(
              tab.id,
              'window.scrollBy(0, $dy); "SCROLLED"',
            );
            tab.recordActivity('Scrolled $dy px');
            return 'SCROLLED';
          default:
            throw ArgumentError('Unsupported browser action: $action');
        }
      },
    ),
    ClaudeSdkTool(
      name: 'embedded_browser_eval',
      description:
          'Run custom JavaScript in a built-in browser tab. Requires "Execute JavaScript in Built-in Browser" enabled in Settings → Browser and tab permission set to Read & Operate.',
      kind: ToolKind.browser,
      asksItself: true,
      inputSchema: const {
        'type': 'object',
        'required': ['script'],
        'properties': {
          'tabId': {'type': 'string'},
          'script': {
            'type': 'string',
            'description': 'JavaScript expression or IIFE to evaluate.',
          },
        },
      },
      summary: (input, _) => 'Run JS in built-in browser',
      run: (input, call) async {
        final ctrl = EmbeddedBrowserController.instance;
        if (!ctrl.config.effectiveAgentEvalJs) {
          throw StateError(
            'Running custom JavaScript in the built-in browser is disabled. Enable it in Settings → Browser.',
          );
        }
        final tab = _requireTab(input, write: true);
        final script = input['script'] as String? ?? '';
        if (script.trim().isEmpty) throw ArgumentError('script is required.');

        if (ctrl.config.jsExecutionPolicy == JsExecutionPolicy.ask) {
          final ask = call.ask;
          if (ask == null) {
            throw StateError(
              'User confirmation is required to run JavaScript on ${tab.url}, but no interactive prompt is available.',
            );
          }
          final decision = await ask(
            ApprovalRequest(
              id: 'eb_eval_${DateTime.now().microsecondsSinceEpoch}',
              toolName: 'embedded_browser_eval',
              title: 'Run JavaScript on ${tab.displayTitle}',
              reason: script,
            ),
          );
          if (decision != ApprovalDecision.allowOnce &&
              decision != ApprovalDecision.allowAlways) {
            throw StateError('User declined JavaScript execution.');
          }
        }

        final result = await EmbeddedBrowserNative.evalJs(tab.id, script);
        tab.recordActivity(
          'Evaluated JS (${script.trim().split('\n').first})',
        );
        return result;
      },
    ),
  ];
}
