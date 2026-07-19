// Swift side of the spike: owns the NSWindow, a native URL bar, and the
// container NSView that the CEF browser is parented into via CefBridge.

import AppKit

@objc(BZAppDelegate)
public class BZAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var window: NSWindow!
  var urlField: NSTextField!
  var browserContainer: NSView!

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

    let bridge = CefBridge.shared
    bridge.onTitleChange = { [weak self] title in
      self?.window.title = title
    }
    bridge.onAddressChange = { [weak self] url in
      self?.urlField.stringValue = url
    }

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    urlField.stringValue = bridge.initialURL
    bridge.createBrowser(in: browserContainer, url: bridge.initialURL)
  }

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

    NSApp.mainMenu = mainMenu
  }
}
