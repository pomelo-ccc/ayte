import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'embedded_browser_native.dart';

typedef _FreeStrNative = Void Function(Pointer<Uint8>);
typedef _FreeStrDart = void Function(Pointer<Uint8>);
typedef _CreateNative =
    Int32 Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Int32,
      Int32,
      Int32,
    );
typedef _CreateDart =
    int Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      int,
      int,
    );
typedef _SetFrameNative =
    Void Function(Pointer<Uint8>, Double, Double, Double, Double, Int32);
typedef _SetFrameDart =
    void Function(Pointer<Uint8>, double, double, double, double, int);
typedef _TwoStrNative = Void Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _TwoStrDart = void Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _ThreeStrNative =
    Void Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _ThreeStrDart =
    void Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _OneStrVoidNative = Void Function(Pointer<Uint8>);
typedef _OneStrVoidDart = void Function(Pointer<Uint8>);
typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();
typedef _OneStrRetNative = Pointer<Uint8> Function(Pointer<Uint8>);
typedef _OneStrRetDart = Pointer<Uint8> Function(Pointer<Uint8>);

typedef _CallocNative = Pointer<Uint8> Function(IntPtr, IntPtr);
typedef _CallocDart = Pointer<Uint8> Function(int, int);
typedef _LibcFreeNative = Void Function(Pointer<Uint8>);
typedef _LibcFreeDart = void Function(Pointer<Uint8>);

final _libc = Platform.isMacOS ? DynamicLibrary.process() : null;
final _calloc = _libc?.lookupFunction<_CallocNative, _CallocDart>('calloc');
final _libcFree = _libc?.lookupFunction<_LibcFreeNative, _LibcFreeDart>('free');

DynamicLibrary? _nativeLib;
bool _attempted = false;
int _reqSeq = 0;

DynamicLibrary? _lib() {
  if (_attempted) return _nativeLib;
  _attempted = true;
  if (!Platform.isMacOS || Platform.environment.containsKey('FLUTTER_TEST')) {
    return null;
  }
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final candidates = [
    p.normalize(p.join(exeDir, '..', 'Frameworks', 'libAyteNative.dylib')),
    p.join(exeDir, 'libAyteNative.dylib'),
  ];
  for (final path in candidates) {
    if (!File(path).existsSync()) continue;
    try {
      _nativeLib = DynamicLibrary.open(path);
      return _nativeLib;
    } on Object {
      // Try next candidate.
    }
  }
  return null;
}

Pointer<Uint8> _toCString(String text) {
  final bytes = utf8.encode(text);
  final ptr = _calloc!(bytes.length + 1, 1);
  final view = ptr.asTypedList(bytes.length + 1);
  view.setRange(0, bytes.length, bytes);
  view[bytes.length] = 0;
  return ptr;
}

String _fromCStringAndFree(DynamicLibrary lib, Pointer<Uint8> ptr) {
  if (ptr == nullptr) return '';
  try {
    var len = 0;
    while (ptr[len] != 0) {
      len++;
    }
    final bytes = Uint8List.fromList(ptr.asTypedList(len));
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    final freeFn = lib.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'AyteNativeFreeString',
    );
    freeFn(ptr);
  }
}

bool get supported => Platform.isMacOS && _lib() != null;

bool createTab({
  required String tabId,
  required String profileId,
  required String url,
  required bool googleSignInCompat,
  required bool inspectorEnabled,
  required bool detached,
}) {
  final lib = _lib();
  if (lib == null || _calloc == null || _libcFree == null) return false;
  final pTab = _toCString(tabId);
  final pProfile = _toCString(profileId);
  final pUrl = _toCString(url);
  try {
    final fn = lib.lookupFunction<_CreateNative, _CreateDart>(
      'AyteWebViewCreate',
    );
    return fn(
          pTab,
          pProfile,
          pUrl,
          googleSignInCompat ? 1 : 0,
          inspectorEnabled ? 1 : 0,
          detached ? 1 : 0,
        ) !=
        0;
  } finally {
    _libcFree!(pTab);
    _libcFree!(pProfile);
    _libcFree!(pUrl);
  }
}

void setFrame({
  required String tabId,
  required double x,
  required double y,
  required double width,
  required double height,
  required bool visible,
}) {
  final lib = _lib();
  if (lib == null || _calloc == null || _libcFree == null) return;
  final pTab = _toCString(tabId);
  try {
    final fn = lib.lookupFunction<_SetFrameNative, _SetFrameDart>(
      'AyteWebViewSetFrame',
    );
    fn(pTab, x, y, width, height, visible ? 1 : 0);
  } finally {
    _libcFree!(pTab);
  }
}

void navigate(String tabId, String url) {
  final lib = _lib();
  if (lib == null || _calloc == null || _libcFree == null) return;
  final pTab = _toCString(tabId);
  final pUrl = _toCString(url);
  try {
    final fn = lib.lookupFunction<_TwoStrNative, _TwoStrDart>(
      'AyteWebViewNavigate',
    );
    fn(pTab, pUrl);
  } finally {
    _libcFree!(pTab);
    _libcFree!(pUrl);
  }
}

void action(String tabId, String actionName) {
  final lib = _lib();
  if (lib == null || _calloc == null || _libcFree == null) return;
  final pTab = _toCString(tabId);
  final pAct = _toCString(actionName);
  try {
    final fn = lib.lookupFunction<_TwoStrNative, _TwoStrDart>(
      'AyteWebViewAction',
    );
    fn(pTab, pAct);
  } finally {
    _libcFree!(pTab);
    _libcFree!(pAct);
  }
}

void hideAll() {
  final lib = _lib();
  if (lib == null) return;
  final fn = lib.lookupFunction<_VoidNative, _VoidDart>('AyteWebViewHideAll');
  fn();
}

NativeWebTabState getState(String tabId) {
  final lib = _lib();
  if (lib == null || _calloc == null || _libcFree == null) {
    return const NativeWebTabState(exists: false);
  }
  final pTab = _toCString(tabId);
  try {
    final fn = lib.lookupFunction<_OneStrRetNative, _OneStrRetDart>(
      'AyteWebViewGetState',
    );
    final raw = _fromCStringAndFree(lib, fn(pTab));
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, Object?>) {
      return NativeWebTabState.fromJson(decoded);
    }
    return const NativeWebTabState(exists: false);
  } on Object {
    return const NativeWebTabState(exists: false);
  } finally {
    _libcFree!(pTab);
  }
}

Future<String> _pollResult(
  DynamicLibrary lib,
  String reqId,
  Duration timeout,
) async {
  final pollFn = lib.lookupFunction<_OneStrRetNative, _OneStrRetDart>(
    'AyteWebViewPollResult',
  );
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final pReq = _toCString(reqId);
    String raw;
    try {
      raw = _fromCStringAndFree(lib, pollFn(pReq));
    } finally {
      _libcFree!(pReq);
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map && decoded['done'] == true) {
      if (decoded['error'] case final String err when err.isNotEmpty) {
        throw StateError(err);
      }
      return decoded['value'] as String? ?? '';
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  throw TimeoutException('Embedded browser operation timed out.');
}

Future<String> evalJs(
  String tabId,
  String script, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final lib = _lib();
  if (lib == null || _calloc == null || _libcFree == null) {
    throw UnsupportedError('Embedded WKWebView bridge is unavailable.');
  }
  final reqId = 'js_${++_reqSeq}_${DateTime.now().microsecondsSinceEpoch}';
  final pTab = _toCString(tabId);
  final pReq = _toCString(reqId);
  final pScript = _toCString(script);
  try {
    final fn = lib.lookupFunction<_ThreeStrNative, _ThreeStrDart>(
      'AyteWebViewEvalJs',
    );
    fn(pTab, pReq, pScript);
  } finally {
    _libcFree!(pTab);
    _libcFree!(pReq);
    _libcFree!(pScript);
  }
  return _pollResult(lib, reqId, timeout);
}

Future<String> takeSnapshot(
  String tabId,
  String outputPath, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final lib = _lib();
  if (lib == null || _calloc == null || _libcFree == null) {
    throw UnsupportedError('Embedded WKWebView bridge is unavailable.');
  }
  final reqId = 'snap_${++_reqSeq}_${DateTime.now().microsecondsSinceEpoch}';
  final pTab = _toCString(tabId);
  final pReq = _toCString(reqId);
  final pPath = _toCString(outputPath);
  try {
    final fn = lib.lookupFunction<_ThreeStrNative, _ThreeStrDart>(
      'AyteWebViewTakeSnapshot',
    );
    fn(pTab, pReq, pPath);
  } finally {
    _libcFree!(pTab);
    _libcFree!(pReq);
    _libcFree!(pPath);
  }
  return _pollResult(lib, reqId, timeout);
}

void clearProfile(String profileId) {
  final lib = _lib();
  if (lib == null || _calloc == null || _libcFree == null) return;
  final pProfile = _toCString(profileId);
  try {
    final fn = lib.lookupFunction<_OneStrVoidNative, _OneStrVoidDart>(
      'AyteWebViewClearProfile',
    );
    fn(pProfile);
  } finally {
    _libcFree!(pProfile);
  }
}
