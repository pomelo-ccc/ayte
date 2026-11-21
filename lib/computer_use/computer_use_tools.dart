import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../chat/chat_models.dart' show ToolKind;
import '../kernel/claude_code/claude_sdk_tools.dart';
import 'computer_use_controller.dart';
import 'computer_use_native.dart';
import 'computer_use_settings.dart';
import 'cua_driver_service.dart';

/// Exposes permission-gated desktop window inspection and control tools to
/// agents via [ClaudeSdkTools] (`mcp__baocode__computer_*`), aligned with
/// `cua-driver` 0.55+ strict JSON schemas.
abstract final class ComputerUseTools {
  static bool _registered = false;
  static bool _started = false;

  static const _feature = 'computer_use';
  static const _sessionLabel = 'ayte';

  static const _instructions = '''
Desktop Computer Use tools (`computer_*`) operate ONLY on desktop windows the user explicitly shared with Ayte.
- Call `computer_list_windows` first to discover visible windows and see which ones are shared (`readOnly` or `interactive`).
- Call `computer_get_window_state` on a shared window to inspect its accessibility tree (with `element_token`s) and PNG screenshot.
- Call `computer_act` ONLY on a window marked `interactive`. Prefer `elementToken` when available; fall back to `x`/`y` screenshot coordinates.
- Never attempt to bypass blocked privacy apps or Ayte's own window.
- If no window is shared yet, ask the user to share the target window from Ayte's Computer Use status pill.
''';

  static void start() {
    if (_started) return;
    _started = true;
    final controller = ComputerUseController.instance;
    void sync() {
      if (controller.config.toolsActive) {
        register();
      } else {
        unregister();
      }
    }

    sync();
    controller.addListener(sync);
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

  static Future<Map<String, Object?>?> _readImageAndDelete(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      return claudeSdkImage(base64Encode(bytes), 'image/png');
    } finally {
      if (file.existsSync()) file.deleteSync();
    }
  }

  static List<ClaudeSdkTool> get _tools => [
    ClaudeSdkTool(
      name: 'computer_list_windows',
      description:
          'List visible desktop windows and their share status with Ayte (none / readOnly / interactive). Blocked privacy apps and Ayte itself are excluded.',
      kind: ToolKind.other,
      inputSchema: const {'type': 'object', 'properties': <String, Object?>{}},
      summary: (_, _) => 'List shared desktop windows',
      run: (input, call) async {
        final ctrl = ComputerUseController.instance;
        if (!ctrl.config.enabled) {
          throw StateError(
            'Computer Use is disabled in Settings → Computer Use.',
          );
        }
        ctrl.refreshWindows();
        final visible = <Map<String, Object?>>[];
        for (final w in ctrl.windows) {
          if (ctrl.isWindowBlocked(w)) continue;
          final level = ctrl.shareLevelOf(w.windowId);
          visible.add({
            ...w.toJson(),
            'shareLevel': ctrl.fullScreenShared ? 'interactive' : level.name,
          });
        }
        return jsonEncode({
          'fullScreenShared': ctrl.fullScreenShared,
          'deliveryMode': ctrl.config.effectiveDeliveryMode.name,
          'driverInstalled': CuaDriverService.instance.isInstalled,
          'daemonRunning': CuaDriverService.instance.daemonRunning,
          'windows': visible,
        });
      },
    ),
    ClaudeSdkTool(
      name: 'computer_get_window_state',
      description:
          'Inspect a shared desktop window: returns the accessibility tree (via cua-driver) and a PNG screenshot of the window.',
      kind: ToolKind.other,
      inputSchema: const {
        'type': 'object',
        'required': ['windowId'],
        'properties': {
          'windowId': {
            'type': 'integer',
            'description': 'Target windowId from computer_list_windows.',
          },
          'includeScreenshot': {
            'type': 'boolean',
            'description': 'Capture a PNG screenshot of the shared window (default true).',
          },
          'query': {
            'type': 'string',
            'description': 'Optional case-insensitive filter for accessibility tree elements.',
          },
        },
      },
      summary: (input, _) => 'Inspect desktop window #${input['windowId']}',
      run: (input, call) async {
        final ctrl = ComputerUseController.instance;
        if (!ctrl.config.enabled) {
          throw StateError('Computer Use is disabled.');
        }
        final windowId = (input['windowId'] as num?)?.toInt();
        if (windowId == null) {
          throw ArgumentError('windowId is required.');
        }
        final entry = ctrl.sharedWindows[windowId];
        DesktopWindowInfo? target = entry?.window;
        if (target == null && ctrl.fullScreenShared) {
          ctrl.refreshWindows();
          for (final w in ctrl.windows) {
            if (w.windowId == windowId && !ctrl.isWindowBlocked(w)) {
              target = w;
              break;
            }
          }
        }
        if (target == null) {
          throw StateError(
            'Window #$windowId is not shared with Ayte. Ask the user to share it from the Computer Use menu.',
          );
        }
        if (ctrl.isWindowBlocked(target)) {
          throw StateError(
            'Window #$windowId belongs to a protected/blocked app.',
          );
        }
        ctrl.markWindowAccessed(windowId);
        if (ctrl.fullScreenShared) ctrl.markFullScreenAccessed();

        final includeShot = input['includeScreenshot'] != false;
        final tmpShot = p.join(
          Directory.systemTemp.path,
          'ayte_cu_win_${target.windowId}_${DateTime.now().millisecondsSinceEpoch}.png',
        );
        final blocks = <Map<String, Object?>>[];
        var gotImage = false;

        final driver = CuaDriverService.instance;
        if (driver.isInstalled) {
          final res = await driver.callTool(
            'get_window_state',
            {
              'pid': target.pid,
              'window_id': target.windowId,
              'session': _sessionLabel,
              'include_screenshot': includeShot,
              if (input['query'] case final String q when q.trim().isNotEmpty)
                'query': q.trim(),
            },
            screenshotOutFile: includeShot ? tmpShot : null,
          );
          if (res.ok && res.stdout.isNotEmpty) {
            blocks.add(claudeSdkText(res.stdout));
          } else if (res.stderr.isNotEmpty) {
            blocks.add(claudeSdkText('cua-driver note: ${res.stderr}'));
          }
          if (includeShot) {
            final img = await _readImageAndDelete(tmpShot);
            if (img != null) {
              blocks.add(img);
              gotImage = true;
            }
          }
        } else {
          blocks.add(
            claudeSdkText(
              jsonEncode({
                'window': target.toJson(),
                'note':
                    'cua-driver is not installed yet; returning native window metadata and screenshot.',
              }),
            ),
          );
        }

        if (includeShot && !gotImage && ComputerUseNative.supported) {
          if (ComputerUseNative.captureWindow(target.windowId, tmpShot)) {
            final img = await _readImageAndDelete(tmpShot);
            if (img != null) blocks.add(img);
          }
        }
        return blocks.isEmpty ? 'No window state returned.' : blocks;
      },
    ),
    ClaudeSdkTool(
      name: 'computer_act',
      description:
          'Perform an input action on a desktop window shared with "interactive" permission via cua-driver (click, double_click, right_click, type_text, press_key, hotkey, scroll, drag, set_window_frame, launch_app, clipboard_read, clipboard_write).',
      kind: ToolKind.other,
      inputSchema: const {
        'type': 'object',
        'required': ['action'],
        'properties': {
          'windowId': {
            'type': 'integer',
            'description': 'Target windowId marked interactive (required for window actions).',
          },
          'action': {
            'type': 'string',
            'enum': [
              'click',
              'double_click',
              'right_click',
              'type_text',
              'press_key',
              'hotkey',
              'scroll',
              'drag',
              'set_window_frame',
              'move_window',
              'launch_app',
              'clipboard_read',
              'clipboard_write',
            ],
          },
          'x': {'type': 'number'},
          'y': {'type': 'number'},
          'toX': {'type': 'number'},
          'toY': {'type': 'number'},
          'text': {'type': 'string'},
          'key': {'type': 'string'},
          'keys': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'modifiers': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'elementToken': {'type': 'string'},
          'direction': {
            'type': 'string',
            'enum': ['up', 'down', 'left', 'right'],
          },
          'amount': {'type': 'number'},
          'deltaY': {'type': 'number'},
          'width': {'type': 'number'},
          'height': {'type': 'number'},
          'appName': {'type': 'string'},
          'bundleId': {'type': 'string'},
          'foreground': {
            'type': 'boolean',
            'description': 'Whether to bring the window to front if allowed.',
          },
        },
      },
      summary: (input, _) =>
          'Desktop ${input['action']}${input['windowId'] != null ? ' on window #${input['windowId']}' : ''}',
      run: (input, call) async {
        final ctrl = ComputerUseController.instance;
        if (!ctrl.config.enabled) {
          throw StateError('Computer Use is disabled.');
        }
        final action = input['action'] as String? ?? '';
        if (action.isEmpty) throw ArgumentError('action is required.');

        // App-level / clipboard actions gated by settings.
        if (action == 'launch_app') {
          if (!ctrl.config.allowLaunchAndMove) {
            throw StateError(
              'Launching apps is disabled in Settings → Computer Use.',
            );
          }
          final name = (input['appName'] as String? ?? '').trim();
          final bundleId = (input['bundleId'] as String? ?? '').trim();
          if (ctrl.config.isBlockedApp(
            bundleId: bundleId,
            appName: name,
            execPath: '',
          )) {
            throw StateError('Cannot launch a protected/blacklisted app.');
          }
          final res = await CuaDriverService.instance.callTool('launch_app', {
            'session': _sessionLabel,
            if (name.isNotEmpty) 'name': name,
            if (bundleId.isNotEmpty) 'bundle_id': bundleId,
          });
          if (!res.ok) throw StateError(res.stderr);
          return res.stdout.isEmpty ? 'Launched app' : res.stdout;
        }

        if (action == 'clipboard_read' || action == 'clipboard_write') {
          if (!ctrl.config.allowClipboard) {
            throw StateError(
              'Clipboard access is disabled in Settings → Computer Use.',
            );
          }
          final args = action == 'clipboard_read'
              ? <String, Object?>{
                  'session': _sessionLabel,
                  'include_text': true,
                }
              : <String, Object?>{
                  'session': _sessionLabel,
                  'text': input['text'] as String? ?? '',
                };
          final res = await CuaDriverService.instance.callTool(action, args);
          if (!res.ok) throw StateError(res.stderr);
          return res.stdout.isEmpty ? 'OK ($action)' : res.stdout;
        }

        final windowId = (input['windowId'] as num?)?.toInt();
        if (windowId == null) {
          throw ArgumentError('windowId is required for $action.');
        }
        final entry = ctrl.sharedWindows[windowId];
        final isInteractive =
            ctrl.fullScreenShared ||
            entry?.level == WindowShareLevel.interactive;
        if (!isInteractive) {
          throw StateError(
            'Window #$windowId does not have interactive permission. Share it as "Interactive" first.',
          );
        }
        DesktopWindowInfo? target = entry?.window;
        if (target == null) {
          ctrl.refreshWindows();
          for (final w in ctrl.windows) {
            if (w.windowId == windowId) {
              target = w;
              break;
            }
          }
        }
        if (target == null || ctrl.isWindowBlocked(target)) {
          throw StateError('Window #$windowId is unavailable or protected.');
        }
        ctrl.markWindowAccessed(windowId);

        final reqFg = input['foreground'] as bool?;
        final deliveryMode =
            (ctrl.config.allowBringToFront &&
                (reqFg ??
                    ctrl.config.effectiveDeliveryMode ==
                        ComputerUseDeliveryMode.foreground))
            ? 'foreground'
            : 'background';

        final cuaTool = action == 'move_window' ? 'set_window_frame' : action;
        if (cuaTool == 'set_window_frame') {
          if (!ctrl.config.allowLaunchAndMove) {
            throw StateError(
              'Moving/resizing windows is disabled in Settings → Computer Use.',
            );
          }
          final res = await CuaDriverService.instance.callTool(
            'set_window_frame',
            {
              'session': _sessionLabel,
              'pid': target.pid,
              'window_id': target.windowId,
              'x': input['x'] ?? target.x,
              'y': input['y'] ?? target.y,
              'width': input['width'] ?? target.width,
              'height': input['height'] ?? target.height,
            },
          );
          if (!res.ok) throw StateError(res.stderr);
          return res.stdout.isEmpty ? 'OK (set_window_frame)' : res.stdout;
        }

        final args = <String, Object?>{
          'session': _sessionLabel,
          'pid': target.pid,
          'window_id': target.windowId,
          'delivery_mode': deliveryMode,
        };

        switch (cuaTool) {
          case 'click' || 'double_click' || 'right_click':
            if (input['elementToken'] != null) {
              args['element_token'] = input['elementToken'];
            } else {
              if (input['x'] != null) args['x'] = input['x'];
              if (input['y'] != null) args['y'] = input['y'];
            }
          case 'type_text':
            args['text'] = input['text'] as String? ?? '';
            if (input['elementToken'] != null) {
              args['element_token'] = input['elementToken'];
            } else {
              if (input['x'] != null) args['x'] = input['x'];
              if (input['y'] != null) args['y'] = input['y'];
            }
          case 'press_key':
            args['key'] = input['key'] as String? ?? '';
            if (input['modifiers'] != null) {
              args['modifiers'] = input['modifiers'];
            }
            if (input['elementToken'] != null) {
              args['element_token'] = input['elementToken'];
            }
          case 'hotkey':
            args['keys'] = input['keys'] ?? const <String>[];
            if (input['elementToken'] != null) {
              args['element_token'] = input['elementToken'];
            }
          case 'scroll':
            final dy = (input['deltaY'] as num?)?.toDouble();
            final dir =
                input['direction'] as String? ??
                (dy != null && dy < 0 ? 'up' : 'down');
            args['direction'] = dir;
            if (input['amount'] != null) {
              args['amount'] = input['amount'];
            } else if (dy != null) {
              args['amount'] = dy.abs().round().clamp(1, 20);
            }
            if (input['elementToken'] != null) {
              args['element_token'] = input['elementToken'];
            } else {
              if (input['x'] != null) args['x'] = input['x'];
              if (input['y'] != null) args['y'] = input['y'];
            }
          case 'drag':
            args['from_x'] = input['x'] ?? 0;
            args['from_y'] = input['y'] ?? 0;
            args['to_x'] = input['toX'] ?? 0;
            args['to_y'] = input['toY'] ?? 0;
          default:
            throw ArgumentError('Unsupported desktop action: $action');
        }

        final res = await CuaDriverService.instance.callTool(cuaTool, args);
        if (!res.ok) {
          throw StateError(
            res.stderr.isEmpty
                ? 'cua-driver action $cuaTool failed.'
                : res.stderr,
          );
        }
        return res.stdout.isEmpty ? 'OK ($cuaTool)' : res.stdout;
      },
    ),
    ClaudeSdkTool(
      name: 'computer_get_desktop_state',
      description:
          'Capture the full desktop display when the user explicitly enabled and started full-screen sharing.',
      kind: ToolKind.other,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'maxImageDimension': {
            'type': 'integer',
            'description': 'Optional max image edge length in pixels.',
          },
        },
      },
      summary: (_, _) => 'Inspect full desktop screen',
      run: (input, call) async {
        final ctrl = ComputerUseController.instance;
        if (!ctrl.config.enabled ||
            !ctrl.config.allowFullScreen ||
            !ctrl.fullScreenShared) {
          throw StateError(
            'Full-screen sharing is not active. Enable it in Settings → Computer Use and turn it on from the Computer Use pill.',
          );
        }
        ctrl.markFullScreenAccessed();
        final tmpShot = p.join(
          Directory.systemTemp.path,
          'ayte_cu_desktop_${DateTime.now().millisecondsSinceEpoch}.png',
        );
        final res = await CuaDriverService.instance.callTool(
          'get_desktop_state',
          {
            'session': _sessionLabel,
            'screenshot_out_file': tmpShot,
            if (input['maxImageDimension'] != null)
              'max_image_dimension': input['maxImageDimension'],
          },
          screenshotOutFile: tmpShot,
        );
        if (!res.ok) {
          throw StateError(
            res.stderr.isEmpty ? 'get_desktop_state failed.' : res.stderr,
          );
        }
        final blocks = <Map<String, Object?>>[];
        if (res.stdout.isNotEmpty) blocks.add(claudeSdkText(res.stdout));
        final img = await _readImageAndDelete(tmpShot);
        if (img != null) blocks.add(img);
        return blocks.isEmpty ? 'OK' : blocks;
      },
    ),
  ];
}
