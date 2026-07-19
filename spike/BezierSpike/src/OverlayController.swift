// Overlay spike (Bézier #8): native AppKit views composited OVER the CEF
// browser view, in the same window. Three probes:
//   1. static NSVisualEffectView panel + translucent plain view (z-order,
//      clipping, sync during scroll/resize),
//   2. animated command-bar panel (Core Animation slide+fade) with a
//      CADisplayLink frame-pacing trace written as JSON,
//   3. first-responder/keyboard focus (text field in the overlay vs the page).
//
// Automation: the app listens for Darwin notifications (post with
// `notifyutil -p <name>`) so tests don't depend on AX click targeting:
//   com.bezier.spike.static  toggle the static overlay
//   com.bezier.spike.bar     toggle the command bar (focuses its field)
//   com.bezier.spike.loop    run a traced N-cycle show/hide animation loop
//   com.bezier.spike.trace   start/stop a standalone frame trace (no animation)
//   com.bezier.spike.dump    write state.json (focus probe readback)
// Trace/label/state files live in the directory given by --trace-dir=PATH.

import AppKit
import QuartzCore

// CADisplayLink (macOS 14+) tick recorder. Measures the main thread's ability
// to keep up with the display's refresh cadence: if the main run loop is busy
// (CEF pump, layout, anything), ticks arrive late and the interval shows it.
// Note the slide/fade itself is committed once and animated by the render
// server; this trace answers "did the app's main thread hold frame rate while
// the overlay animated and web content was live", which is the compositor
// -pressure question the spike cares about.
final class FrameTraceRecorder: NSObject {
  private var frames: [(ts: Double, target: Double)] = []
  private var events: [(t: Double, label: String)] = []
  var meta: [String: Any] = [:]
  private var link: CADisplayLink?
  private let outURL: URL

  init(outURL: URL) {
    self.outURL = outURL
    super.init()
    frames.reserveCapacity(8192)
  }

  func start(view: NSView) {
    let l = view.displayLink(target: self, selector: #selector(tick(_:)))
    // .common so the link keeps firing during event tracking (live resize,
    // scroll wheel) — same reasoning as the CEF pump's timer modes.
    l.add(to: .main, forMode: .common)
    link = l
    mark("trace.start")
  }

  @objc private func tick(_ l: CADisplayLink) {
    frames.append((l.timestamp, l.targetTimestamp))
  }

  func mark(_ label: String) {
    events.append((CACurrentMediaTime(), label))
  }

  func stopAndWrite() {
    mark("trace.stop")
    link?.invalidate()
    link = nil
    let dict: [String: Any] = [
      "meta": meta,
      "events": events.map { ["t": $0.t, "label": $0.label] },
      "frames": frames.map { ["t": $0.ts, "target": $0.target] },
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: dict, options: [.sortedKeys]) {
      try? data.write(to: outURL)
      NSLog("BezierSpike trace: \(frames.count) frames -> \(outURL.path)")
    } else {
      NSLog("BezierSpike trace: JSON serialization FAILED")
    }
  }
}

@objc(BZOverlayController)
public class OverlayController: NSObject {
  private weak var window: NSWindow!
  private weak var contentView: NSView!
  private weak var browserContainer: NSView!

  var traceDir: URL?
  var currentURL: String = ""

  // Static overlay (probe 1).
  private var staticPanel: NSVisualEffectView?
  private var staticSquare: NSView?
  private(set) var staticVisible = false

  // Command bar (probes 2 + 3).
  private var commandBar: NSVisualEffectView!
  private var commandField: NSTextField!
  private(set) var commandBarVisible = false
  private let animDuration: TimeInterval = 0.25
  private let barSize = NSSize(width: 620, height: 60)

  private var recorder: FrameTraceRecorder?
  private var loopActive = false

  @objc public init(window: NSWindow, contentView: NSView, browserContainer: NSView) {
    self.window = window
    self.contentView = contentView
    self.browserContainer = browserContainer
    super.init()
    buildCommandBar()
    registerDarwinNotifications()
  }

  // MARK: - Probe 1: static overlay

  @objc public func toggleStaticOverlay() {
    if staticVisible {
      staticPanel?.removeFromSuperview()
      staticSquare?.removeFromSuperview()
      staticPanel = nil
      staticSquare = nil
      staticVisible = false
      return
    }
    let bounds = browserContainer.frame  // in contentView coords
    let w: CGFloat = 460, h: CGFloat = 240
    let panel = NSVisualEffectView(
      frame: NSRect(
        x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h))
    panel.material = .hudWindow
    panel.blendingMode = .withinWindow  // the interesting case over CEF content
    panel.state = .active
    panel.wantsLayer = true
    panel.layer?.cornerRadius = 14
    panel.layer?.masksToBounds = true
    // Flexible margins on all sides keep it centered through live resize.
    panel.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]

    let title = NSTextField(labelWithString: "Native NSVisualEffectView (withinWindow) over CEF")
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.frame = NSRect(x: 20, y: h - 44, width: w - 40, height: 22)
    panel.addSubview(title)
    let sub = NSTextField(
      labelWithString: "Static overlay probe — z-order / clipping / resize sync")
    sub.font = .systemFont(ofSize: 12)
    sub.textColor = .secondaryLabelColor
    sub.frame = NSRect(x: 20, y: h - 66, width: w - 40, height: 18)
    panel.addSubview(sub)

    // Plain translucent view proves straight alpha compositing over the CEF
    // surface independent of vibrancy backdrop sampling.
    let square = NSView(
      frame: NSRect(x: panel.frame.maxX - 40, y: panel.frame.minY - 40, width: 130, height: 130))
    square.wantsLayer = true
    square.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.45).cgColor
    square.layer?.borderColor = NSColor.white.cgColor
    square.layer?.borderWidth = 2
    square.layer?.cornerRadius = 8
    square.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]

    contentView.addSubview(panel)
    contentView.addSubview(square)
    staticPanel = panel
    staticSquare = square
    staticVisible = true
  }

  // MARK: - Probe 2: animated command bar

  private func buildCommandBar() {
    let bar = NSVisualEffectView(
      frame: NSRect(origin: .zero, size: barSize))
    bar.material = .hudWindow
    bar.blendingMode = .withinWindow
    bar.state = .active
    bar.wantsLayer = true
    bar.layer?.cornerRadius = 12
    bar.layer?.masksToBounds = true
    bar.alphaValue = 0

    let prompt = NSTextField(labelWithString: "⌘")
    prompt.font = .systemFont(ofSize: 22, weight: .medium)
    prompt.frame = NSRect(x: 16, y: 16, width: 28, height: 28)
    bar.addSubview(prompt)

    let field = NSTextField(
      frame: NSRect(x: 52, y: 14, width: barSize.width - 68, height: 32))
    field.placeholderString = "Command bar overlay — type here"
    field.font = .systemFont(ofSize: 17)
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.autoresizingMask = [.width]
    bar.addSubview(field)

    commandBar = bar
    commandField = field
  }

  private func barFrames() -> (shown: NSRect, hidden: NSRect) {
    let b = contentView.bounds
    let x = b.midX - barSize.width / 2
    // Shown: floating near the top of the browser area (Arc command-bar-ish).
    let shownY = browserContainer.frame.maxY - barSize.height - 24
    let shown = NSRect(x: x, y: shownY, width: barSize.width, height: barSize.height)
    let hidden = shown.offsetBy(dx: 0, dy: 60)  // slides down into place
    return (shown, hidden)
  }

  @objc public func toggleCommandBar() {
    if commandBarVisible {
      hideCommandBar {}
    } else {
      showCommandBar {}
    }
  }

  private func showCommandBar(_ completion: @escaping () -> Void) {
    guard !commandBarVisible else { return completion() }
    commandBarVisible = true
    let (shown, hidden) = barFrames()
    commandBar.frame = hidden
    commandBar.alphaValue = 0
    if commandBar.superview == nil {
      contentView.addSubview(commandBar)  // added last => topmost sibling
    }
    recorder?.mark("bar.showStart")
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = animDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      ctx.allowsImplicitAnimation = true
      commandBar.animator().frame = shown
      commandBar.animator().alphaValue = 1
    }, completionHandler: {
      self.recorder?.mark("bar.showEnd")
      completion()
    })
    // Grab keyboard focus for the overlay field (probe 3).
    window.makeFirstResponder(commandField)
  }

  private func hideCommandBar(_ completion: @escaping () -> Void) {
    guard commandBarVisible else { return completion() }
    commandBarVisible = false
    let (shown, _) = barFrames()
    let up = shown.offsetBy(dx: 0, dy: 60)
    recorder?.mark("bar.hideStart")
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = animDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
      ctx.allowsImplicitAnimation = true
      commandBar.animator().frame = up
      commandBar.animator().alphaValue = 0
    }, completionHandler: {
      self.recorder?.mark("bar.hideEnd")
      completion()
    })
    // Hand keyboard focus back to the browser (probe 3: does it return
    // cleanly?). CefBrowserHostView is the container's first subview.
    if let cefView = browserContainer.subviews.first {
      window.makeFirstResponder(cefView)
    }
    CefBridge.shared.focusBrowser()
  }

  // MARK: - Traced animation loop

  @objc public func runTracedLoop() {
    guard !loopActive, recorder == nil else {
      NSLog("BezierSpike: loop/trace already active, ignoring")
      return
    }
    guard let dir = traceDir else {
      NSLog("BezierSpike: no --trace-dir, ignoring loop request")
      return
    }
    let label = readScenarioLabel()
    let cycles = 8
    loopActive = true
    let rec = FrameTraceRecorder(outURL: dir.appendingPathComponent("\(label).json"))
    rec.meta = metadata(scenario: label, cycles: cycles)
    rec.start(view: contentView)
    recorder = rec
    NSLog("BezierSpike: traced loop start, scenario=\(label)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      self.animCycle(0, of: cycles)
    }
  }

  private func animCycle(_ i: Int, of n: Int) {
    guard i < n else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        self.recorder?.stopAndWrite()
        self.recorder = nil
        self.loopActive = false
        NSLog("BezierSpike: traced loop done")
      }
      return
    }
    recorder?.mark("cycle.\(i)")
    showCommandBar {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        self.hideCommandBar {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.animCycle(i + 1, of: n)
          }
        }
      }
    }
  }

  // Standalone trace (baseline / scroll-only): toggle start/stop.
  @objc public func toggleStandaloneTrace() {
    if let rec = recorder {
      guard !loopActive else { return }
      rec.stopAndWrite()
      recorder = nil
      return
    }
    guard let dir = traceDir else { return }
    let label = readScenarioLabel()
    let rec = FrameTraceRecorder(outURL: dir.appendingPathComponent("\(label).json"))
    rec.meta = metadata(scenario: label, cycles: 0)
    rec.start(view: contentView)
    recorder = rec
    NSLog("BezierSpike: standalone trace start, scenario=\(label)")
  }

  // MARK: - Scripted continuous resize
  // Real live-drag automation isn't available in this environment (synthetic
  // AX drags never reach the window server's resize loop). This steps the
  // window frame every ~8 ms — driving the same autoresize/relayout/composite
  // path per step — but does NOT enter NSEventTrackingRunLoopMode the way a
  // real user drag does.

  private var resizeTimer: Timer?

  @objc public func runScriptedResize() {
    guard resizeTimer == nil else { return }
    let original = window.frame
    let shrunk = NSRect(
      x: original.origin.x + 180, y: original.origin.y + 130,
      width: original.width - 360, height: original.height - 260)
    let phaseSteps = 150  // ~1.2 s shrink + ~1.2 s grow at 8 ms/step
    var step = 0
    recorder?.mark("resize.start")
    NSLog("BezierSpike: scripted resize start")
    let timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] t in
      guard let self else {
        t.invalidate()
        return
      }
      step += 1
      if step == phaseSteps { self.recorder?.mark("resize.turn") }
      let phase =
        step <= phaseSteps
        ? Double(step) / Double(phaseSteps)
        : Double(2 * phaseSteps - step) / Double(phaseSteps)
      let f = NSRect(
        x: original.origin.x + (shrunk.origin.x - original.origin.x) * phase,
        y: original.origin.y + (shrunk.origin.y - original.origin.y) * phase,
        width: original.width + (shrunk.width - original.width) * phase,
        height: original.height + (shrunk.height - original.height) * phase)
      self.window.setFrame(f, display: true)
      if step >= 2 * phaseSteps {
        t.invalidate()
        self.resizeTimer = nil
        self.recorder?.mark("resize.end")
        NSLog("BezierSpike: scripted resize done")
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    resizeTimer = timer
  }

  // MARK: - Probe 3 readback

  @objc public func dumpState() {
    guard let dir = traceDir else { return }
    let fr = window.firstResponder
    let dict: [String: Any] = [
      "t": CACurrentMediaTime(),
      "commandBarVisible": commandBarVisible,
      "commandFieldText": commandField.stringValue,
      "firstResponderClass": fr.map { String(describing: type(of: $0)) } ?? "nil",
      "firstResponderDesc": fr.map { String(describing: $0) } ?? "nil",
      "fieldIsEditing": commandField.currentEditor() != nil,
      "staticOverlayVisible": staticVisible,
      "currentURL": currentURL,
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: dict, options: [.sortedKeys, .prettyPrinted]) {
      try? data.write(to: dir.appendingPathComponent("state.json"))
      NSLog("BezierSpike: state dumped")
    }
  }

  // MARK: - Plumbing

  private func readScenarioLabel() -> String {
    guard let dir = traceDir,
      let s = try? String(contentsOf: dir.appendingPathComponent("next-label.txt"), encoding: .utf8),
      !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return "trace-\(Int(CACurrentMediaTime()))"
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func metadata(scenario: String, cycles: Int) -> [String: Any] {
    var model = [CChar](repeating: 0, count: 64)
    var size = model.count
    sysctlbyname("hw.model", &model, &size, nil, 0)
    let screen = window.screen
    return [
      "scenario": scenario,
      "date": ISO8601DateFormatter().string(from: Date()),
      "machine": String(cString: model),
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "screenName": screen?.localizedName ?? "unknown",
      "screenMaxFPS": screen?.maximumFramesPerSecond ?? 0,
      "backingScale": window.backingScaleFactor,
      "windowFrame": NSStringFromRect(window.frame),
      "currentURL": currentURL,
      "cycles": cycles,
      "animDuration": animDuration,
      "staticOverlayVisible": staticVisible,
    ]
  }

  private func registerDarwinNotifications() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let observer = Unmanaged.passUnretained(self).toOpaque()
    let callback: CFNotificationCallback = { _, observer, name, _, _ in
      guard let observer, let name else { return }
      let ctrl = Unmanaged<OverlayController>.fromOpaque(observer).takeUnretainedValue()
      DispatchQueue.main.async {
        ctrl.handleDarwinNotification(name.rawValue as String)
      }
    }
    for name in [
      "com.bezier.spike.static", "com.bezier.spike.bar", "com.bezier.spike.loop",
      "com.bezier.spike.trace", "com.bezier.spike.dump", "com.bezier.spike.resize",
      "com.bezier.spike.activate",
    ] {
      CFNotificationCenterAddObserver(
        center, observer, callback, name as CFString, nil, .deliverImmediately)
    }
  }

  private func handleDarwinNotification(_ name: String) {
    NSLog("BezierSpike: darwin notification \(name)")
    switch name {
    case "com.bezier.spike.static": toggleStaticOverlay()
    case "com.bezier.spike.bar": toggleCommandBar()
    case "com.bezier.spike.loop": runTracedLoop()
    case "com.bezier.spike.trace": toggleStandaloneTrace()
    case "com.bezier.spike.dump": dumpState()
    case "com.bezier.spike.resize": runScriptedResize()
    case "com.bezier.spike.activate":
      // Bring the app frontmost so synthetic keyboard events can be delivered
      // (focus-probe automation; headless drivers can't activate us from
      // outside).
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    default: break
    }
  }
}
