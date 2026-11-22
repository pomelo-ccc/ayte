import AudioToolbox
import AVFoundation
import Carbon
import Cocoa
import CoreAudio
import FlutterMacOS
import Vision

/// A window that is a view of the app's one engine: the app's own windows
/// (BaoWindow) and the stash's panel, which is not one of them.
protocol FlutterHostWindow: NSWindow {
  var viewId: Int64 { get }
}

extension BaoWindow: FlutterHostWindow {}

/// The stash's panel (see lib/stash/, docs/stash.md): a view of the app's
/// engine in a panel shown in front of every app, on every Space, without
/// bringing the app in front (an ordinary window's level, not kept above
/// the others once the user goes on in another app, unless pinned): the app the user was in stays the active one,
/// and has the keyboard back once the panel goes. Not in the Dock's or the
/// Window menu's lists. Made once, hidden, and shown again at once each
/// time the shortcut is pressed.
final class StashPanel: NSPanel, FlutterHostWindow {
  static let defaultSize = NSSize(width: 560, height: 420)
  static let minimumSize = NSSize(width: 380, height: 220)

  /// Where its place and size are kept (the user defaults'), for the next
  /// launch.
  private static let frameName = "BaoCodeStashPanel"

  /// The app's one panel, once made.
  private(set) static weak var current: StashPanel?

  /// Whether it has a place of its own yet (kept, or given once):
  /// centered on the screen until it does.
  private var placed = false

  private(set) var flutterViewController: FlutterViewController?
  private var channel: FlutterMethodChannel?
  private var drops: FileDropView?

  var viewId: Int64 { flutterViewController?.viewIdentifier ?? -1 }

  init(flutter: FlutterViewController) {
    super.init(
      contentRect: NSRect(origin: .zero, size: Self.defaultSize),
      styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    flutterViewController = flutter
    isReleasedWhenClosed = false
    isRestorable = false
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      standardWindowButton(button)?.isHidden = true
    }
    isMovableByWindowBackground = true
    level = .normal
    hidesOnDeactivate = false
    isFloatingPanel = false
    becomesKeyOnlyIfNeeded = false
    worksWhenModal = true
    isExcludedFromWindowsMenu = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    animationBehavior = .utilityWindow
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    appearance = NSAppearance(named: BaoWindow.keptDarkAppearance ? .darkAqua : .aqua)
    flutter.backgroundColor = .clear
    // The main window's material under it, as the conversation has it
    // there (AppColors.conversationSurface tints it).
    contentViewController = StashContent(flutter: flutter, size: Self.defaultSize)
    setContentSize(Self.defaultSize)
    contentMinSize = Self.minimumSize

    let messenger = flutter.engine.binaryMessenger
    let suffix = ".\(flutter.viewIdentifier)"
    let drops = FileDropView(channel: FlutterMethodChannel(
      name: "baocode/drop" + suffix, binaryMessenger: messenger))
    drops.frame = flutter.view.bounds
    drops.autoresizingMask = [.width, .height]
    flutter.view.addSubview(drops)
    self.drops = drops

    // Where the user left it, as big as they made it.
    placed = setFrameUsingName(Self.frameName)
    setFrameAutosaveName(Self.frameName)
    Self.current = self

    let channel = FlutterMethodChannel(name: "baocode/window" + suffix, binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      self.handle(call, result: result)
    }
  }

  /// Takes the keyboard without the app coming in front.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// Where it was left (moved or resized by the user, kept across
  /// launches); in the middle of the screen the mouse is on the first
  /// time, or when where it was is on no screen now.
  func present() {
    let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    if !placed || !onScreen {
      let mouse = NSEvent.mouseLocation
      let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
      if let visible = screen?.visibleFrame {
        let origin = NSPoint(
          x: visible.midX - frame.width / 2,
          y: max(visible.minY, min(visible.midY - frame.height / 2, visible.maxY - frame.height)))
        setFrameOrigin(origin)
        placed = true
      }
    }
    syncScale()
    // Light or dark as the color theme is now, as the app's windows are.
    appearance = NSAppearance(named: BaoWindow.keptDarkAppearance ? .darkAqua : .aqua)
    makeKeyAndOrderFront(nil)
    orderFrontRegardless()
  }

  /// ⌘W, ⌘S and ⌘N are the panel's (close, save, a new stash), ahead of
  /// the app's menu, whose commands go to its windows.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
      let commands = ["w": "baocode.stash.close", "s": "baocode.stash.save", "n": "baocode.stash.new"]
      if let command = commands[key] {
        menuCommand(command)
        return true
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  /// A command of the app's menu, or one of its own, for Flutter.
  func menuCommand(_ command: String) {
    channel?.invokeMethod("menuCommand", arguments: command)
  }

  /// Hidden; the app that was in front has the keyboard again, as it never
  /// lost being the active one.
  func dismiss() {
    orderOut(nil)
  }

  /// Escape, as a panel's: Flutter decides (it saves first).
  override func cancelOperation(_ sender: Any?) {
    menuCommand("baocode.stash.close")
  }

  private func syncScale() {
    guard let flutter = flutterViewController,
          flutter.responds(to: NSSelectorFromString("flutterView")),
          let view = flutter.value(forKey: "flutterView") as? NSView,
          let layer = view.layer
    else { return }
    let scale = backingScaleFactor
    guard layer.contentsScale != scale else { return }
    layer.contentsScale = scale
    view.viewDidChangeBackingProperties()
  }

  func tearDown() {
    channel?.setMethodCallHandler(nil)
    drops?.stop()
  }

  // The Edit menu's commands, as BaoWindow's.
  @objc func baocodeUndo(_ sender: Any?) { editCommand("undo") }
  @objc func baocodeRedo(_ sender: Any?) { editCommand("redo") }
  @objc func baocodeCut(_ sender: Any?) { editCommand("cut") }
  @objc func baocodeCopy(_ sender: Any?) { editCommand("copy") }
  @objc func baocodePaste(_ sender: Any?) { editCommand("paste") }
  @objc func baocodeSelectAll(_ sender: Any?) { editCommand("selectAll") }

  private func editCommand(_ command: String) {
    channel?.invokeMethod("editCommand", arguments: command)
  }

  /// What the panel's view asks of its window: the clipboard's pictures
  /// and files, files to pick, a context menu; the rest as BaoWindow
  /// answers it, where it applies to a panel.
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "readPasteboardImages":
      result(BaoWindow.pasteboardImages())
    case "readPasteboardFiles":
      result(FileDropView.files(on: NSPasteboard.general))
    case "readImageFile":
      guard let path = call.arguments as? String else {
        result(nil)
        return
      }
      result(BaoWindow.image(at: URL(fileURLWithPath: path)))
    case "canPaste":
      result(NSPasteboard.general.canReadObject(
        forClasses: [NSString.self, NSURL.self, NSImage.self], options: nil))
    case "writePasteboardMarkdown":
      result(BaoWindow.writePasteboardMarkdown(call.arguments as? [String: Any] ?? [:]))
    case "readPasteboardMarkdown":
      result(BaoWindow.readPasteboardMarkdown())
    case "writePasteboardImage":
      guard let arguments = call.arguments as? [String: Any],
            let bytes = arguments["bytes"] as? FlutterStandardTypedData
      else {
        result(false)
        return
      }
      result(BaoWindow.writePasteboardImage(
        bytes.data, png: arguments["type"] as? String == "image/png"))
    case "pickFiles":
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = true
      panel.beginSheetModal(for: self) { response in
        result(response == .OK ? panel.urls.map(FileDropView.entry) : [])
      }
    case "armFileDrag":
      let paths = (call.arguments as? [String: Any])?["paths"] as? [String]
      drops?.arm(paths, flutter: flutterViewController)
      result(drops != nil)
    case "disarmFileDrag":
      drops?.disarm()
      result(nil)
    case "startFileDrag":
      let paths = (call.arguments as? [String: Any])?["paths"] as? [String] ?? []
      result(drops?.drag(paths, flutter: flutterViewController) ?? false)
    case "revealInFinder":
      if let path = call.arguments as? String {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      }
      result(nil)
    case "showContextMenu":
      guard let arguments = call.arguments as? [String: Any],
            let items = arguments["items"] as? [[String: Any]],
            let x = arguments["x"] as? Double, let y = arguments["y"] as? Double,
            let view = flutterViewController?.view
      else {
        result(nil)
        return
      }
      let point = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
      ContextMenu(items: items, answer: result).show(at: point, in: view)
    case "dragWindow":
      // Its top bar, pressed: moved as a title bar moves its window.
      if let event = NSApp.currentEvent,
         [.leftMouseDown, .leftMouseDragged].contains(event.type) {
        performDrag(with: event)
      }
      result(nil)
    case "setAlwaysOnTop":
      // Pinned (its top bar's pin): over other apps' windows; else an
      // ordinary window's level, in front as it shows.
      level = (call.arguments as? Bool ?? false) ? .floating : .normal
      result(nil)
    case "windowRoom":
      result(["width": 0.0, "height": 0.0])
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// The panel's content: the system's sidebar material, blurring what is
/// behind it, under the Flutter view. Active
/// always: the panel takes the keyboard without the app coming in front.
private final class StashContent: NSViewController {
  private let flutter: FlutterViewController
  private let size: NSSize

  init(flutter: FlutterViewController, size: NSSize) {
    self.flutter = flutter
    self.size = size
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func loadView() {
    let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    material.material = .sidebar
    material.blendingMode = .behindWindow
    material.state = .active
    // The window's own corners and edge, as the main window's: the
    // system's, which clips the content to them.
    addChild(flutter)
    flutter.view.frame = material.bounds
    flutter.view.autoresizingMask = [.width, .height]
    material.addSubview(flutter.view)
    view = material
  }
}

// MARK: - The shortcut

/// The shortcut that shows the panel from any app: a hot key of the
/// system's (Carbon's: no leave asked, unlike watching all keys).
final class StashHotkey {
  static let shared = StashHotkey()

  private var hotKey: EventHotKeyRef?
  private var voiceHotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?

  /// Called on the main thread as the stash shortcut is pressed.
  var onPress: (() -> Void)?

  /// Called on the main thread as the voice shortcut is pressed.
  var onVoicePress: (() -> Void)?

  /// Takes [spec] (`ctrl+shift+space`, `cmd+alt+n`…) in place of the one
  /// it had; none for an empty one. Whether the system gave it (another
  /// app may hold it).
  func register(_ spec: String) -> Bool {
    unregister()
    guard let (code, modifiers) = Self.parse(spec) else { return spec.isEmpty }
    installHandler()
    let id = EventHotKeyID(signature: OSType(0x4241_4F53), id: 1)  // 'BAOS'
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(code, modifiers, id, GetEventDispatcherTarget(), 0, &ref)
    guard status == noErr else { return false }
    hotKey = ref
    return true
  }

  func unregister() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    hotKey = nil
  }

  func registerVoice(_ spec: String) -> Bool {
    unregisterVoice()
    guard let (code, modifiers) = Self.parse(spec) else { return spec.isEmpty }
    installHandler()
    let id = EventHotKeyID(signature: OSType(0x4241_4F53), id: 2)  // 'BAOS' #2
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(code, modifiers, id, GetEventDispatcherTarget(), 0, &ref)
    guard status == noErr else { return false }
    voiceHotKey = ref
    return true
  }

  func unregisterVoice() {
    if let voiceHotKey { UnregisterEventHotKey(voiceHotKey) }
    voiceHotKey = nil
  }

  private func installHandler() {
    guard handler == nil else { return }
    var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetEventDispatcherTarget(),
      { _, event, _ -> OSStatus in
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID)
        let id = status == noErr ? hotKeyID.id : 1
        DispatchQueue.main.async {
          if id == 2 {
            StashHotkey.shared.onVoicePress?()
          } else {
            StashHotkey.shared.onPress?()
          }
        }
        return noErr
      },
      1, &type, nil, &handler)
  }

  /// [spec]'s key and modifiers, as Carbon counts them; nil when it names
  /// no key, or no modifier (a key alone would be taken from every app).
  static func parse(_ spec: String) -> (UInt32, UInt32)? {
    var modifiers: UInt32 = 0
    var key: UInt32?
    for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
      switch part {
      case "cmd", "command", "meta", "⌘": modifiers |= UInt32(cmdKey)
      case "ctrl", "control", "⌃": modifiers |= UInt32(controlKey)
      case "alt", "option", "opt", "⌥": modifiers |= UInt32(optionKey)
      case "shift", "⇧": modifiers |= UInt32(shiftKey)
      default: key = keyCodes[part]
      }
    }
    guard let key, modifiers != 0 else { return nil }
    return (key, modifiers)
  }

  private static let keyCodes: [String: UInt32] = {
    var codes: [String: UInt32] = [
      "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
      "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
      "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
      "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
      "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
      "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
      "space": 0x31, "enter": 0x24, "return": 0x24, "tab": 0x30, "escape": 0x35, "esc": 0x35,
      "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
      "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
      "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]
    codes["backquote"] = 0x32
    return codes
  }()
}

// MARK: - The channel

/// `baocode/stash` (see lib/stash/stash_host.dart): the shortcut, and the
/// text in pictures. Pressed, it tells whether that was in BaoCode itself
/// (`self`) and whether the panel was what the keyboard was in (`panel`).
final class StashChannel {
  static var shared: StashChannel?

  private let channel: FlutterMethodChannel
  private let voiceChannel: FlutterMethodChannel
  private let voiceAudio = VoiceAudioController()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "baocode/stash", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result) ?? result(nil)
    }
    voiceChannel = FlutterMethodChannel(name: "baocode/voice", binaryMessenger: messenger)
    voiceChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleVoice(call, result: result) ?? result(nil)
    }
    voiceAudio.onPlaybackDone = { [weak self] playId in
      self?.voiceChannel.invokeMethod("playbackDone", arguments: playId)
    }
    StashHotkey.shared.onPress = { [weak self] in self?.pressed() }
    StashHotkey.shared.onVoicePress = { [weak self] in self?.voicePressed() }
  }

  private func voicePressed() {
    NSApp.activate(ignoringOtherApps: true)
    if let mainWindow = NSApp.windows.first(where: { $0 is BaoWindow }) {
      mainWindow.makeKeyAndOrderFront(nil)
    }
    voiceChannel.invokeMethod("pressed", arguments: nil)
  }

  private func handleVoice(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setHotkey":
      result(StashHotkey.shared.registerVoice(call.arguments as? String ?? ""))
    case "startRecording":
      var path = ""
      var deviceId = -1
      if let rawPath = call.arguments as? String {
        path = rawPath
      } else if let map = call.arguments as? [String: Any] {
        path = map["path"] as? String ?? ""
        if let idNum = map["deviceId"] as? NSNumber {
          deviceId = idNum.intValue
        }
      }
      voiceAudio.startRecording(path: path, deviceId: deviceId) { err in
        if let err {
          result(FlutterError(code: "MAC_RECORD_START", message: err, details: nil))
        } else {
          result(true)
        }
      }
    case "stopRecording":
      if let err = voiceAudio.stopRecording() {
        result(FlutterError(code: "MAC_RECORD_STOP", message: err, details: nil))
      } else {
        result(true)
      }
    case "cancelRecording":
      voiceAudio.cancelRecording()
      result(true)
    case "recordingMetrics":
      result(voiceAudio.recordingMetrics())
    case "listInputDevices":
      result(voiceAudio.listInputDevices())
    case "playAudio":
      var path = ""
      var playId = 0
      if let map = call.arguments as? [String: Any] {
        path = map["path"] as? String ?? ""
        if let idNum = map["id"] as? NSNumber {
          playId = idNum.intValue
        }
      }
      if let err = voiceAudio.playAudio(path: path, playId: playId) {
        result(FlutterError(code: "MAC_AUDIO_PLAY", message: err, details: nil))
      } else {
        result(true)
      }
    case "pauseAudio":
      result(voiceAudio.pauseAudio())
    case "resumeAudio":
      result(voiceAudio.resumeAudio())
    case "stopAudio":
      voiceAudio.stopAudio()
      result(true)
    case "playEarcon":
      voiceAudio.playEarcon(kind: call.arguments as? String ?? "start")
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func pressed() {
    // The panel, what the keyboard is in: it hides then, and is given the
    // keyboard back otherwise.
    let inApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
      == ProcessInfo.processInfo.processIdentifier
    channel.invokeMethod("pressed", arguments: [
      "self": inApp,
      "panel": StashPanel.current?.isKeyWindow ?? false,
    ])
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setHotkey":
      result(StashHotkey.shared.register(call.arguments as? String ?? ""))
    case "recognizeText":
      guard let path = call.arguments as? String else {
        result(nil)
        return
      }
      Self.recognizeText(at: URL(fileURLWithPath: path), result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The text in the picture at [url], read by Vision, in the
  /// background; nil when there is none or it cannot be read.
  private static func recognizeText(at url: URL, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .utility).async {
      guard let image = NSImage(contentsOf: url),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
      let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
      var text: String?
      do {
        try handler.perform([request])
        text = (request.results ?? [])
          .compactMap { $0.topCandidates(1).first?.string }
          .joined(separator: "\n")
      } catch {
        text = nil
      }
      DispatchQueue.main.async { result(text) }
    }
  }
}

// MARK: - Native macOS Voice Audio (AVAudioEngine + AVAudioPlayer + CoreAudio)

/// Native macOS audio recorder (16kHz 16-bit mono streaming PCM WAV with
/// adaptive ambient noise floor VAD & selectable CoreAudio microphone),
/// low-latency MP3/WAV playback with Pause/Resume/Stop, and synthesized
/// UI earcons — providing full feature parity with Windows `stash_channel.cpp`.
final class VoiceAudioController: NSObject, AVAudioPlayerDelegate {
  var onPlaybackDone: ((Int) -> Void)?

  private static let sampleRate: Double = 16000.0
  private static let sampleRateUInt32: UInt32 = 16000

  private let lock = NSLock()
  private var engine: AVAudioEngine?
  private var fileHandle: FileHandle?
  private var recording = false
  private var dataBytes: UInt32 = 0
  private var level: Double = 0.0
  private var silenceMs: UInt32 = 0
  private var totalMs: UInt32 = 0
  private var heardSpeech = false
  private var noiseFloorRms: Double = 0.006
  private var calibratedMs: UInt32 = 0

  private var audioPlayer: AVAudioPlayer?
  private var earconPlayer: AVAudioPlayer?
  private var activePlayId: Int = 0

  deinit {
    cancelRecording()
    stopAudio()
  }

  // MARK: Microphone device enumeration (CoreAudio)

  func listInputDevices() -> [[String: Any]] {
    var devicesAddr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: AudioObjectPropertyElement(0))
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &devicesAddr, 0, nil, &dataSize) == noErr,
      dataSize > 0
    else { return [] }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &devicesAddr, 0, nil, &dataSize, &deviceIDs) == noErr
    else { return [] }

    var devices: [[String: Any]] = []
    for deviceID in deviceIDs {
      guard Self.inputChannelCount(for: deviceID) > 0,
            let name = Self.deviceName(for: deviceID),
            !name.isEmpty
      else { continue }
      devices.append([
        "id": Int(deviceID),
        "name": name,
      ])
    }
    return devices
  }

  private static func inputChannelCount(for deviceID: AudioDeviceID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: AudioObjectPropertyElement(0))
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
          size > 0
    else { return 0 }

    let rawPtr = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size),
      alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { rawPtr.deallocate() }

    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, rawPtr) == noErr
    else { return 0 }

    let buffers = UnsafeMutableAudioBufferListPointer(
      rawPtr.bindMemory(to: AudioBufferList.self, capacity: 1))
    var total: UInt32 = 0
    for buf in buffers {
      total &+= buf.mNumberChannels
    }
    return total
  }

  private static func deviceName(for deviceID: AudioDeviceID) -> String? {
    var cfName: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: AudioObjectPropertyElement(0))
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfName) == noErr,
          let name = cfName?.takeRetainedValue() as String?
    else { return nil }
    return name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: Streaming 16kHz PCM WAV Recording + Adaptive VAD

  func startRecording(path: String, deviceId: Int, completion: @escaping (String?) -> Void) {
    guard !path.isEmpty else {
      completion("录音输出路径为空")
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      completion(startRecordingAuthorized(path: path, deviceId: deviceId))
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self else {
            completion("录音会话已释放")
            return
          }
          if granted {
            completion(self.startRecordingAuthorized(path: path, deviceId: deviceId))
          } else {
            completion("麦克风权限未授权，请在「系统设置 → 隐私与安全性 → 麦克风」允许 Ayte 访问麦克风")
          }
        }
      }
    case .denied, .restricted:
      completion("麦克风权限被拒绝，请在「系统设置 → 隐私与安全性 → 麦克风」允许 Ayte 访问麦克风")
    @unknown default:
      completion("无法获取麦克风访问权限")
    }
  }

  private func startRecordingAuthorized(path: String, deviceId: Int) -> String? {
    cancelRecording()

    guard FileManager.default.createFile(atPath: path, contents: nil),
          let handle = FileHandle(forWritingAtPath: path)
    else {
      return "无法创建录音文件"
    }
    do {
      try handle.write(contentsOf: Self.buildWavHeader(dataBytes: 0))
    } catch {
      try? handle.close()
      return "写入录音文件头失败: \(error.localizedDescription)"
    }

    let newEngine = AVAudioEngine()
    let inputNode = newEngine.inputNode
    if deviceId >= 0, let audioUnit = inputNode.audioUnit {
      var devID = AudioDeviceID(deviceId)
      _ = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &devID,
        UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    let hwFormat = inputNode.outputFormat(forBus: 0)
    guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
      try? handle.close()
      return "未检测到可用的麦克风输入格式"
    }
    guard let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Self.sampleRate,
      channels: 1,
      interleaved: true),
      let converter = AVAudioConverter(from: hwFormat, to: targetFormat)
    else {
      try? handle.close()
      return "无法初始化音频重采样器"
    }

    lock.lock()
    engine = newEngine
    fileHandle = handle
    recording = true
    dataBytes = 0
    level = 0.0
    silenceMs = 0
    totalMs = 0
    heardSpeech = false
    noiseFloorRms = 0.006
    calibratedMs = 0
    lock.unlock()

    let ratio = Self.sampleRate / hwFormat.sampleRate
    inputNode.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
      guard let self else { return }
      let outCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 64
      guard let outBuffer = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: max(outCapacity, 256))
      else { return }

      var consumed = false
      var convError: NSError?
      let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
        if consumed {
          outStatus.pointee = .noDataNow
          return nil
        }
        consumed = true
        outStatus.pointee = .haveData
        return buffer
      }
      guard (status == .haveData || status == .inputRanDry),
            outBuffer.frameLength > 0,
            let pcm = outBuffer.int16ChannelData?.pointee
      else { return }

      let sampleCount = Int(outBuffer.frameLength)
      let byteCount = sampleCount * 2
      let chunk = Data(bytes: pcm, count: byteCount)

      var sumSq: Double = 0.0
      for i in 0..<sampleCount {
        let norm = Double(pcm[i]) / 32768.0
        sumSq += norm * norm
      }
      let rms = sqrt(sumSq / Double(sampleCount))
      let chunkMs = UInt32((sampleCount * 1000) / Int(Self.sampleRateUInt32))

      self.lock.lock()
      defer { self.lock.unlock() }
      guard self.recording, let fh = self.fileHandle else { return }
      try? fh.write(contentsOf: chunk)
      self.dataBytes &+= UInt32(byteCount)
      self.totalMs &+= chunkMs

      if self.calibratedMs < 260 {
        self.noiseFloorRms = self.calibratedMs == 0
          ? rms
          : (self.noiseFloorRms * 0.5 + rms * 0.5)
        self.calibratedMs &+= chunkMs
      }
      let speechThreshold = max(0.011, min(0.085, self.noiseFloorRms * 2.4))
      let visualRms = max(0.0, rms - self.noiseFloorRms * 0.7)
      self.level = min(1.0, visualRms * 6.0)

      if rms >= speechThreshold {
        self.heardSpeech = true
        self.silenceMs = 0
      } else {
        self.noiseFloorRms = self.noiseFloorRms * 0.92 + rms * 0.08
        if self.heardSpeech {
          self.silenceMs &+= chunkMs
        }
      }
    }

    newEngine.prepare()
    do {
      try newEngine.start()
      return nil
    } catch {
      cancelRecording()
      return "启动麦克风录音失败: \(error.localizedDescription)"
    }
  }

  func stopRecording() -> String? {
    lock.lock()
    if !recording {
      lock.unlock()
      return "Not recording"
    }
    recording = false
    let activeEngine = engine
    engine = nil
    let activeHandle = fileHandle
    fileHandle = nil
    let finalBytes = dataBytes
    lock.unlock()

    activeEngine?.inputNode.removeTap(onBus: 0)
    activeEngine?.stop()

    if let fh = activeHandle {
      do {
        try fh.seek(toOffset: 0)
        try fh.write(contentsOf: Self.buildWavHeader(dataBytes: finalBytes))
        try fh.close()
      } catch {
        try? fh.close()
        return "保存录音文件失败: \(error.localizedDescription)"
      }
    }
    return nil
  }

  func cancelRecording() {
    lock.lock()
    recording = false
    let activeEngine = engine
    engine = nil
    let activeHandle = fileHandle
    fileHandle = nil
    lock.unlock()

    activeEngine?.inputNode.removeTap(onBus: 0)
    activeEngine?.stop()
    try? activeHandle?.close()
  }

  func recordingMetrics() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    return [
      "level": level,
      "silenceMs": Int(silenceMs),
      "totalMs": Int(totalMs),
      "heardSpeech": heardSpeech,
    ]
  }

  // MARK: Native Audio Playback (AVAudioPlayer) + Earcons

  func playAudio(path: String, playId: Int) -> String? {
    stopAudio()
    guard !path.isEmpty else { return "Empty audio path" }
    do {
      let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
      player.delegate = self
      player.prepareToPlay()
      guard player.play() else {
        return "无法播放音频文件"
      }
      audioPlayer = player
      activePlayId = playId
      return nil
    } catch {
      return "播放音频失败: \(error.localizedDescription)"
    }
  }

  func pauseAudio() -> Bool {
    guard let player = audioPlayer, player.isPlaying else { return false }
    player.pause()
    return true
  }

  func resumeAudio() -> Bool {
    guard let player = audioPlayer, !player.isPlaying else { return false }
    return player.play()
  }

  func stopAudio() {
    if let player = audioPlayer {
      player.delegate = nil
      player.stop()
    }
    audioPlayer = nil
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    guard player === audioPlayer else { return }
    let finishedId = activePlayId
    audioPlayer = nil
    DispatchQueue.main.async { [weak self] in
      self?.onPlaybackDone?(finishedId)
    }
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    guard player === audioPlayer else { return }
    let finishedId = activePlayId
    audioPlayer = nil
    DispatchQueue.main.async { [weak self] in
      self?.onPlaybackDone?(finishedId)
    }
  }

  func playEarcon(kind: String) {
    let wav = Self.buildEarconWav(kind: kind)
    guard !wav.isEmpty else { return }
    earconPlayer?.stop()
    if let player = try? AVAudioPlayer(data: wav) {
      player.volume = 0.75
      player.prepareToPlay()
      _ = player.play()
      earconPlayer = player
    }
  }

  // MARK: PCM WAV & Earcon Helpers

  private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }

  private static func buildWavHeader(dataBytes: UInt32) -> Data {
    var header = Data(capacity: 44)
    header.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // "RIFF"
    appendLE(&header, UInt32(36) &+ dataBytes)
    header.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // "WAVE"
    header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])  // "fmt "
    appendLE(&header, UInt32(16))
    appendLE(&header, UInt16(1))                         // PCM
    appendLE(&header, UInt16(1))                         // Mono
    appendLE(&header, sampleRateUInt32)                  // 16000 Hz
    appendLE(&header, sampleRateUInt32 * 2)              // ByteRate
    appendLE(&header, UInt16(2))                         // BlockAlign
    appendLE(&header, UInt16(16))                        // BitsPerSample
    header.append(contentsOf: [0x64, 0x61, 0x74, 0x61])  // "data"
    appendLE(&header, dataBytes)
    return header
  }

  private static func buildEarconWav(kind: String) -> Data {
    let tones: [(freq: Double, ms: Double, amp: Double)]
    switch kind {
    case "start":
      tones = [(660.0, 52.0, 0.14), (880.0, 62.0, 0.14)]
    case "stop":
      tones = [(780.0, 48.0, 0.13), (580.0, 62.0, 0.13)]
    default:
      tones = [(740.0, 55.0, 0.13), (587.0, 55.0, 0.13), (440.0, 90.0, 0.14)]
    }
    var samples: [Int16] = []
    for tone in tones {
      let count = Int((tone.ms / 1000.0) * sampleRate)
      let fade = min(count / 4, 160)
      for i in 0..<count {
        var env = 1.0
        if fade > 0 {
          if i < fade {
            env = Double(i) / Double(fade)
          } else if i + fade > count {
            env = Double(count - i) / Double(fade)
          }
        }
        let phase = 2.0 * Double.pi * tone.freq * Double(i) / sampleRate
        let val = sin(phase) * tone.amp * env
        samples.append(Int16(max(-32767.0, min(32767.0, val * 32767.0))))
      }
    }
    let byteCount = UInt32(samples.count * 2)
    var wav = buildWavHeader(dataBytes: byteCount)
    samples.withUnsafeBytes { raw in
      wav.append(contentsOf: raw)
    }
    return wav
  }
}
