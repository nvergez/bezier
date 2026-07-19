// Swift side of the spike: owns the NSWindow, a native URL bar, and the
// container NSView that the CEF browser is parented into via CefBridge.

import AppKit

@objc(BZAppDelegate)
public class BZAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var window: NSWindow!
  var urlField: NSTextField!
  var browserContainer: NSView!
  var overlay: OverlayController!

  public func applicationDidFinishLaunching(_ notification: Notification) {
    buildMainMenu()

    let contentRect = NSRect(x: 0, y: 0, width: 1200, height: 850)
    window = NSWindow(
      contentRect: contentRect,
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "Bézier CEF Spike"
    window.delegate = self
    window.center()

    let content = window.contentView!
    let barHeight: CGFloat = 38

    // Native URL bar strip pinned to the top.
    let bar = NSView(
      frame: NSRect(
        x: 0, y: content.bounds.height - barHeight,
        width: content.bounds.width, height: barHeight))
    bar.autoresizingMask = [.width, .minYMargin]

    urlField = NSTextField(
      frame: NSRect(x: 8, y: 7, width: bar.bounds.width - 92, height: 24))
    urlField.autoresizingMask = [.width]
    urlField.placeholderString = "URL"
    urlField.target = self
    urlField.action = #selector(navigate(_:))
    bar.addSubview(urlField)

    let goButton = NSButton(title: "Go", target: self, action: #selector(navigate(_:)))
    goButton.frame = NSRect(x: bar.bounds.width - 78, y: 5, width: 70, height: 28)
    goButton.autoresizingMask = [.minXMargin]
    bar.addSubview(goButton)

    // App-owned container view the CEF browser becomes a child of.
    browserContainer = NSView(
      frame: NSRect(
        x: 0, y: 0,
        width: content.bounds.width, height: content.bounds.height - barHeight))
    browserContainer.autoresizingMask = [.width, .height]

    content.addSubview(browserContainer)
    content.addSubview(bar)

    // Overlay spike (Bézier #8): controller managing native views composited
    // over the CEF view. --trace-dir=PATH is where frame traces / state dumps
    // land; --prefer-promotion moves the window to the highest-refresh screen.
    overlay = OverlayController(
      window: window, contentView: content, browserContainer: browserContainer)
    for arg in ProcessInfo.processInfo.arguments {
      if arg.hasPrefix("--trace-dir=") {
        overlay.traceDir = URL(
          fileURLWithPath: String(arg.dropFirst("--trace-dir=".count)),
          isDirectory: true)
      }
    }
    if ProcessInfo.processInfo.arguments.contains("--prefer-promotion") {
      moveToHighestRefreshScreen()
    }

    let bridge = CefBridge.shared
    bridge.onTitleChange = { [weak self] title in
      self?.window.title = title
    }
    bridge.onAddressChange = { [weak self] url in
      self?.urlField.stringValue = url
      self?.overlay.currentURL = url
    }

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    urlField.stringValue = bridge.initialURL
    bridge.createBrowser(in: browserContainer, url: bridge.initialURL)
  }

  private func moveToHighestRefreshScreen() {
    // Prefer the built-in ProMotion panel when it can do >=120 Hz (the spike's
    // target hardware); otherwise fall back to whatever refreshes fastest.
    func isBuiltin(_ s: NSScreen) -> Bool {
      guard
        let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? NSNumber
      else { return false }
      return CGDisplayIsBuiltin(n.uint32Value) != 0
    }
    let screens = NSScreen.screens
    guard
      let best = screens.first(where: { isBuiltin($0) && $0.maximumFramesPerSecond >= 120 })
        ?? screens.max(by: {
          $0.maximumFramesPerSecond < $1.maximumFramesPerSecond
        })
    else { return }
    if window.screen != best {
      let f = best.visibleFrame
      let size = window.frame.size
      window.setFrameOrigin(
        NSPoint(
          x: f.midX - size.width / 2,
          y: f.midY - size.height / 2))
    }
    NSLog(
      "BezierSpike: window on screen '\(window.screen?.localizedName ?? "?")' "
        + "maxFPS=\(window.screen?.maximumFramesPerSecond ?? 0)")
  }

  @objc func toggleStaticOverlay(_ sender: Any?) { overlay.toggleStaticOverlay() }
  @objc func toggleCommandBar(_ sender: Any?) { overlay.toggleCommandBar() }
  @objc func runTracedLoop(_ sender: Any?) { overlay.runTracedLoop() }

  @objc func navigate(_ sender: Any?) {
    var url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
    guard !url.isEmpty else { return }
    if !url.contains("://") {
      url = "https://" + url
    }
    CefBridge.shared.loadURL(url)
  }

  // Window close (red button): deny while browsers are still open and start
  // the CEF close-down; the in-progress close is allowed once isClosing.
  public func windowShouldClose(_ sender: NSWindow) -> Bool {
    let bridge = CefBridge.shared
    if bridge.isClosing {
      return true
    }
    bridge.closeAllBrowsers(false)
    return false
  }

  // CEF tears the browser down when its NSView is dealloc'ed (see cefsimple's
  // comments). Swift holds strong refs (window → contentView → container →
  // CEF view), so drop the CEF view explicitly once the window really closes;
  // OnBeforeClose then stops the app run loop.
  public func windowWillClose(_ notification: Notification) {
    browserContainer?.subviews.forEach { $0.removeFromSuperview() }
    browserContainer = nil
    window = nil
  }

  public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func buildMainMenu() {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      NSMenuItem(
        title: "Quit BezierSpike",
        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(
      NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    editMenu.addItem(
      NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(
      NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editMenu.addItem(
      NSMenuItem(
        title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    editItem.submenu = editMenu

    let viewItem = NSMenuItem()
    mainMenu.addItem(viewItem)
    let viewMenu = NSMenu(title: "View")
    viewMenu.addItem(
      NSMenuItem(
        title: "Toggle Static Overlay",
        action: #selector(toggleStaticOverlay(_:)), keyEquivalent: "1"))
    viewMenu.addItem(
      NSMenuItem(
        title: "Toggle Command Bar",
        action: #selector(toggleCommandBar(_:)), keyEquivalent: "k"))
    viewMenu.addItem(
      NSMenuItem(
        title: "Run Traced Animation Loop",
        action: #selector(runTracedLoop(_:)), keyEquivalent: "l"))
    viewItem.submenu = viewMenu

    NSApp.mainMenu = mainMenu
  }
}
