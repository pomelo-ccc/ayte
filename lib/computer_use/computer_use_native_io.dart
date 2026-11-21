import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'computer_use_native.dart';

typedef _FreeStrNative = Void Function(Pointer<Uint8>);
typedef _FreeStrDart = void Function(Pointer<Uint8>);
typedef _CheckPermsNative = Pointer<Uint8> Function();
typedef _CheckPermsDart = Pointer<Uint8> Function();
typedef _ReqPermNative = Int32 Function();
typedef _ReqPermDart = int Function();
typedef _OpenPaneNative = Void Function(Pointer<Uint8>);
typedef _OpenPaneDart = void Function(Pointer<Uint8>);
typedef _ListWinNative = Pointer<Uint8> Function();
typedef _ListWinDart = Pointer<Uint8> Function();
typedef _CaptureWinNative = Int32 Function(Int32, Pointer<Uint8>);
typedef _CaptureWinDart = int Function(int, Pointer<Uint8>);
typedef _RegHotKeyNative = Int32 Function(Int32, Int32);
typedef _RegHotKeyDart = int Function(int, int);
typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();
typedef _PollStopNative = Int32 Function();
typedef _PollStopDart = int Function();
typedef _ShowBarNative = Void Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _ShowBarDart = void Function(Pointer<Uint8>, Pointer<Uint8>);

typedef _CallocNative = Pointer<Uint8> Function(IntPtr, IntPtr);
typedef _CallocDart = Pointer<Uint8> Function(int, int);
typedef _LibcFreeNative = Void Function(Pointer<Uint8>);
typedef _LibcFreeDart = void Function(Pointer<Uint8>);

final _libc = Platform.isMacOS ? DynamicLibrary.process() : null;
final _calloc = _libc?.lookupFunction<_CallocNative, _CallocDart>('calloc');
final _libcFree = _libc?.lookupFunction<_LibcFreeNative, _LibcFreeDart>('free');

DynamicLibrary? _nativeLib;
bool _attempted = false;

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

ComputerUsePermissions checkPermissions() {
  final lib = _lib();
  if (lib == null) {
    return const ComputerUsePermissions(
      accessibility: false,
      screenRecording: false,
    );
  }
  try {
    final fn = lib.lookupFunction<_CheckPermsNative, _CheckPermsDart>(
      'AyteCuCheckPermissions',
    );
    final raw = _fromCStringAndFree(lib, fn());
    final map = jsonDecode(raw) as Map<String, Object?>;
    return ComputerUsePermissions(
      accessibility: map['accessibility'] == true,
      screenRecording: map['screenRecording'] == true,
      pid: (map['pid'] as num?)?.toInt() ?? 0,
      bundleId: map['bundleId'] as String? ?? '',
    );
  } on Object {
    return const ComputerUsePermissions(
      accessibility: false,
      screenRecording: false,
    );
  }
}

bool requestAccessibility() {
  final lib = _lib();
  if (lib == null) return false;
  final fn = lib.lookupFunction<_ReqPermNative, _ReqPermDart>(
    'AyteCuRequestAccessibility',
  );
  return fn() != 0;
}

bool requestScreenRecording() {
  final lib = _lib();
  if (lib == null) return false;
  final fn = lib.lookupFunction<_ReqPermNative, _ReqPermDart>(
    'AyteCuRequestScreenRecording',
  );
  return fn() != 0;
}

void openPrivacyPane(String pane) {
  final lib = _lib();
  if (lib == null || _calloc == null || _libcFree == null) return;
  final ptr = _toCString(pane);
  try {
    final fn = lib.lookupFunction<_OpenPaneNative, _OpenPaneDart>(
      'AyteCuOpenPrivacyPane',
    );
    fn(ptr);
  } finally {
    _libcFree!(ptr);
  }
}

List<DesktopWindowInfo> listWindows() {
  final lib = _lib();
  if (lib == null) return const [];
  try {
    final fn = lib.lookupFunction<_ListWinNative, _ListWinDart>(
      'AyteCuListWindows',
    );
    final raw = _fromCStringAndFree(lib, fn());
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (item is Map<String, Object?>) DesktopWindowInfo.fromJson(item),
    ];
  } on Object {
    return const [];
  }
}

bool captureWindow(int windowId, String outputPath) {
  final lib = _lib();
  if (lib == null || _calloc == null || _libcFree == null) return false;
  final ptr = _toCString(outputPath);
  try {
    final fn = lib.lookupFunction<_CaptureWinNative, _CaptureWinDart>(
      'AyteCuCaptureWindow',
    );
    return fn(windowId, ptr) != 0;
  } finally {
    _libcFree!(ptr);
  }
}

bool registerStopHotkey(int keyCode, int carbonModifiers) {
  final lib = _lib();
  if (lib == null) return false;
  final fn = lib.lookupFunction<_RegHotKeyNative, _RegHotKeyDart>(
    'AyteCuRegisterStopHotkey',
  );
  return fn(keyCode, carbonModifiers) != 0;
}

void unregisterStopHotkey() {
  final lib = _lib();
  if (lib == null) return;
  final fn = lib.lookupFunction<_VoidNative, _VoidDart>(
    'AyteCuUnregisterStopHotkey',
  );
  fn();
}

bool pollStopEvent() {
  final lib = _lib();
  if (lib == null) return false;
  final fn = lib.lookupFunction<_PollStopNative, _PollStopDart>(
    'AyteCuPollStopEvent',
  );
  return fn() != 0;
}

void showStopBar(String statusText, String stopLabel) {
  final lib = _lib();
  if (lib == null || _calloc == null || _libcFree == null) return;
  final pStatus = _toCString(statusText);
  final pStop = _toCString(stopLabel);
  try {
    final fn = lib.lookupFunction<_ShowBarNative, _ShowBarDart>(
      'AyteCuShowStopBar',
    );
    fn(pStatus, pStop);
  } finally {
    _libcFree!(pStatus);
    _libcFree!(pStop);
  }
}

void hideStopBar() {
  final lib = _lib();
  if (lib == null) return;
  final fn = lib.lookupFunction<_VoidNative, _VoidDart>('AyteCuHideStopBar');
  fn();
}
