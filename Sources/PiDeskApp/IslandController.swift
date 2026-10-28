import AppKit
import Combine
import PiDeskCore
import PiDeskTransport
import SwiftUI

private final class IslandPanel: NSPanel {
  var allowKey: () -> Bool = { false }
  var escape: () -> Void = {}
  override var canBecomeKey: Bool { allowKey() }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { escape() }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { escape() } else { super.keyDown(with: event) }
  }
}

private final class IslandHostingView: NSHostingView<AnyView> {
  var hoverChanged: (Bool) -> Void = { _ in }
  private var hoverArea: NSTrackingArea?
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea = hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
      userInfo: nil)
    addTrackingArea(area)
    hoverArea = area
  }
  override func mouseEntered(with event: NSEvent) { hoverChanged(true) }
  override func mouseExited(with event: NSEvent) { hoverChanged(false) }
}
@MainActor final class IslandController: NSObject, ObservableObject {
  @Published var state = IslandInteraction()
  @Published var geometry = IslandGeometry.calculate(
    screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visible: CGRect(x: 0, y: 0, width: 1440, height: 868), safeTop: 0, cameraGap: 0)
  @Published var composing: Identity?
  @Published var mode = "followUp"
  private var panel: IslandPanel?
  private weak var manager: NSWindow?
  private weak var model: AppModel?
  private var screen: NSScreen?
  private var leave: DispatchWorkItem?
  private var enter: DispatchWorkItem?
  private var subscriptions = Set<AnyCancellable>()
  private var configured = false
  private var started = false
  private var rows = 0
  private var pointerInside = false
  private var localMonitor: Any?
  var reducedMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      || (model?.isPreview == true && CommandLine.arguments.contains("--reduce-motion-preview"))
  }
  func start(model: AppModel) {
    guard !configured else { return }
    configured = true
    self.model = model
    createPanel(model: model)
  }
  func attach(model: AppModel, manager: NSWindow) {
    start(model: model)
    attachManager(manager)
  }
  func attachManager(_ manager: NSWindow) {
    self.manager = manager
    screen = previewScreen() ?? manager.screen ?? screen
    NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification, object: manager)
      .receive(on: RunLoop.main).sink { [weak self] _ in
        self?.screen = self?.previewScreen() ?? manager.screen ?? NSScreen.main
        self?.updateGeometry(animated: false)
      }.store(in: &subscriptions)
    updateGeometry(animated: false)
  }
  private func previewScreen() -> NSScreen? {
    guard model?.isPreview == true,
      let i = CommandLine.arguments.firstIndex(of: "--preview-screen"),
      i + 1 < CommandLine.arguments.count, let index = Int(CommandLine.arguments[i + 1]),
      NSScreen.screens.indices.contains(index)
    else { return nil }
    return NSScreen.screens[index]
  }
  private func createPanel(model: AppModel) {
    guard !started else { return }
    started = true
    model.showIsland = { [weak self] in self?.revealForInteraction() }
    screen = previewScreen() ?? manager?.screen ?? NSScreen.main ?? NSScreen.screens.first
    let panel = IslandPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.title = "Pi Desk 顶部速览"
    panel.identifier = NSUserInterfaceItemIdentifier("pi-desk-island")
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.isMovable = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.allowKey = { [weak self] in self?.state.expanded == true }
    panel.escape = { [weak self] in self?.escape() }
    let hosting = IslandHostingView(
      rootView: AnyView(IslandView().environmentObject(model).environmentObject(self)))
    hosting.hoverChanged = { [weak self] value in self?.hover(value) }
    panel.contentView = hosting
    self.panel = panel
    updateGeometry(animated: false)
    panel.orderFrontRegardless()
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .receive(on: RunLoop.main).sink { [weak self] _ in
        self?.screen = self?.previewScreen() ?? self?.manager?.screen ?? NSScreen.main
        self?.updateGeometry(animated: false)
      }.store(in: &subscriptions)
    model.$store.receive(on: RunLoop.main).sink { [weak self] store in
      guard let self = self else { return }
      let count = min(store.sessions.count, 4)
      if count != self.rows {
        self.rows = count
        self.updateGeometry(animated: false)
      }
    }.store(in: &subscriptions)
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self = self else { return event }
      if self.model?.isPreview == true { DispatchQueue.main.async { self.reportPreview() } }
      guard NSApp.keyWindow === self.panel, event.keyCode == 53 else { return event }
      self.escape()
      return nil
    }
    if CommandLine.arguments.contains("--island-expanded") { expand() }
  }
  func updateGeometry(animated: Bool) {
    guard let panel = panel, let screen = screen ?? NSScreen.main else { return }
    var gap = 0.0
    if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
      gap = max(0, right.minX - left.maxX)
    }
    geometry = IslandGeometry.calculate(
      screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top,
      cameraGap: gap)
    var frame = state.expanded ? geometry.expanded : geometry.compact
    if state.expanded {
      let height = min(
        frame.height,
        Double((rows == 0 ? 260 : 200 + min(rows, 4) * 132) + (composing == nil ? 0 : 170))
          + geometry.topInset)
      frame.origin.y = frame.maxY - height
      frame.size.height = height
    }
    panel.setFrame(frame, display: true, animate: animated && !reducedMotion)
    reportPreview()
  }
  private func reportPreview() {
    guard model?.isPreview == true, let i = CommandLine.arguments.firstIndex(of: "--visual-report"),
      i + 1 < CommandLine.arguments.count, let panel = panel
    else { return }
    let values: [String: Any] = [
      "synthetic": true, "panelWindowId": panel.windowNumber,
      "managerWindowId": manager?.windowNumber ?? 0, "expanded": state.expanded,
      "pinned": state.pinned, "editing": state.editing, "isVisible": panel.isVisible,
      "level": panel.level.rawValue,
      "frame": [
        "x": panel.frame.minX, "y": panel.frame.minY, "width": panel.frame.width,
        "height": panel.frame.height,
      ], "cameraGap": geometry.cameraGap, "safeTop": geometry.topInset,
      "reduceMotion": reducedMotion,
      "firstResponder": panel.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "none",
      "managerFirstResponder": manager?.firstResponder.map { NSStringFromClass(type(of: $0)) }
        ?? "none",
      "draftCount": model?.drafts.count ?? 0, "keyWindow": NSApp.keyWindow?.windowNumber ?? 0,
      "screens": NSScreen.screens.map {
        ["width": $0.frame.width, "height": $0.frame.height, "safeTop": $0.safeAreaInsets.top]
      },
    ]
    if let data = try? JSONSerialization.data(withJSONObject: values) {
      try? PrivateSettings.save(data, to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    }
  }
  func hover(_ inside: Bool) {
    let wasInside = pointerInside
    pointerInside = inside
    if inside {
      leave?.cancel()
      if !state.expanded {
        enter?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.expand() }
        enter = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
      }
    } else {
      enter?.cancel()
      guard wasInside, state.mayAutoCollapse, composing == nil else { return }
      leave?.cancel()
      let work = DispatchWorkItem { [weak self] in
        guard let self = self, self.state.mayAutoCollapse, self.composing == nil,
          let panel = self.panel, !panel.frame.contains(NSEvent.mouseLocation)
        else { return }
        self.collapse()
      }
      leave = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
  }
  func revealForInteraction() {
    expand()
    panel?.makeKey()
  }
  func expand() {
    leave?.cancel()
    guard !state.expanded else { return }
    state.expand()
    updateGeometry(animated: true)
  }
  func collapse() {
    leave?.cancel()
    enter?.cancel()
    composing = nil
    state.collapse()
    panel?.makeFirstResponder(nil)
    updateGeometry(animated: true)
  }
  func escape() {
    let wasEditing = state.editing
    state.escape()
    if wasEditing { panel?.makeFirstResponder(nil) }
    if !state.expanded { composing = nil }
    updateGeometry(animated: true)
  }
  func pin() {
    state.pinned.toggle()
    reportPreview()
  }
  func compose(_ identity: Identity, mode: String) {
    state.expand()
    composing = identity
    self.mode = mode
    state.editing = true
    updateGeometry(animated: true)
    panel?.makeKey()
  }
  func finishComposing() {
    state.editing = false
    composing = nil
    panel?.makeFirstResponder(nil)
    updateGeometry(animated: true)
  }
  func editing(_ value: Bool) {
    state.editing = value
    reportPreview()
  }
  func openManager(_ identity: Identity? = nil) {
    if let identity = identity {
      model?.select(identity)
      model?.page = "会话"
    }
    if let manager {
      manager.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    } else {
      model?.showManager()
    }
  }
  func stop() {
    leave?.cancel()
    enter?.cancel()
    if let localMonitor = localMonitor { NSEvent.removeMonitor(localMonitor) }
    subscriptions.removeAll()
    panel?.close()
    panel = nil
    configured = false
    started = false
  }
}
