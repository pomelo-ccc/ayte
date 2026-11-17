import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';

void main() {
  group('AntigravityTransport tool mapping & normalization', () {
    test('normalizeToolParams decodes JSON-encoded parameter values', () {
      final raw = <String, Object?>{
        'Path': '"/workspace/app/package.json"',
        'StartLine': '1',
        'EndLine': '80',
        'IsDaemon': 'true',
        'PlainString': 'unquoted-value',
      };
      final normalized = AntigravityTransport.normalizeToolParams(raw);
      expect(normalized['Path'], '/workspace/app/package.json');
      expect(normalized['StartLine'], 1);
      expect(normalized['EndLine'], 80);
      expect(normalized['IsDaemon'], true);
      expect(normalized['PlainString'], 'unquoted-value');
    });

    test('cleanToolOutput strips Created At / Completed At headers', () {
      const rawRead =
          'Created At: 2026-11-07T08:40:27+08:00\n'
          'Completed At: 2026-11-07T08:40:27+08:00\n'
          'Showing lines 1-3 of 3\n'
          '1: {\n2:   "name": "demo"\n3: }';
      expect(
        AntigravityTransport.cleanToolOutput('read_file', rawRead),
        'Showing lines 1-3 of 3\n1: {\n2:   "name": "demo"\n3: }',
      );

      const rawBash =
          'Created At: 2026-11-07T08:40:27+08:00\n'
          'Completed At: 2026-11-07T08:40:28+08:00\n'
          'Command exited with code 0.\n\n'
          'Command output:\n'
          'HTTP/1.1 200 OK';
      expect(
        AntigravityTransport.cleanToolOutput('run_command', rawBash),
        'HTTP/1.1 200 OK',
      );
    });

    test('mapTool translates read_file, edit_file, and run_command', () {
      final readMapped = AntigravityTransport.mapTool(
        'read_file',
        {
          'Path': '"/workspace/app/package.json"',
          'StartLine': '10',
          'EndLine': '29',
        },
        '10: line',
      );
      expect(readMapped.name, 'Read');
      expect(readMapped.input, {
        'file_path': '/workspace/app/package.json',
        'offset': 10,
        'limit': 20,
      });

      final editMapped = AntigravityTransport.mapTool(
        'edit_file',
        {
          'Path': '"/workspace/app/README.md"',
          'Target': '"old line"',
          'Replacement': '"new line"',
        },
        'Made 1 replacement',
      );
      expect(editMapped.name, 'Edit');
      expect(editMapped.input['file_path'], '/workspace/app/README.md');
      expect(editMapped.input['old_string'], 'old line');
      expect(editMapped.input['new_string'], 'new line');
      expect(editMapped.structuredResult, isNotNull);

      final bashMapped = AntigravityTransport.mapTool(
        'run_command',
        {
          'CommandLine': '"pnpm run dev:docs"',
          'toolSummary': '"Start docs server"',
        },
        'Server listening on 5173',
      );
      expect(bashMapped.name, 'Bash');
      expect(bashMapped.input['command'], 'pnpm run dev:docs');
      expect(bashMapped.input['description'], 'Start docs server');
    });
  });
}
