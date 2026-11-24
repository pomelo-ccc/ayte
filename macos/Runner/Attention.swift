import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers
import UserNotifications

/// What tells the user an agent wants them while they look elsewhere (see
/// lib/notifications/): the system's notifications, a sound, the Dock
/// icon's badge and bounce, and the menu bar icon, whose popover brings the
/// window — or an agent — back. Over `baocode/attention`.
final class Attention:
  NSObject, UNUserNotificationCenterDelegate, NSSoundDelegate,
  NSPopoverDelegate, NSMenuDelegate
{
  /// The window's, for the app delegate to ask (see hidesOnClose).
  private(set) static weak var shared: Attention?

  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?

  /// The menu bar icon, while there is one (the `tray.enabled` setting).
  private var statusItem: NSStatusItem?

  /// The custom card popover attached to the menu bar icon.
  private var popover: NSPopover?
  private var popoverController: TrayPopoverViewController?

  /// Dismisses the popover when clicking outside while another app is active.
  private var outsideClickMonitor: Any?

  /// Temporary right-click menu shown on control-click / right-click.
  private var contextMenu: NSMenu?

  /// Keep each sound alive until its own playback finishes.
  private var playingSounds: [NSSound] = []

  /// Whether notifications were asked leave for, this run.
  private var authorizationAsked = false

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    channel = FlutterMethodChannel(name: "baocode/attention", binaryMessenger: messenger)
    self.window = window
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    UNUserNotificationCenter.current().delegate = self
    Attention.shared = self
  }

  deinit {
    removeOutsideClickMonitor()
  }

  /// The close button hides the window while the menu bar icon can bring it
  /// back; without one, closing it quits.
  var hidesOnClose: Bool { statusItem != nil }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "notify":
      notify(
        id: arguments?["id"] as? String ?? "",
        title: arguments?["title"] as? String ?? "",
        body: arguments?["body"] as? String ?? "")
      result(nil)
    case "playSound":
      play(
        path: arguments?["path"] as? String,
        bytes: (arguments?["bytes"] as? FlutterStandardTypedData)?.data)
      result(nil)
    case "requestAttention":
      // A bounce of the Dock icon, once; nothing while the app is in front.
      NSApp.requestUserAttention(.informationalRequest)
      result(nil)
    case "setBadge":
      let count = call.arguments as? Int ?? 0
      NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
      result(nil)
    case "setTray":
      setTray(arguments)
      result(nil)
    case "pickSound":
      pickSound(result: result)
    case "quit":
      quitChosen()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Notifications

  private func notify(id: String, title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    let post = {
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.threadIdentifier = id
      content.userInfo = ["thread": id]
      // Silent: the app plays the sound the user picked itself.
      content.sound = nil
      // One at a time for each agent: its newer news takes the place of
      // the older.
      let request = UNNotificationRequest(
        identifier: "agent.\(id)", content: content, trigger: nil)
      center.add(request)
    }
    if authorizationAsked {
      post()
      return
    }
    authorizationAsked = true
    center.requestAuthorization(options: [.alert]) { granted, _ in
      if granted { DispatchQueue.main.async(execute: post) }
    }
  }

  /// Shown in front of the app too: it only notifies then when the agent
  /// is not the one in view (or the user wants it always).
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
  }

  /// A click on one: the window, on the agent it is about.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = response.notification.request.content.userInfo["thread"] as? String
    open(id)
    completionHandler()
  }

  // MARK: Sound

  private func play(path: String?, bytes: Data?) {
    let sound: NSSound?
    if let bytes {
      sound = NSSound(data: bytes)
    } else if let path {
      sound = NSSound(contentsOf: URL(fileURLWithPath: path), byReference: true)
    } else {
      return
    }
    guard let sound else { return }
    sound.delegate = self
    playingSounds.append(sound)
    if !sound.play() { playingSounds.removeAll { $0 === sound } }
  }

  func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
    playingSounds.removeAll { $0 === sound }
  }

  /// A sound file of the user's for the notifications.
  private func pickSound(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.audio]
    let answer = { (response: NSApplication.ModalResponse) in
      result(response == .OK ? panel.url?.path : nil)
    }
    if let window, window.isVisible {
      panel.beginSheetModal(for: window, completionHandler: answer)
    } else {
      answer(panel.runModal())
    }
  }

  // MARK: Window

  /// Brings the window back, hidden or minimized, in front.
  func showWindow() {
    guard let window else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// The window, on the agent [id] when there is one. With the IDE's
  /// windows, the app shows the one the agent is a tab of (else this one).
  private func open(_ id: String?) {
    if id != nil && AppWindows.shared?.started ?? false {
      NSApp.activate(ignoringOtherApps: true)
    } else {
      showWindow()
    }
    channel.invokeMethod("open", arguments: id)
  }

  // MARK: Menu bar

  /// The menu bar icon and its popover state, as the Flutter side describes
  /// them; nil removes the status item.
  private func setTray(_ state: [String: Any]?) {
    guard let state else {
      closePopover()
      contextMenu = nil
      statusItem?.menu = nil
      popover = nil
      popoverController = nil
      if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
      statusItem = nil
      trayState = nil
      return
    }
    let item: NSStatusItem
    if let existing = statusItem {
      item = existing
    } else {
      item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      if let button = item.button {
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.setAccessibilityTitle("Ayte")
      }
      statusItem = item
    }
    trayState = state
    let dot = state["dot"] as? Bool ?? false
    let waitingCount = (state["waiting"] as? [[String: Any]])?.count ?? 0
    let runningCount = (state["running"] as? [[String: Any]])?.count ?? 0

    if let button = item.button {
      button.image = Self.trayImage(
        waitingCount: waitingCount,
        runningCount: runningCount,
        hasAttention: dot)
      button.toolTip = state["tooltip"] as? String
      if waitingCount > 0 {
        let attrs: [NSAttributedString.Key: Any] = [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
          .baselineOffset: 0.5,
        ]
        button.attributedTitle = NSAttributedString(
          string: " \(waitingCount)", attributes: attrs)
      } else {
        button.title = ""
      }
    }

    if popover?.isShown == true {
      updatePopoverContent()
    }
  }

  /// What Flutter last said of the menu bar icon.
  private var trayState: [String: Any]?

  /// Refreshes the open popover when the app's windows change (see AppWindows).
  func refreshTray() {
    guard statusItem != nil, trayState != nil else { return }
    if popover?.isShown == true {
      updatePopoverContent()
    }
  }

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    let isRightClick = event?.type == .rightMouseUp
      || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
    if isRightClick {
      closePopover()
      showContextMenu(for: sender)
      return
    }
    togglePopover(relativeTo: sender)
  }

  private func togglePopover(relativeTo button: NSStatusBarButton) {
    if let popover, popover.isShown {
      closePopover()
      return
    }
    let popover = ensurePopover()
    updatePopoverContent()
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
    installOutsideClickMonitor()
  }

  private func ensurePopover() -> NSPopover {
    if let popover { return popover }
    let controller = TrayPopoverViewController(actions: TrayPopoverActions(
      showApp: { [weak self] in
        self?.closePopover()
        self?.open(nil)
      },
      newChat: { [weak self] in
        self?.startNewChat()
      },
      openSettings: { [weak self] in
        self?.openSettings()
      },
      openAgent: { [weak self] id in
        self?.closePopover()
        self?.open(id)
      },
      focusWindow: { [weak self] viewId in
        self?.closePopover()
        AppWindows.shared?.focusWindow(viewId: viewId)
      },
      newWindow: { [weak self] in
        self?.closePopover()
        AppWindows.shared?.openNewWindow()
      },
      quit: { [weak self] in
        self?.closePopover()
        self?.quitChosen()
      },
      close: { [weak self] in
        self?.closePopover()
      }
    ))
    let pop = NSPopover()
    pop.behavior = .transient
    pop.animates = true
    pop.delegate = self
    pop.contentViewController = controller
    controller.onPreferredSizeChanged = { [weak pop] size in
      pop?.contentSize = size
    }
    self.popoverController = controller
    self.popover = pop
    return pop
  }

  private func updatePopoverContent() {
    guard let trayState, let controller = popoverController else { return }
    let snapshot = TrayPopoverSnapshot(state: trayState, appWindows: AppWindows.shared)
    controller.update(snapshot: snapshot)
    popover?.contentSize = controller.preferredContentSize
  }

  private func closePopover() {
    removeOutsideClickMonitor()
    if let popover, popover.isShown {
      popover.performClose(nil)
    }
  }

  func popoverDidClose(_ notification: Notification) {
    removeOutsideClickMonitor()
  }

  private func installOutsideClickMonitor() {
    removeOutsideClickMonitor()
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      self?.closePopover()
    }
  }

  private func removeOutsideClickMonitor() {
    if let monitor = outsideClickMonitor {
      NSEvent.removeMonitor(monitor)
      outsideClickMonitor = nil
    }
  }

  /// Compact native menu shown on right-click / Control-click of the status icon.
  private func showContextMenu(for button: NSStatusBarButton) {
    guard let state = trayState, let statusItem else { return }
    let labels = state["labels"] as? [String: String] ?? [:]
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    menu.addItem(action(labels["show"] ?? "Show Ayte", #selector(showChosen)))
    menu.addItem(action(labels["newChat"] ?? "New Chat", #selector(newChatChosen)))
    if let windows = AppWindows.shared, windows.started {
      menu.addItem(action(windows.newWindowTitle, #selector(newWindowChosen)))
    }
    menu.addItem(.separator())
    menu.addItem(action(labels["settings"] ?? "Open Settings", #selector(settingsChosen)))
    menu.addItem(.separator())
    menu.addItem(action(labels["quit"] ?? "Quit Ayte", #selector(quitChosen)))
    contextMenu = menu
    statusItem.menu = menu
    button.performClick(nil)
  }

  func menuDidClose(_ menu: NSMenu) {
    if statusItem?.menu === menu {
      statusItem?.menu = nil
    }
    if contextMenu === menu {
      contextMenu = nil
    }
  }

  private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
    item.target = self
    return item
  }

  @objc private func showChosen() { open(nil) }

  @objc private func newChatChosen() { startNewChat() }

  @objc private func newWindowChosen() {
    closePopover()
    AppWindows.shared?.openNewWindow()
  }

  @objc private func settingsChosen() { openSettings() }

  private func startNewChat() {
    closePopover()
    showWindow()
    (window as? BaoWindow)?.menuCommand("workbench.action.chat.newChat")
  }

  private func openSettings() {
    closePopover()
    if let windows = AppWindows.shared, windows.started {
      windows.bringFront()
    } else {
      showWindow()
    }
    ((NSApp.keyWindow as? BaoWindow) ?? (window as? BaoWindow))?.menuCommand(
      "workbench.action.openSettings")
  }

  /// Quits as ⌘Q does: the app asks first, in its window (the one in
  /// front, with the IDE's).
  @objc private func quitChosen() {
    if let windows = AppWindows.shared, windows.started {
      windows.bringFront()
    } else {
      showWindow()
    }
    NSApp.terminate(nil)
  }

  /// Full-color Ayte App Icon aligned with the app's bundled AppIcon squircle,
  /// rendered crisply at 1x/2x/3x scales (used in the tray popover header).
  static func appBrandIcon(size: NSSize, inset: CGFloat = 0) -> NSImage {
    let image = NSImage(size: size)
    let source: NSImage? = NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
    for scale in [1, 2, 3] {
      let pixelsW = Int(round(size.width * CGFloat(scale)))
      let pixelsH = Int(round(size.height * CGFloat(scale)))
      guard pixelsW > 0, pixelsH > 0,
            let rep = NSBitmapImageRep(
              bitmapDataPlanes: nil, pixelsWide: pixelsW, pixelsHigh: pixelsH,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
      else { continue }
      NSGraphicsContext.saveGraphicsState()
      if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        let pxInset = inset * CGFloat(scale)
        let targetRect = NSRect(
          x: pxInset, y: pxInset,
          width: CGFloat(pixelsW) - pxInset * 2,
          height: CGFloat(pixelsH) - pxInset * 2)
        drawBrandIcon(source: source, in: ctx.cgContext, rect: targetRect)
      }
      NSGraphicsContext.restoreGraphicsState()
      rep.size = size
      image.addRepresentation(rep)
    }
    image.isTemplate = false
    return image
  }

  /// Optical 18x18pt menu bar icon: bold geometric 'a' + 4-point AI spark.
  ///
  /// - Idle: pure monochrome template (`isTemplate = true`), adapting natively
  ///   to light/dark menu bars, wallpaper tinting, and inactive displays.
  /// - Running: monochrome 'a' (dynamically tinted via current drawing
  ///   appearance) with an emerald 4-point spark.
  /// - Waiting / Attention: monochrome 'a' with a coral-red beacon replacing
  ///   the top-right spark so status never collides with the brand mark.
  static func trayImage(
    waitingCount: Int = 0,
    runningCount: Int = 0,
    hasAttention: Bool = false
  ) -> NSImage {
    let needsAttention = waitingCount > 0 || hasAttention
    let isRunning = !needsAttention && runningCount > 0
    let isIdle = !needsAttention && !isRunning

    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: true) { rect in
      guard let cg = NSGraphicsContext.current?.cgContext else { return false }
      let side = min(rect.width, rect.height)
      let u = side / 18.0
      let ox = rect.minX + (rect.width - side) * 0.5
      let oy = rect.minY + (rect.height - side) * 0.5

      cg.saveGState()
      cg.translateBy(x: ox, y: oy)
      cg.setAllowsAntialiasing(true)
      cg.setShouldAntialias(true)

      let glyphColor: NSColor
      if isIdle {
        glyphColor = .black
      } else {
        let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        glyphColor = isDark
          ? NSColor(white: 1.0, alpha: 0.94)
          : NSColor(white: 0.0, alpha: 0.88)
      }

      // Optical-balanced geometric 'a': even-odd ring + flush rounded stem.
      let ringCenter = CGPoint(x: 7.65 * u, y: 10.35 * u)
      let outerR = 5.25 * u
      let innerR = 2.52 * u
      let ring = CGMutablePath()
      ring.addEllipse(in: CGRect(
        x: ringCenter.x - outerR, y: ringCenter.y - outerR,
        width: outerR * 2, height: outerR * 2))
      ring.addEllipse(in: CGRect(
        x: ringCenter.x - innerR, y: ringCenter.y - innerR,
        width: innerR * 2, height: innerR * 2))

      cg.setFillColor(glyphColor.cgColor)
      cg.addPath(ring)
      cg.fillPath(using: .evenOdd)

      let stemRect = CGRect(x: 10.22 * u, y: 5.10 * u, width: 2.75 * u, height: 10.50 * u)
      let stemRadius = stemRect.width * 0.5
      cg.addPath(CGPath(
        roundedRect: stemRect,
        cornerWidth: stemRadius,
        cornerHeight: stemRadius,
        transform: nil))
      cg.fillPath()

      // Top-right 4-point AI spark doubles cleanly as the live status beacon.
      let sparkCenter = CGPoint(x: 14.55 * u, y: 3.65 * u)
      if needsAttention {
        let dotR = 2.25 * u
        cg.setFillColor(NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0).cgColor)
        cg.fillEllipse(in: CGRect(
          x: sparkCenter.x - dotR, y: sparkCenter.y - dotR,
          width: dotR * 2, height: dotR * 2))
      } else if isRunning {
        cg.setFillColor(NSColor(srgbRed: 0.06, green: 0.76, blue: 0.44, alpha: 1.0).cgColor)
        cg.addPath(fourPointSparkPath(center: sparkCenter, outerRadius: 2.95 * u, innerRatio: 0.33))
        cg.fillPath()
      } else {
        cg.setFillColor(glyphColor.cgColor)
        cg.addPath(fourPointSparkPath(center: sparkCenter, outerRadius: 2.70 * u, innerRatio: 0.28))
        cg.fillPath()
      }

      cg.restoreGState()
      return true
    }

    image.isTemplate = isIdle
    return image
  }

  private static func fourPointSparkPath(
    center: CGPoint,
    outerRadius r: CGFloat,
    innerRatio: CGFloat
  ) -> CGPath {
    let c = r * innerRatio
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x, y: center.y - r))
    path.addQuadCurve(
      to: CGPoint(x: center.x + r, y: center.y),
      control: CGPoint(x: center.x + c, y: center.y - c))
    path.addQuadCurve(
      to: CGPoint(x: center.x, y: center.y + r),
      control: CGPoint(x: center.x + c, y: center.y + c))
    path.addQuadCurve(
      to: CGPoint(x: center.x - r, y: center.y),
      control: CGPoint(x: center.x - c, y: center.y + c))
    path.addQuadCurve(
      to: CGPoint(x: center.x, y: center.y - r),
      control: CGPoint(x: center.x - c, y: center.y - c))
    path.closeSubpath()
    return path
  }

  /// Draws the bundled AppIcon cropped tightly to the standard macOS 824/1024
  /// squircle grid, falling back to a full-color CoreGraphics vector version.
  private static func drawBrandIcon(
    source: NSImage?, in context: CGContext, rect: NSRect
  ) {
    if let source, source.size.width > 0, source.size.height > 0 {
      let insetX = source.size.width * 0.09
      let insetY = source.size.height * 0.09
      let srcRect = NSRect(
        x: insetX,
        y: insetY,
        width: source.size.width - insetX * 2,
        height: source.size.height - insetY * 2)
      source.draw(
        in: rect,
        from: srcRect,
        operation: .sourceOver,
        fraction: 1.0,
        respectFlipped: true,
        hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
      return
    }
    drawFallbackBrandIcon(in: context, rect: rect)
  }

  /// Vector fallback matching the porcelain squircle + gradient 'a' + golden spark.
  private static func drawFallbackBrandIcon(in context: CGContext, rect: NSRect) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    let side = min(rect.width, rect.height)
    let tileRect = CGRect(x: 0, y: 0, width: side, height: side)
    let corner = side * 0.225
    let tilePath = CGPath(
      roundedRect: tileRect.insetBy(dx: side * 0.015, dy: side * 0.015),
      cornerWidth: corner, cornerHeight: corner, transform: nil)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Warm porcelain tile.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    if let bg = CGGradient(
      colorsSpace: colorSpace,
      colors: [
        NSColor(srgbRed: 1.0, green: 0.996, blue: 0.98, alpha: 1.0).cgColor,
        NSColor(srgbRed: 0.965, green: 0.955, blue: 0.925, alpha: 1.0).cgColor,
      ] as CFArray,
      locations: [0.0, 1.0])
    {
      context.drawLinearGradient(
        bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: side), options: [])
    }
    context.restoreGState()

    context.addPath(tilePath)
    context.setStrokeColor(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14).cgColor)
    context.setLineWidth(max(1.0, side * 0.03))
    context.strokePath()

    // Coordinate map matching assets/branding/logo.svg inside the porcelain tile.
    let pad = side * 0.14
    let span = side - pad * 2
    func u(_ x: CGFloat) -> CGFloat { pad + (x - 249) / 512 * span }
    func v(_ y: CGFloat) -> CGFloat { pad + (y - 234) / 512 * span }
    func r(_ d: CGFloat) -> CGFloat { d / 512 * span }

    // Gradient ring of 'a'.
    let ringCenter = CGPoint(x: u(466), y: v(538))
    let outerR = r(198)
    let innerR = r(112)
    let ring = CGMutablePath()
    ring.addEllipse(in: CGRect(
      x: ringCenter.x - outerR, y: ringCenter.y - outerR,
      width: outerR * 2, height: outerR * 2))
    ring.addEllipse(in: CGRect(
      x: ringCenter.x - innerR, y: ringCenter.y - innerR,
      width: innerR * 2, height: innerR * 2))
    context.saveGState()
    context.addPath(ring)
    context.clip(using: .evenOdd)
    if let ringGrad = CGGradient(
      colorsSpace: colorSpace,
      colors: [
        NSColor(srgbRed: 0.22, green: 0.74, blue: 0.97, alpha: 1.0).cgColor,
        NSColor(srgbRed: 0.39, green: 0.40, blue: 0.95, alpha: 1.0).cgColor,
        NSColor(srgbRed: 0.93, green: 0.28, blue: 0.60, alpha: 1.0).cgColor,
      ] as CFArray,
      locations: [0.0, 0.55, 1.0])
    {
      context.drawLinearGradient(
        ringGrad,
        start: CGPoint(x: u(290), y: v(344)),
        end: CGPoint(x: u(640), y: v(724)),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    context.restoreGState()

    // Gradient vertical stem.
    let stemRect = CGRect(x: u(580), y: v(340), width: r(84), height: r(396))
    let stemRadius = min(stemRect.width, stemRect.height) / 2
    let stemPath = CGPath(
      roundedRect: stemRect, cornerWidth: stemRadius, cornerHeight: stemRadius, transform: nil)
    context.saveGState()
    context.addPath(stemPath)
    context.clip()
    if let stemGrad = CGGradient(
      colorsSpace: colorSpace,
      colors: [
        NSColor(srgbRed: 0.98, green: 0.44, blue: 0.52, alpha: 1.0).cgColor,
        NSColor(srgbRed: 0.66, green: 0.33, blue: 0.97, alpha: 1.0).cgColor,
        NSColor(srgbRed: 0.39, green: 0.40, blue: 0.95, alpha: 1.0).cgColor,
      ] as CFArray,
      locations: [0.0, 0.55, 1.0])
    {
      context.drawLinearGradient(
        stemGrad,
        start: CGPoint(x: stemRect.midX, y: stemRect.minY),
        end: CGPoint(x: stemRect.midX, y: stemRect.maxY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    context.restoreGState()

    // Luminous golden spark orb.
    let sparkCenter = CGPoint(x: u(704), y: v(282))
    let sparkR = r(42)
    let sparkPath = CGPath(
      ellipseIn: CGRect(
        x: sparkCenter.x - sparkR, y: sparkCenter.y - sparkR,
        width: sparkR * 2, height: sparkR * 2),
      transform: nil)
    context.saveGState()
    context.addPath(sparkPath)
    context.clip()
    if let dotGrad = CGGradient(
      colorsSpace: colorSpace,
      colors: [
        NSColor(srgbRed: 1.0, green: 0.94, blue: 0.54, alpha: 1.0).cgColor,
        NSColor(srgbRed: 0.96, green: 0.62, blue: 0.04, alpha: 1.0).cgColor,
        NSColor(srgbRed: 0.85, green: 0.47, blue: 0.02, alpha: 1.0).cgColor,
      ] as CFArray,
      locations: [0.0, 0.55, 1.0])
    {
      context.drawRadialGradient(
        dotGrad,
        startCenter: CGPoint(x: sparkCenter.x - sparkR * 0.28, y: sparkCenter.y - sparkR * 0.28),
        startRadius: 0,
        endCenter: sparkCenter,
        endRadius: sparkR * 1.15,
        options: [.drawsAfterEndLocation])
    }
    context.restoreGState()
    context.restoreGState()
  }
}
