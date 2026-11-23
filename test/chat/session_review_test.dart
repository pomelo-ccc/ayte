import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _NoStore implements ReviewStore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A review that records what the session asks of it.
class _Review extends ChangeReview {
  _Review() : super(_NoStore(), root: '/p');

  final calls = <String>[];
  Completer<void>? holdBefore;
  List<FileChange> listed = const [];

  @override
  List<FileChange> get changes => listed;

  void list(List<FileChange> changes) {
    listed = changes;
    notifyListeners();
  }

  @override
  Future<void> before(String path, {String? turn}) async {
    calls.add('before $path');
    await holdBefore?.future;
  }

  @override
  Future<void> after(String path, {String? turn}) async =>
      calls.add('after $path');

  @override
  void report(FileChange change, {FileOriginal? original}) =>
      calls.add('report ${change.path}');

  @override
  Future<void> look() async => calls.add('look');

  @override
  Future<void> keep(Iterable<String> paths) async =>
      calls.add('keep ${paths.join(',')}');

  @override
  Future<void> keepAll() async => calls.add('keepAll');

  @override
  Future<void> undo(Iterable<String> paths) async =>
      calls.add('undo ${paths.join(',')}');

  @override
  Future<void> undoAll() async => calls.add('undoAll');
}

void main() {
  late _Review review;

  Future<ChatSession> pump(WidgetTester tester) async {
    review = _Review();
    final session = ChatSession(
      kernel: MockKernels.claudeCode,
      kernelContext: const KernelContext(cwd: '/p'),
      historyCount: 0,
      openReview: (root, {session}) async => review,
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: ChatScreen(session: session),
      ),
    );
    await tester.pump();
    return session;
  }

  Future<void> finish(WidgetTester tester, ChatSession session) async {
    // The message goes once the snapshot before it is taken.
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 400 && session.isStreaming; i++) {
      switch (session.pendingInteraction) {
        case QuestionRequest():
          session.answer(const QuestionAnswer([], skipped: true));
        case ApprovalRequest():
          session.answer(const ApprovalAnswer(ApprovalDecision.allowOnce));
        default:
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('each edit waits on the review keeping what its file was, '
      'and is told it once made', (tester) async {
    final session = await pump(tester);
    review.holdBefore = Completer();
    session.send(const ComposerMessage(text: '把输入框改成随内容增高'));
    for (var i = 0; i < 400 && review.calls.isEmpty; i++) {
      switch (session.pendingInteraction) {
        case QuestionRequest():
          session.answer(const QuestionAnswer([], skipped: true));
        case ApprovalRequest():
          session.answer(const ApprovalAnswer(ApprovalDecision.allowOnce));
        default:
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    // As the CLI tells it (the mock's, relative).
    const first = 'lib/chat/composer/composer.dart';
    expect(review.calls, ['before $first']);
    // The edit waits.
    await tester.pump(const Duration(seconds: 1));
    expect(review.calls, ['before $first']);
    expect(session.fileChanges, isEmpty);

    review.holdBefore!.complete();
    await finish(tester, session);
    expect(
      review.calls,
      containsAllInOrder([
        'before $first',
        'after $first',
        'report $first',
        'before lib/chat/chat_screen.dart',
        'after lib/chat/chat_screen.dart',
      ]),
    );
    // Its files looked at again as the turn ended.
    expect(review.calls.last, 'look');
    // Its background tests settle.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the changes, and Keep and Undo, are the review\'s', (
    tester,
  ) async {
    final session = await pump(tester);
    session.send(const ComposerMessage(text: '把输入框改成随内容增高'));
    await finish(tester, session);

    const change = FileChange(path: '/p/lib/a.dart', added: 2, removed: 1);
    review.list(const [change]);
    await tester.pump();
    expect(session.fileChanges, [change]);
    expect(find.text('1 file changed'), findsOneWidget);

    session.keepChanges(const [change]);
    session.undoChanges!(const [change]);
    session.undoAllChanges!();
    await tester.tap(find.text('Keep all'));
    expect(
      review.calls,
      containsAllInOrder([
        'keep /p/lib/a.dart',
        'undo /p/lib/a.dart',
        'undoAll',
        'keepAll',
      ]),
    );

    // Failed, it gives way to what the kernel reported.
    review.abandon('gone');
    await tester.pump();
    expect(session.fileChanges, isNot([change]));
    expect(session.undoChanges, isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  test('ChangeReview deduplicates Windows case-variant paths across before/after, report, baseOf, keep, undo, rewind, and resume', () async {
    final store = _MemoryWindowsReviewStore();
    store.files[r'c:\repo\lib\a.dart'] = 'base1\nbase2\n';

    final review = ChangeReview(
      store,
      root: r'C:\Repo',
      paths: p.windows,
    );
    addTearDown(review.dispose);
    review.session = 'win-case-session';

    // Tracked edit: before with relative/root casing, after with lowercase drive + forward slashes.
    await review.before('lib/a.dart', turn: 't1');
    store.files[r'c:\repo\lib\a.dart'] = 'edit1\nbase2\n';
    await review.after(r'c:/Repo/lib/a.dart', turn: 't1');

    // Second tracked edit on same file with uppercase path variant.
    await review.before(r'C:\REPO\LIB\A.DART', turn: 't2');
    store.files[r'c:\repo\lib\a.dart'] = 'edit1\nedit2\n';
    await review.after(r'c:\repo\lib\a.dart', turn: 't2');

    // Untracked reports with mixed casing.
    review.report(
      const FileChange(path: r'C:\Repo\lib\other2.dart', added: 1, removed: 0),
    );
    review.report(
      const FileChange(path: r'c:\repo\lib\other2.dart', added: 2, removed: 0),
    );
    await review.keep(const []);

    expect(review.changes, hasLength(2));
    expect(
      review.changes.map((c) => c.path).toList(),
      [r'C:\Repo\lib\a.dart', r'C:\Repo\lib\other2.dart'],
    );
    expect(review.changes[1].added, 3);
    expect(review.baseOf(r'c:\repo\lib\a.dart'), isNotNull);
    expect(await review.original(r'c:/Repo/lib/a.dart')!(), 'base1\nbase2\n');

    // Rewind t2 via persisted/canonical turn map and verify file + pending change.
    await review.rewind({'t2'});
    expect(store.files[r'c:\repo\lib\a.dart'], 'edit1\nbase2\n');
    expect(review.changes.first.path, r'C:\Repo\lib\a.dart');

    // Resume from persisted state and keep via lowercase variant.
    final reopened = await ChangeReview.resume(
      store,
      'win-case-session',
      root: r'C:\Repo',
      paths: p.windows,
    );
    addTearDown(reopened.dispose);
    expect(reopened.changes, hasLength(2));
    await reopened.keep([r'c:\repo\lib\other2.dart']);
    expect(reopened.changes.map((c) => c.path), [r'C:\Repo\lib\a.dart']);

    // Undo via lowercase variant restores original and clears entry.
    await reopened.undo([r'c:/Repo/lib/a.dart']);
    expect(store.files[r'c:\repo\lib\a.dart'], 'base1\nbase2\n');
    expect(reopened.changes, isEmpty);
  });
}

class _MemoryWindowsReviewStore implements ReviewStore {
  final Map<String, String> files = {};
  final Map<String, Uint8List> blobs = {};
  final Map<String, String> sessions = {};
  int _nextOid = 1;

  String _key(String path) => p.windows.canonicalize(path);

  @override
  Future<ReviewBlob?> take(String path) async {
    final text = files[_key(path)];
    if (text == null) return null;
    return store(Uint8List.fromList(utf8.encode(text)), mode: '100644');
  }

  @override
  Future<ReviewBlob?> current(String path) async {
    final text = files[_key(path)];
    if (text == null) return null;
    for (final entry in blobs.entries) {
      if (utf8.decode(entry.value) == text) {
        return ReviewBlob('100644', entry.key);
      }
    }
    return store(Uint8List.fromList(utf8.encode(text)), mode: '100644');
  }

  @override
  Future<Uint8List> read(ReviewBlob blob) async => blobs[blob.oid]!;

  @override
  Future<ReviewBlob> store(Uint8List bytes, {required String mode}) async {
    final text = utf8.decode(bytes);
    for (final entry in blobs.entries) {
      if (utf8.decode(entry.value) == text) {
        return ReviewBlob(mode, entry.key);
      }
    }
    final oid = 'oid_${_nextOid++}';
    blobs[oid] = bytes;
    return ReviewBlob(mode, oid);
  }

  @override
  Future<void> restore(String path, ReviewBlob? blob, {String? root}) async {
    final k = _key(path);
    if (blob == null) {
      files.remove(k);
    } else {
      files[k] = utf8.decode(blobs[blob.oid]!);
    }
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    files[_key(path)] = utf8.decode(bytes);
  }

  @override
  Future<Uint8List?> merge(ReviewBlob mine, ReviewBlob from, ReviewBlob to) async =>
      null;

  @override
  Future<({int added, int removed})?> lineCounts(
    ReviewBlob? from,
    ReviewBlob? to,
  ) async {
    final a = from == null ? const <String>[] : utf8.decode(blobs[from.oid]!).split('\n');
    final b = to == null ? const <String>[] : utf8.decode(blobs[to.oid]!).split('\n');
    return (added: b.length, removed: a.length);
  }

  @override
  Future<String?> load(String session) async => sessions[session];

  @override
  Future<void> save(
    String session,
    String data, {
    required Iterable<ReviewBlob> blobs,
  }) async {
    sessions[session] = data;
  }

  @override
  Future<void> forget(String session) async {
    sessions.remove(session);
  }
}
