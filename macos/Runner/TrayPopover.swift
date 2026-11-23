import Cocoa

/// One agent conversation displayed as an interactive row in the menu bar popover.
struct TrayAgentItem {
  let id: String
  let title: String
  let project: String
  let detail: String

  init?(dictionary: [String: Any]) {
    guard let id = dictionary["id"] as? String else { return nil }
    self.id = id
    self.title = dictionary["title"] as? String ?? ""
    self.project = dictionary["project"] as? String ?? ""
    self.detail = dictionary["detail"] as? String ?? ""
  }
}

/// Immutable UI snapshot consumed by [TrayPopoverViewController].
struct TrayPopoverSnapshot {
  let waiting: [TrayAgentItem]
  let running: [TrayAgentItem]
  let unread: [TrayAgentItem]
  let windows: [AppWindows.WindowSummary]
  let showNewWindow: Bool

  let showLabel: String
  let newChatLabel: String
  let newWindowLabel: String
  let windowsLabel: String
  let waitingHeader: String
  let runningHeader: String
  let unreadHeader: String
  let idleLabel: String
  let idleHintLabel: String
  let settingsLabel: String
  let quitLabel: String
  let summaryLine: String

  init(state: [String: Any], appWindows: AppWindows?) {
    let labels = state["labels"] as? [String: String] ?? [:]
    let waitingList = (state["waiting"] as? [[String: Any]] ?? []).compactMap(TrayAgentItem.init)
    let runningList = (state["running"] as? [[String: Any]] ?? []).compactMap(TrayAgentItem.init)
    let unreadList = (state["unread"] as? [[String: Any]] ?? []).compactMap(TrayAgentItem.init)

    self.waiting = waitingList
    self.running = runningList
    self.unread = unreadList
    self.windows = appWindows?.windowSummaries ?? []
    self.showNewWindow = appWindows?.started ?? false

    self.showLabel = labels["show"] ?? "Show Ayte"
    self.newChatLabel = labels["newChat"] ?? "New Chat"
    self.newWindowLabel = appWindows?.newWindowTitle ?? "New Window"
    self.windowsLabel = appWindows?.windowsSectionTitle ?? "Windows"
    self.waitingHeader = labels["waiting"] ?? "Waiting for You"
    self.runningHeader = labels["runningHeader"] ?? "Running"
    self.unreadHeader = labels["unread"] ?? "Finished"
    self.idleLabel = labels["idle"] ?? "All caught up"
    self.idleHintLabel = labels["idleHint"] ?? "Agents keep working here in the background."
    self.settingsLabel = labels["settings"] ?? "Open Settings"
    self.quitLabel = labels["quit"] ?? "Quit Ayte"

    var parts: [String] = []
    if !waitingList.isEmpty {
      parts.append(labels["waitingCount"] ?? "\(waitingList.count) waiting")
    }
    if !runningList.isEmpty {
      parts.append(labels["running"] ?? "\(runningList.count) running")
    }
    if waitingList.isEmpty && runningList.isEmpty && !unreadList.isEmpty {
      parts.append(labels["unreadCount"] ?? "\(unreadList.count) finished")
    }
    self.summaryLine = parts.isEmpty ? self.idleLabel : parts.joined(separator: " · ")
  }
}

/// Callbacks executed when the user interacts with controls inside the popover.
struct TrayPopoverActions {
  let showApp: () -> Void
  let newChat: () -> Void
  let openSettings: () -> Void
  let openAgent: (String) -> Void
  let focusWindow: (Int64) -> Void
  let newWindow: () -> Void
  let quit: () -> Void
  let close: () -> Void
}

/// Compact native macOS menu bar popover displaying live agent status,
/// scannable waiting/running/finished rows, open windows, and quick actions.
final class TrayPopoverViewController: NSViewController {
  static let panelWidth: CGFloat = 320
  private static let maxBodyHeight: CGFloat = 340
  private static let minBodyHeight: CGFloat = 68

  private let actions: TrayPopoverActions
  private var snapshot: TrayPopoverSnapshot?

  /// Notifies the owning NSPopover whenever dynamic height changes.
  var onPreferredSizeChanged: ((NSSize) -> Void)?

  // Persistent structural views
  private let rootStack = NSStackView()
  private let headerIconView = NSImageView()
  private let subtitleLabel = makeSingleLineLabel(size: 11, weight: .regular, color: .secondaryLabelColor)
  private let newChatButton = HeaderIconButton(symbol: "square.and.pencil")
  private let showAppButton = HeaderIconButton(symbol: "macwindow")
  private let scrollView = NSScrollView()
  private let bodyDocumentView = FlippedContainerView()
  private let bodyStack = NSStackView()
  private var scrollHeightConstraint: NSLayoutConstraint?

  private let settingsButton = FooterActionButton(symbol: "gearshape", title: "Settings", destructive: false)
  private let quitButton = FooterActionButton(symbol: "power", title: "Quit", destructive: true)

  init(actions: TrayPopoverActions) {
    self.actions = actions
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func loadView() {
    let effect = NSVisualEffectView(
      frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 220))
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    self.view = effect
    buildLayout(in: effect)
  }

  override func cancelOperation(_ sender: Any?) {
    actions.close()
  }

  func update(snapshot: TrayPopoverSnapshot) {
    self.snapshot = snapshot
    _ = self.view  // ensure loadView has run
    reloadContent(snapshot)
  }

  // MARK: Layout Construction

  private func buildLayout(in container: NSView) {
    rootStack.orientation = .vertical
    rootStack.alignment = .leading
    rootStack.spacing = 0
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(rootStack)

    NSLayoutConstraint.activate([
      rootStack.topAnchor.constraint(equalTo: container.topAnchor),
      rootStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      rootStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      rootStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      rootStack.widthAnchor.constraint(equalToConstant: Self.panelWidth),
    ])

    // 1. Compact Header with integrated quick icon actions
    let header = buildHeader()
    rootStack.addArrangedSubview(header)
    header.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

    // 2. Divider above scrollable body
    let topDivider = makeDivider()
    rootStack.addArrangedSubview(topDivider)
    topDivider.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

    // 3. Scrollable list body
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay

    bodyDocumentView.translatesAutoresizingMaskIntoConstraints = true
    bodyDocumentView.autoresizingMask = [.width]
    bodyDocumentView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.minBodyHeight)

    bodyStack.orientation = .vertical
    bodyStack.alignment = .leading
    bodyStack.spacing = 8
    bodyStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    bodyStack.translatesAutoresizingMaskIntoConstraints = false
    bodyDocumentView.addSubview(bodyStack)

    NSLayoutConstraint.activate([
      bodyStack.topAnchor.constraint(equalTo: bodyDocumentView.topAnchor),
      bodyStack.leadingAnchor.constraint(equalTo: bodyDocumentView.leadingAnchor),
      bodyStack.trailingAnchor.constraint(equalTo: bodyDocumentView.trailingAnchor),
    ])

    scrollView.documentView = bodyDocumentView
    rootStack.addArrangedSubview(scrollView)

    let heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: Self.minBodyHeight)
    self.scrollHeightConstraint = heightConstraint
    NSLayoutConstraint.activate([
      scrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
      heightConstraint,
    ])

    // 4. Divider above footer
    let bottomDivider = makeDivider()
    rootStack.addArrangedSubview(bottomDivider)
    bottomDivider.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

    // 5. Footer bar
    let footer = buildFooter()
    rootStack.addArrangedSubview(footer)
    footer.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
  }

  private func buildHeader() -> NSView {
    let wrapper = NSView()
    wrapper.translatesAutoresizingMaskIntoConstraints = false

    headerIconView.image = Attention.appBrandIcon(size: NSSize(width: 26, height: 26))
    headerIconView.imageScaling = .scaleProportionallyUpOrDown
    headerIconView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      headerIconView.widthAnchor.constraint(equalToConstant: 26),
      headerIconView.heightAnchor.constraint(equalToConstant: 26),
    ])

    let titleLabel = makeSingleLineLabel(size: 13, weight: .semibold, color: .labelColor)
    titleLabel.stringValue = "Ayte"

    let textStack = NSStackView(views: [titleLabel, subtitleLabel])
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = 1
    textStack.translatesAutoresizingMaskIntoConstraints = false
    textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.widthAnchor.constraint(lessThanOrEqualTo: textStack.widthAnchor).isActive = true
    subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: textStack.widthAnchor).isActive = true

    newChatButton.onClick = { [weak self] in self?.actions.newChat() }
    showAppButton.onClick = { [weak self] in self?.actions.showApp() }

    let actionStack = NSStackView(views: [newChatButton, showAppButton])
    actionStack.orientation = .horizontal
    actionStack.alignment = .centerY
    actionStack.spacing = 3
    actionStack.translatesAutoresizingMaskIntoConstraints = false
    actionStack.setContentHuggingPriority(.required, for: .horizontal)
    actionStack.setContentCompressionResistancePriority(.required, for: .horizontal)

    wrapper.addSubview(headerIconView)
    wrapper.addSubview(textStack)
    wrapper.addSubview(actionStack)

    NSLayoutConstraint.activate([
      wrapper.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),

      headerIconView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
      headerIconView.centerYAnchor.constraint(equalTo: textStack.centerYAnchor),

      textStack.leadingAnchor.constraint(equalTo: headerIconView.trailingAnchor, constant: 9),
      textStack.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 10),
      textStack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -10),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -8),

      actionStack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -10),
      actionStack.centerYAnchor.constraint(equalTo: textStack.centerYAnchor),
    ])
    return wrapper
  }

  private func buildFooter() -> NSView {
    let wrapper = NSView()
    wrapper.translatesAutoresizingMaskIntoConstraints = false

    settingsButton.translatesAutoresizingMaskIntoConstraints = false
    settingsButton.onClick = { [weak self] in self?.actions.openSettings() }

    quitButton.translatesAutoresizingMaskIntoConstraints = false
    quitButton.onClick = { [weak self] in self?.actions.quit() }

    wrapper.addSubview(settingsButton)
    wrapper.addSubview(quitButton)

    NSLayoutConstraint.activate([
      settingsButton.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 8),
      settingsButton.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 5),
      settingsButton.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -5),

      quitButton.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -8),
      quitButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
      settingsButton.trailingAnchor.constraint(lessThanOrEqualTo: quitButton.leadingAnchor, constant: -8),
    ])
    return wrapper
  }

  private func makeDivider() -> NSView {
    let line = NSBox()
    line.boxType = .separator
    line.translatesAutoresizingMaskIntoConstraints = false
    return line
  }

  private func makeInsetDivider(width: CGFloat) -> NSView {
    let wrapper = NSView()
    wrapper.translatesAutoresizingMaskIntoConstraints = false
    let line = makeDivider()
    wrapper.addSubview(line)
    NSLayoutConstraint.activate([
      wrapper.widthAnchor.constraint(equalToConstant: width),
      line.heightAnchor.constraint(equalToConstant: 1),
      line.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 6),
      line.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -6),
      line.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 1),
      line.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -1),
    ])
    return wrapper
  }

  // MARK: Dynamic Content Refresh

  private func reloadContent(_ snapshot: TrayPopoverSnapshot) {
    // Reset hover states on persistent buttons in case popover closed mid-hover
    newChatButton.resetInteractionState()
    showAppButton.resetInteractionState()
    settingsButton.resetInteractionState()
    quitButton.resetInteractionState()

    // Header summary & localized tooltips
    subtitleLabel.stringValue = snapshot.summaryLine
    newChatButton.configure(tooltip: snapshot.newChatLabel)
    showAppButton.configure(tooltip: snapshot.showLabel)

    // Body sections
    let previousScrollY = scrollView.contentView.bounds.origin.y
    clearStack(bodyStack)

    let innerWidth = Self.panelWidth - 16
    let hasAnyAgent = !snapshot.waiting.isEmpty || !snapshot.running.isEmpty || !snapshot.unread.isEmpty
    let hasWindowsBlock = !snapshot.windows.isEmpty || snapshot.showNewWindow

    if !snapshot.waiting.isEmpty {
      addAgentSection(
        title: snapshot.waitingHeader,
        symbol: "exclamationmark.circle.fill",
        accent: PopoverPalette.waitingAccent,
        kind: .waiting,
        items: snapshot.waiting,
        width: innerWidth)
    }

    if !snapshot.running.isEmpty {
      addAgentSection(
        title: snapshot.runningHeader,
        symbol: "bolt.circle.fill",
        accent: PopoverPalette.runningAccent,
        kind: .running,
        items: snapshot.running,
        width: innerWidth)
    }

    if !snapshot.unread.isEmpty {
      addAgentSection(
        title: snapshot.unreadHeader,
        symbol: "checkmark.circle.fill",
        accent: PopoverPalette.unreadAccent,
        kind: .unread,
        items: snapshot.unread,
        width: innerWidth)
    }

    if !hasAnyAgent {
      let hintText = snapshot.idleHintLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      let empty = EmptyStateHintView(
        hint: hintText.isEmpty ? snapshot.idleLabel : hintText,
        compact: hasWindowsBlock,
        maxTextWidth: innerWidth - 28)
      bodyStack.addArrangedSubview(empty)
      empty.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
    }

    if hasWindowsBlock {
      bodyStack.addArrangedSubview(makeInsetDivider(width: innerWidth))

      if !snapshot.windows.isEmpty {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 2
        section.translatesAutoresizingMaskIntoConstraints = false

        let trailingAction: SectionTrailingAction? = snapshot.showNewWindow
          ? SectionTrailingAction(symbol: "plus", tooltip: snapshot.newWindowLabel) { [weak self] in
              self?.actions.newWindow()
            }
          : nil

        let header = SectionHeaderView(
          symbol: "macwindow.on.rectangle",
          title: snapshot.windowsLabel,
          count: snapshot.windows.count,
          accent: .secondaryLabelColor,
          trailingAction: trailingAction)
        section.addArrangedSubview(header)
        header.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true

        for summary in snapshot.windows {
          let row = WindowRowView(summary: summary) { [weak self] in
            self?.actions.focusWindow(summary.viewId)
          }
          section.addArrangedSubview(row)
          row.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        }

        bodyStack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
      } else if snapshot.showNewWindow {
        let newWindowRow = NewWindowRowView(title: snapshot.newWindowLabel) { [weak self] in
          self?.actions.newWindow()
        }
        bodyStack.addArrangedSubview(newWindowRow)
        newWindowRow.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
      }
    }

    // Footer titles
    settingsButton.setTitle(snapshot.settingsLabel)
    quitButton.setTitle(snapshot.quitLabel)

    // Measure & resize cleanly
    bodyDocumentView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: 2000)
    bodyDocumentView.layoutSubtreeIfNeeded()
    let contentHeight = ceil(bodyStack.fittingSize.height)
    let scrollHeight = min(max(contentHeight, Self.minBodyHeight), Self.maxBodyHeight)
    bodyDocumentView.frame = NSRect(
      x: 0, y: 0, width: Self.panelWidth, height: max(contentHeight, scrollHeight))
    scrollHeightConstraint?.constant = scrollHeight

    let maxScrollY = max(0, bodyDocumentView.frame.height - scrollHeight)
    let targetY = min(max(0, previousScrollY), maxScrollY)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
    scrollView.reflectScrolledClipView(scrollView.contentView)

    view.layoutSubtreeIfNeeded()
    let totalHeight = ceil(rootStack.fittingSize.height)
    let newSize = NSSize(width: Self.panelWidth, height: totalHeight)
    preferredContentSize = newSize
    onPreferredSizeChanged?(newSize)
  }

  private func addAgentSection(
    title: String,
    symbol: String,
    accent: NSColor,
    kind: AgentRowKind,
    items: [TrayAgentItem],
    width: CGFloat
  ) {
    let section = NSStackView()
    section.orientation = .vertical
    section.alignment = .leading
    section.spacing = kind == .waiting ? 3 : 2
    section.translatesAutoresizingMaskIntoConstraints = false

    let header = SectionHeaderView(
      symbol: symbol, title: title, count: items.count, accent: accent)
    section.addArrangedSubview(header)
    header.widthAnchor.constraint(equalToConstant: width).isActive = true

    for item in items {
      let row = AgentRowView(item: item, kind: kind) { [weak self] in
        self?.actions.openAgent(item.id)
      }
      section.addArrangedSubview(row)
      row.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    bodyStack.addArrangedSubview(section)
    section.widthAnchor.constraint(equalToConstant: width).isActive = true
  }

  private func clearStack(_ stack: NSStackView) {
    for subview in stack.arrangedSubviews {
      stack.removeArrangedSubview(subview)
      subview.removeFromSuperview()
    }
  }
}

// MARK: Palette & Helpers

/// Dynamic warm brand palette calibrated for light & dark macOS popover glass.
/// Aligns with Ayte's terracotta accent (KestrelNotch), sage green activity,
/// soft indigo completion, and warm amber spark.
private enum PopoverPalette {
  /// Warm terracotta amber — dignified attention cue without harsh error-red glare.
  static let waitingAccent = dynamic(
    light: NSColor(srgbRed: 0.76, green: 0.34, blue: 0.20, alpha: 1.0),
    dark: NSColor(srgbRed: 0.91, green: 0.52, blue: 0.39, alpha: 1.0))

  /// Sage emerald — calm, high-contrast live activity indicator.
  static let runningAccent = dynamic(
    light: NSColor(srgbRed: 0.13, green: 0.48, blue: 0.34, alpha: 1.0),
    dark: NSColor(srgbRed: 0.33, green: 0.77, blue: 0.59, alpha: 1.0))

  /// Soft indigo — harmonized with the Ayte brand mark for completed turns.
  static let unreadAccent = dynamic(
    light: NSColor(srgbRed: 0.31, green: 0.33, blue: 0.79, alpha: 1.0),
    dark: NSColor(srgbRed: 0.53, green: 0.55, blue: 0.96, alpha: 1.0))

  /// Muted warm amber — empty-state spark harmonized with the app icon orb.
  static let sparkAccent = dynamic(
    light: NSColor(srgbRed: 0.75, green: 0.48, blue: 0.16, alpha: 0.85),
    dark: NSColor(srgbRed: 0.92, green: 0.70, blue: 0.34, alpha: 0.85))

  /// Restrained destructive tint used only on Quit hover/press.
  static let destructiveAccent = dynamic(
    light: NSColor(srgbRed: 0.77, green: 0.21, blue: 0.17, alpha: 1.0),
    dark: NSColor(srgbRed: 0.95, green: 0.40, blue: 0.36, alpha: 1.0))

  static let destructiveHover = dynamic(
    light: NSColor(srgbRed: 0.84, green: 0.22, blue: 0.18, alpha: 0.10),
    dark: NSColor(srgbRed: 0.95, green: 0.36, blue: 0.32, alpha: 0.16))

  /// Ultra-light warm wash for waiting rows (borderless).
  static let waitingRowSurface = dynamic(
    light: NSColor(srgbRed: 0.85, green: 0.43, blue: 0.26, alpha: 0.065),
    dark: NSColor(srgbRed: 0.91, green: 0.52, blue: 0.39, alpha: 0.10))

  static let waitingRowHover = dynamic(
    light: NSColor(srgbRed: 0.85, green: 0.43, blue: 0.26, alpha: 0.13),
    dark: NSColor(srgbRed: 0.91, green: 0.52, blue: 0.39, alpha: 0.18))

  static let waitingRowPressed = dynamic(
    light: NSColor(srgbRed: 0.85, green: 0.43, blue: 0.26, alpha: 0.19),
    dark: NSColor(srgbRed: 0.91, green: 0.52, blue: 0.39, alpha: 0.25))

  /// Neutral frosted hover/pressed washes for borderless rows & icon buttons.
  static let subtleHover = dynamic(
    light: NSColor(white: 0.0, alpha: 0.055),
    dark: NSColor(white: 1.0, alpha: 0.085))

  static let subtlePressed = dynamic(
    light: NSColor(white: 0.0, alpha: 0.10),
    dark: NSColor(white: 1.0, alpha: 0.14))

  private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
  }
}

private func makeSingleLineLabel(
  size: CGFloat, weight: NSFont.Weight, color: NSColor
) -> NSTextField {
  let label = NSTextField(labelWithString: "")
  label.translatesAutoresizingMaskIntoConstraints = false
  label.font = NSFont.systemFont(ofSize: size, weight: weight)
  label.textColor = color
  label.maximumNumberOfLines = 1
  label.usesSingleLineMode = true
  label.lineBreakMode = .byTruncatingTail
  label.cell?.truncatesLastVisibleLine = true
  label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  return label
}

private func sfSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
  guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
  let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
  return base.withSymbolConfiguration(config) ?? base
}

private final class FlippedContainerView: NSView {
  override var isFlipped: Bool { true }
}

/// Base interactive surface with smooth hover/pressed layer states that work
/// even when Ayte is not the active application.
private class HoverInteractiveView: NSView {
  var onClick: (() -> Void)?
  private(set) var isHovered = false
  private(set) var isPressed = false
  private var trackingAreaRef: NSTrackingArea?

  override var wantsUpdateLayer: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerCurve = .continuous
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  func resetInteractionState() {
    guard isHovered || isPressed else { return }
    isHovered = false
    isPressed = false
    needsDisplay = true
    hoverDidChange()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    return bounds.contains(local) ? self : nil
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let existing = trackingAreaRef {
      removeTrackingArea(existing)
    }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil)
    addTrackingArea(area)
    trackingAreaRef = area
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    needsDisplay = true
    hoverDidChange()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    isPressed = false
    needsDisplay = true
    hoverDidChange()
  }

  override func mouseDown(with event: NSEvent) {
    isPressed = true
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    let wasPressed = isPressed
    isPressed = false
    needsDisplay = true
    let local = convert(event.locationInWindow, from: nil)
    if wasPressed && bounds.contains(local) {
      onClick?()
    }
  }

  func hoverDidChange() {}
}

// MARK: Header Icon Button

private final class HeaderIconButton: HoverInteractiveView {
  private let iconView = NSImageView()

  init(symbol: String) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    iconView.image = sfSymbol(symbol, pointSize: 12.5, weight: .medium)
    iconView.contentTintColor = .secondaryLabelColor
    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 26),
      heightAnchor.constraint(equalToConstant: 26),
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  func configure(tooltip: String) {
    self.toolTip = tooltip
    setAccessibilityLabel(tooltip)
  }

  override func hoverDidChange() {
    iconView.contentTintColor = isHovered ? .labelColor : .secondaryLabelColor
  }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.cornerRadius = 6.5
      if isPressed {
        layer?.backgroundColor = PopoverPalette.subtlePressed.cgColor
      } else if isHovered {
        layer?.backgroundColor = PopoverPalette.subtleHover.cgColor
      } else {
        layer?.backgroundColor = NSColor.clear.cgColor
      }
    }
  }
}

// MARK: Section Header

private struct SectionTrailingAction {
  let symbol: String
  let tooltip: String
  let action: () -> Void
}

private final class SectionActionButton: HoverInteractiveView {
  private let iconView = NSImageView()

  init(symbol: String, tooltip: String, action: @escaping () -> Void) {
    super.init(frame: .zero)
    self.onClick = action
    translatesAutoresizingMaskIntoConstraints = false
    self.toolTip = tooltip
    setAccessibilityLabel(tooltip)

    iconView.image = sfSymbol(symbol, pointSize: 10.5, weight: .semibold)
    iconView.contentTintColor = .secondaryLabelColor
    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 20),
      heightAnchor.constraint(equalToConstant: 20),
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func hoverDidChange() {
    iconView.contentTintColor = isHovered ? .labelColor : .secondaryLabelColor
  }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.cornerRadius = 5
      if isPressed {
        layer?.backgroundColor = PopoverPalette.subtlePressed.cgColor
      } else if isHovered {
        layer?.backgroundColor = PopoverPalette.subtleHover.cgColor
      } else {
        layer?.backgroundColor = NSColor.clear.cgColor
      }
    }
  }
}

private final class SectionHeaderView: NSView {
  init(
    symbol: String,
    title: String,
    count: Int?,
    accent: NSColor,
    trailingAction: SectionTrailingAction? = nil
  ) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    let icon = NSImageView()
    icon.image = sfSymbol(symbol, pointSize: 10.5, weight: .semibold)
    icon.contentTintColor = accent
    icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 12),
      icon.heightAnchor.constraint(equalToConstant: 12),
    ])

    let label = makeSingleLineLabel(size: 11, weight: .semibold, color: .secondaryLabelColor)
    label.stringValue = title
    label.setContentHuggingPriority(.required, for: .horizontal)

    addSubview(icon)
    addSubview(label)

    var lastLeadingView: NSView = label
    if let count {
      let countBadge = NSTextField(labelWithString: "\(count)")
      countBadge.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
      countBadge.textColor = .tertiaryLabelColor
      countBadge.translatesAutoresizingMaskIntoConstraints = false
      countBadge.setContentHuggingPriority(.required, for: .horizontal)
      countBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
      addSubview(countBadge)
      NSLayoutConstraint.activate([
        countBadge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5),
        countBadge.centerYAnchor.constraint(equalTo: label.centerYAnchor),
      ])
      lastLeadingView = countBadge
    }

    var constraints: [NSLayoutConstraint] = [
      heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 2),
      label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2),
    ]

    if let trailingAction {
      let button = SectionActionButton(
        symbol: trailingAction.symbol,
        tooltip: trailingAction.tooltip,
        action: trailingAction.action)
      addSubview(button)
      constraints.append(contentsOf: [
        button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        button.centerYAnchor.constraint(equalTo: centerYAnchor),
        lastLeadingView.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -6),
      ])
    } else {
      constraints.append(
        lastLeadingView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6))
    }

    NSLayoutConstraint.activate(constraints)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }
}

// MARK: Agent Row

private enum AgentRowKind {
  case waiting
  case running
  case unread

  var accent: NSColor {
    switch self {
    case .waiting: return PopoverPalette.waitingAccent
    case .running: return PopoverPalette.runningAccent
    case .unread: return PopoverPalette.unreadAccent
    }
  }
}

private final class AgentRowView: HoverInteractiveView {
  private let kind: AgentRowKind
  private var accentBar: NSView?
  private var statusDot: NSView?
  private let chevronView = NSImageView()

  init(item: TrayAgentItem, kind: AgentRowKind, action: @escaping () -> Void) {
    self.kind = kind
    super.init(frame: .zero)
    self.onClick = action
    translatesAutoresizingMaskIntoConstraints = false

    let project = item.project.trimmingCharacters(in: .whitespacesAndNewlines)
    let detail = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
    let fullMeta = [project, detail].filter { !$0.isEmpty }.joined(separator: " · ")

    setAccessibilityLabel(fullMeta.isEmpty ? item.title : "\(item.title), \(fullMeta)")
    if !fullMeta.isEmpty {
      self.toolTip = "\(item.title)\n\(fullMeta)"
    } else {
      self.toolTip = item.title
    }

    // Full-width single-line title
    let titleLabel = makeSingleLineLabel(size: 12.5, weight: .medium, color: .labelColor)
    titleLabel.stringValue = item.title

    let contentStack = NSStackView(views: [titleLabel])
    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = 2
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.widthAnchor.constraint(lessThanOrEqualTo: contentStack.widthAnchor).isActive = true

    // Compact merged second line: "Project · Summary/Kernel"
    if !project.isEmpty || !detail.isEmpty {
      let metaLabel = makeSingleLineLabel(size: 11, weight: .regular, color: .secondaryLabelColor)
      metaLabel.attributedStringValue = Self.makeMetadataString(project: project, detail: detail)
      contentStack.addArrangedSubview(metaLabel)
      metaLabel.widthAnchor.constraint(lessThanOrEqualTo: contentStack.widthAnchor).isActive = true
    }

    // Subtle chevron that reveals on hover without reflowing text
    chevronView.image = sfSymbol("chevron.right", pointSize: 9.5, weight: .semibold)
    chevronView.contentTintColor = .secondaryLabelColor
    chevronView.alphaValue = 0
    chevronView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      chevronView.widthAnchor.constraint(equalToConstant: 10),
      chevronView.heightAnchor.constraint(equalToConstant: 12),
    ])

    addSubview(contentStack)
    addSubview(chevronView)

    var constraints: [NSLayoutConstraint] = [
      contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
      contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 6.5),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6.5),
      contentStack.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -6),

      chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ]

    if kind == .waiting {
      let bar = NSView()
      bar.wantsLayer = true
      bar.translatesAutoresizingMaskIntoConstraints = false
      addSubview(bar)
      self.accentBar = bar
      constraints.append(contentsOf: [
        bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
        bar.widthAnchor.constraint(equalToConstant: 2.5),
        bar.topAnchor.constraint(equalTo: topAnchor, constant: 7),
        bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
      ])
    } else {
      let dot = NSView()
      dot.wantsLayer = true
      dot.translatesAutoresizingMaskIntoConstraints = false
      addSubview(dot)
      self.statusDot = dot
      constraints.append(contentsOf: [
        dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
        dot.widthAnchor.constraint(equalToConstant: 6),
        dot.heightAnchor.constraint(equalToConstant: 6),
        dot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      ])
    }

    NSLayoutConstraint.activate(constraints)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  private static func makeMetadataString(project: String, detail: String) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail

    let regularAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .regular),
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: paragraph,
    ]

    if project.isEmpty {
      return NSAttributedString(string: detail, attributes: regularAttrs)
    }
    if detail.isEmpty {
      return NSAttributedString(string: project, attributes: regularAttrs)
    }

    let displayProject = project.count > 22
      ? String(project.prefix(21)) + "…"
      : project

    let result = NSMutableAttributedString(
      string: displayProject,
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: paragraph,
      ])
    result.append(NSAttributedString(
      string: " · ",
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.tertiaryLabelColor,
        .paragraphStyle: paragraph,
      ]))
    result.append(NSAttributedString(string: detail, attributes: regularAttrs))
    return result
  }

  override func hoverDidChange() {
    chevronView.alphaValue = isHovered ? 1.0 : 0.0
  }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.cornerRadius = 8
      layer?.borderWidth = 0

      if kind == .waiting {
        accentBar?.layer?.cornerRadius = 1.25
        let barAlpha: CGFloat = (isHovered || isPressed) ? 1.0 : 0.88
        accentBar?.layer?.backgroundColor = PopoverPalette.waitingAccent.withAlphaComponent(barAlpha).cgColor
        if isPressed {
          layer?.backgroundColor = PopoverPalette.waitingRowPressed.cgColor
        } else if isHovered {
          layer?.backgroundColor = PopoverPalette.waitingRowHover.cgColor
        } else {
          layer?.backgroundColor = PopoverPalette.waitingRowSurface.cgColor
        }
      } else {
        statusDot?.layer?.cornerRadius = 3
        statusDot?.layer?.backgroundColor = kind.accent.cgColor
        if isPressed {
          layer?.backgroundColor = PopoverPalette.subtlePressed.cgColor
        } else if isHovered {
          layer?.backgroundColor = PopoverPalette.subtleHover.cgColor
        } else {
          layer?.backgroundColor = NSColor.clear.cgColor
        }
      }
    }
  }
}

// MARK: Empty State Hint

private final class EmptyStateHintView: NSView {
  init(hint: String, compact: Bool, maxTextWidth: CGFloat) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    let icon = NSImageView()
    icon.image = sfSymbol("sparkles", pointSize: 14, weight: .medium)
    icon.contentTintColor = PopoverPalette.sparkAccent
    icon.translatesAutoresizingMaskIntoConstraints = false

    let hintLabel = NSTextField(labelWithString: hint)
    hintLabel.translatesAutoresizingMaskIntoConstraints = false
    hintLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    hintLabel.textColor = .secondaryLabelColor
    hintLabel.alignment = .center
    hintLabel.maximumNumberOfLines = 2
    hintLabel.lineBreakMode = .byWordWrapping
    hintLabel.preferredMaxLayoutWidth = maxTextWidth

    let stack = NSStackView(views: [icon, hintLabel])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 5
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    let vPad: CGFloat = compact ? 9 : 14
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor, constant: vPad),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vPad),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }
}

// MARK: Window Rows

private final class WindowRowView: HoverInteractiveView {
  private var editedDot: NSView?

  init(summary: AppWindows.WindowSummary, action: @escaping () -> Void) {
    super.init(frame: .zero)
    self.onClick = action
    translatesAutoresizingMaskIntoConstraints = false
    setAccessibilityLabel(summary.title)
    self.toolTip = summary.title

    let icon = NSImageView()
    icon.image = sfSymbol("macwindow", pointSize: 11.5, weight: summary.active ? .semibold : .regular)
    icon.contentTintColor = summary.active ? .labelColor : .secondaryLabelColor
    icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 12),
      icon.heightAnchor.constraint(equalToConstant: 12),
    ])

    let titleLabel = makeSingleLineLabel(
      size: 12, weight: summary.active ? .medium : .regular, color: .labelColor)
    titleLabel.stringValue = summary.title

    addSubview(icon)
    addSubview(titleLabel)

    var trailingAnchorTarget = trailingAnchor
    var trailingOffset: CGFloat = -8

    if summary.active {
      let check = NSImageView()
      check.image = sfSymbol("checkmark", pointSize: 10, weight: .semibold)
      check.contentTintColor = .secondaryLabelColor
      check.translatesAutoresizingMaskIntoConstraints = false
      addSubview(check)
      NSLayoutConstraint.activate([
        check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        check.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
      trailingAnchorTarget = check.leadingAnchor
      trailingOffset = -6
    }

    if summary.edited {
      let dot = NSView()
      dot.wantsLayer = true
      dot.translatesAutoresizingMaskIntoConstraints = false
      addSubview(dot)
      self.editedDot = dot
      NSLayoutConstraint.activate([
        dot.widthAnchor.constraint(equalToConstant: 5.5),
        dot.heightAnchor.constraint(equalToConstant: 5.5),
        dot.trailingAnchor.constraint(equalTo: trailingAnchorTarget, constant: trailingOffset),
        dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
      trailingAnchorTarget = dot.leadingAnchor
      trailingOffset = -6
    }

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 28),
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchorTarget, constant: trailingOffset),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.cornerRadius = 7
      if isPressed {
        layer?.backgroundColor = PopoverPalette.subtlePressed.cgColor
      } else if isHovered {
        layer?.backgroundColor = PopoverPalette.subtleHover.cgColor
      } else {
        layer?.backgroundColor = NSColor.clear.cgColor
      }
      editedDot?.layer?.cornerRadius = 2.75
      editedDot?.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
    }
  }
}

private final class NewWindowRowView: HoverInteractiveView {
  private let iconView = NSImageView()
  private let titleLabel = makeSingleLineLabel(size: 12, weight: .regular, color: .secondaryLabelColor)

  init(title: String, action: @escaping () -> Void) {
    super.init(frame: .zero)
    self.onClick = action
    translatesAutoresizingMaskIntoConstraints = false
    setAccessibilityLabel(title)

    iconView.image = sfSymbol("plus", pointSize: 11, weight: .semibold)
    iconView.contentTintColor = .secondaryLabelColor
    iconView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: 12),
      iconView.heightAnchor.constraint(equalToConstant: 12),
    ])

    titleLabel.stringValue = title

    addSubview(iconView)
    addSubview(titleLabel)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 28),
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func hoverDidChange() {
    let color: NSColor = isHovered ? .labelColor : .secondaryLabelColor
    iconView.contentTintColor = color
    titleLabel.textColor = color
  }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.cornerRadius = 7
      if isPressed {
        layer?.backgroundColor = PopoverPalette.subtlePressed.cgColor
      } else if isHovered {
        layer?.backgroundColor = PopoverPalette.subtleHover.cgColor
      } else {
        layer?.backgroundColor = NSColor.clear.cgColor
      }
    }
  }
}

// MARK: Footer Button

private final class FooterActionButton: HoverInteractiveView {
  private let destructive: Bool
  private let iconView = NSImageView()
  private let titleLabel = makeSingleLineLabel(size: 12, weight: .regular, color: .secondaryLabelColor)

  init(symbol: String, title: String, destructive: Bool) {
    self.destructive = destructive
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    setAccessibilityLabel(title)

    iconView.image = sfSymbol(symbol, pointSize: 12, weight: .medium)
    iconView.contentTintColor = .secondaryLabelColor
    iconView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: 14),
      iconView.heightAnchor.constraint(equalToConstant: 14),
    ])

    titleLabel.stringValue = title

    let stack = NSStackView(views: [iconView, titleLabel])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 28),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  func setTitle(_ title: String) {
    titleLabel.stringValue = title
    setAccessibilityLabel(title)
  }

  override func hoverDidChange() {
    if isHovered {
      let color: NSColor = destructive ? PopoverPalette.destructiveAccent : .labelColor
      iconView.contentTintColor = color
      titleLabel.textColor = color
    } else {
      iconView.contentTintColor = .secondaryLabelColor
      titleLabel.textColor = .secondaryLabelColor
    }
  }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.cornerRadius = 6
      if isPressed {
        layer?.backgroundColor = (destructive
          ? PopoverPalette.destructiveHover
          : PopoverPalette.subtlePressed).cgColor
      } else if isHovered {
        layer?.backgroundColor = (destructive
          ? PopoverPalette.destructiveHover
          : PopoverPalette.subtleHover).cgColor
      } else {
        layer?.backgroundColor = NSColor.clear.cgColor
      }
    }
  }
}
