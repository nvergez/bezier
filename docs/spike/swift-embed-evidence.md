# CEF validation spike, part 2 — CEF in an app-owned NSView (Swift/AppKit app)

Spike for [Bézier #3](https://github.com/nvergez/bezier/issues/3). Run date: **2026-07-19**, macOS 26.5.2 (arm64).
Builds on part 1 (`cefclient-evidence.md`) and the research doc (`research/cef-macos` branch). Part 1 proved uBO Lite
works in *cefclient's* Alloy-style parented window; part 2 proves the same in **our own app**: a Swift AppKit window
whose content area is an app-owned `NSView` that a CEF browser is parented into — exactly Bézier's planned embedding.

## TL;DR

**Everything Bézier needs works inside a CEF browser embedded in an app-owned NSView.**

| Check | Result |
|---|---|
| Minimal AppKit app + correct 5-helper .app bundle builds against the CEF binary distro | ✅ (~950 LOC total incl. CMake; app target ~520 LOC) |
| Browser created with `CefWindowInfo.SetAsChild(parent_view)` + `CEF_RUNTIME_STYLE_ALLOY` | ✅ renders, resizes with the view, native URL bar drives it |
| Event loop: `external_message_pump` + `OnScheduleMessagePumpWork` → `CefDoMessageLoopWork()` | ✅ (8 ms idle ceiling; ~120 fps content, browser keeps painting during live resize) |
| uBO Lite loads (`--load-extension`, same unpacked build + profile as part 1) | ✅ MV3 service worker runs |
| **Network blocking (DNR) in the embedded view** | ✅ **4/4** on the synthetic page (`img/swift-embed-netblock-works.png`) |
| **Cosmetic filtering (content scripts) in the embedded view** | ✅ **3/3** generic-EasyList elements `display:none` (`img/swift-embed-cosmetic-works.png`) |
| adblock-tester.com | ✅ **100/100** (11 services, 22 checks) (`img/swift-embed-adblocktester-100.png`) |
| uBOL options page (`chrome-extension://…/dashboard.html`) | ✅ renders; part 1's "Complete" mode persisted via shared `--cache-path` (`img/swift-embed-ubol-dashboard.png`) |
| `chrome://extensions` | ❌ refused (`net::ERR_ABORTED`, URL unchanged) — expected; behavioral proof the embedded browser is Alloy style |
| Frame pacing | ~120 fps scroll on a ProMotion display; no visible stalls during live drag-resize; one ~300 ms hiccup on a discrete maximize |
| Clean shutdown (Cmd+Q / window close → CefShutdown → exit 0) | ✅ 5/6 attempts; 1 hang observed (see friction log) |

**The one finding that will bite production: macOS Keychain.** Chromium's Safe Storage init inside the network
service blocks *forever* when the Keychain ACL doesn't match the app's code signature — and every rebuild of an
ad-hoc-signed dev app changes that signature. Symptom: app runs, window paints, CDP responds, but **no navigation
ever commits** (document requests get no response). Cost half this spike in debugging; fixed with
`--use-mock-keychain` (what Chromium's own test harness uses). Production Bézier needs a stable signing identity,
and dev builds need this flag. Details in the friction log.

## Environment

Identical to part 1: CEF `150.0.11+gb887805+chromium-150.0.7871.115` (stable) `macosarm64` standard distro at
`~/cef-spike-cache/`, uBO Lite `2026.714.1952` unpacked at `~/cef-spike-cache/uBOLite_unpacked`, shared profile at
`~/cef-spike-cache/profile` (already in "Complete" filtering mode from part 1), cmake 4.4.0 + ninja 1.13.2,
Swift 6.x toolchain from Xcode CLT.

## The app (spike/BezierSpike/)

First launch (native Swift URL bar above, CEF content in the app-owned NSView below, address callback populating
the field): `img/swift-embed-first-launch.png`.

Architecture — Swift UI, thin pure-ObjC facade, ObjC++ internals:

- **`AppDelegate.swift`** — `NSWindow` with a native URL-bar strip (NSTextField + Go button) and a
  `browserContainer: NSView` filling the rest. Calls `CefBridge.shared.createBrowser(in:url:)`. This is the
  "app-owned NSView" under test.
- **`CefBridge.h/.mm`** — the *only* header Swift sees (bridging header; pure ObjC, no C++ leaks through).
  Exposes `createBrowserInView:url:`, `loadURL:`, `closeAllBrowsers:`, `isClosing`, and title/address callbacks
  (Swift closures). Implementation is ObjC++ holding `CefRefPtr<BezierClient>`.
- **`BezierClient`** — `CefClient` + `CefLifeSpanHandler` + `CefDisplayHandler` (cefsimple's SimpleHandler pattern:
  browser list, `DoClose` sets `is_closing`, `OnBeforeClose` of the last browser stops the app run loop).
- **`BezierCefApp`** — `CefApp` + `CefBrowserProcessHandler`: `OnContextInitialized` → signals the bridge (browser
  creation is queued until CEF is ready), `OnScheduleMessagePumpWork` → pump.
- **`BezierMessagePump`** — port of cefclient's `main_message_loop_external_pump_mac.mm` logic to a single ObjC++
  class: one-shot NSTimer registered in **both** `NSRunLoopCommonModes` and `NSEventTrackingRunLoopMode`,
  reentrancy detection around `CefDoMessageLoopWork()`, idle ceiling lowered from cefclient's 33 ms (30 fps) to
  **8 ms** per the research doc's 120 Hz recommendation.
- **`main.mm`** — `CefScopedLibraryLoader`, `BezierApplication : NSApplication <CefAppProtocol>` (incl. the
  `-terminate:` override rerouting quit through browser close-down), `CefInitialize` with
  `external_message_pump = true`, Swift AppDelegate instantiated via `NSClassFromString`, `[NSApp run]`, drain
  loop, `CefShutdown`.
- **`helper/process_helper_mac.cc`** — verbatim cefsimple helper (sandbox context + library loader +
  `CefExecuteProcess`).

Bundle: built with CMake as an external CEF project (`find_package(CEF)` + `add_subdirectory(libcef_dll_wrapper)`),
cribbing cefsimple's mac section: five helper apps (`BezierSpike Helper` + ` (Alerts)/(GPU)/(Plugin)/(Renderer)`),
framework copied into `Contents/Frameworks`, per-helper Info.plists, sandbox ON. Build: configure 4.4 s, full build
~2 min (231 targets, dominated by `libcef_dll_wrapper`), incremental seconds. `.app` weighs 311 MB (framework).
No signing step beyond the linker's automatic ad-hoc signature — sufficient to run locally, and the cause of the
keychain friction below.

### Event loop: what was chosen and why

`external_message_pump = true` with `OnScheduleMessagePumpWork` → NSTimer → `CefDoMessageLoopWork()` — the
configuration the research doc recommends (`multi_threaded_message_loop` is Windows/Linux-only; `CefRunMessageLoop`
surrenders lifecycle control AppKit apps want). It worked on the first try and was *not* the source of any
debugging pain (the navigation wedge initially blamed on it was the Keychain issue — verified by adding a
`--cef-loop` A/B switch that runs `CefRunMessageLoop` instead: it wedged identically until the keychain fix, and
both run correctly after). Measured behavior of the pump configuration:

- Content reaches **~120 fps** (see frame pacing) — the 8 ms idle ceiling never becomes the bottleneck because CEF
  schedules immediate work via `OnScheduleMessagePumpWork(0)` when busy.
- Idle cost: browser process ~2–3 % CPU sitting still (the 8 ms wake ceiling). cefclient's 33 ms would idle
  cheaper; a production app should make the ceiling adaptive (e.g. drop to 30 fps when unfocused/occluded).
- The tracking-mode timer registration works: web content kept animating during live window resize (measured, below).

## uBO Lite results in the embedded view

Launch (same test pages as part 1, served on `localhost:8899`):

```sh
./build/Release/BezierSpike.app/Contents/MacOS/BezierSpike \
  --use-mock-keychain \
  --load-extension=$HOME/cef-spike-cache/uBOLite_unpacked \
  --cache-path=$HOME/cef-spike-cache/profile \
  --remote-debugging-port=9223 \
  --url=http://localhost:8899/netblock-test.html
```

- uBOL's MV3 **service worker runs** (visible as a CDP target, same extension ID as part 1).
- **Network blocking: 4/4** — three real ad/tracker scripts blocked, benign control loaded. Verified via CDP read
  of the page's self-reported verdict AND screenshot `img/swift-embed-netblock-works.png` (native URL bar visible
  above the filtered page — this is our window, not cefclient).
- **Cosmetic filtering: 3/3** — `#AdBanner`, `#Ad-Container`, `.advertembed` all `display:none` by computed style;
  green control box visible. `img/swift-embed-cosmetic-works.png`. Content scripts inject and act in a browser
  embedded in *our* NSView. (Navigation to this page was done through the app's native URL bar — Swift →
  `CefBridge.loadURL` → `CefFrame::LoadURL` — exercising the native-UI → CEF path.)
- **adblock-tester.com: 100/100** (11 services, 22 checks) — `img/swift-embed-adblocktester-100.png`.
- **uBOL dashboard** (`chrome-extension://ddfleegngaplmlgjpejnlhkpdeoliodn/dashboard.html`) renders inside the
  embedded view with the **Complete** mode radio checked — the setting persisted from part 1 through the shared
  `--cache-path`. `img/swift-embed-ubol-dashboard.png`. (CDP target type for extension pages is `other`, not
  `page`.)
- **`chrome://extensions`** refused (`net::ERR_ABORTED`, URL stays put) — matches CEF #3859 and part 1; the
  parent-view embed is behaviorally Alloy style, as `cef_types_mac.h` promises.

## Frame pacing (scroll / resize)

Measured with an in-page `requestAnimationFrame` timestamp sampler over CDP on a long Wikipedia article, on a
120 Hz ProMotion display:

- **Scroll** (CDP-dispatched wheel events for 4 s, page scrolled ~7500 px): **482 frames / 4025 ms ≈ 120 fps**.
  Frame deltas: mean **8.37 ms**, median 8.3 ms, p95 9.9 ms, worst 24.6 ms (a single dropped frame in 4 s).
  Chromium composites the embedded view at full ProMotion rate — confirms the research doc's expectation for
  windowed embedding.
- **Live drag-resize** of the window corner while sampling: **no rAF gap > 50 ms** (worst 16.3 ms) — the
  tracking-mode timer keeps CEF pumping and content painting during the resize loop. Content viewport tracks the
  container continuously (CEF's browser view autoresizes with its parent; no manual resize plumbing was needed).
- **Discrete maximize** (zoom button, 1200×812 → 2560×1340 viewport): a single **~309 ms** rAF gap during the
  transition while the surface is rebuilt at the new size, then immediately back to 8.3 ms cadence.
  `img/swift-embed-resized-maximized.png` shows the relaid-out page.
- Subjective: scrolling and resize look smooth; the maximize hiccup is perceptible but comparable to heavyweight
  browser windows.

## Friction log (ordered by how much it matters)

1. **macOS Keychain wedges all navigation in dev builds (the big one).** First-ever launch of the app worked;
   after the next rebuild, *every* run wedged: window fine, pump fine, CDP `/json` fine, but no navigation ever
   commits — `Network.requestWillBeSent` then silence, renderer idle, page-level CDP attach times out.
   Reproduced with the external pump AND `CefRunMessageLoop`, with and without `--cache-path`, extension, fresh
   user-data-dir, clean rebuild — while cefclient worked throughout and a freshly built **cefsimple wedged the
   same way**. Diagnosis: Chromium's Safe Storage ("Chromium Safe Storage" Keychain item) is initialized by the
   network service; the Keychain ACL binds to the app's code signature, an ad-hoc-signed binary gets a **new
   identity every rebuild**, and in this context the authorization prompt never usefully appears — the keychain
   call blocks forever inside the network service. cefclient kept working because its first-run authorization
   still matched (it wasn't being rebuilt). **Fix: `--use-mock-keychain`** (Chromium's own test-harness flag) —
   instant, total. Production implication: Bézier must ship with a **stable signing identity** (real cert +
   entitlements) or cookies-at-rest encryption init must be handled deliberately; dev builds should always pass
   `--use-mock-keychain`.
2. **Browser teardown is tied to the CEF NSView's dealloc — ARC/Swift makes that non-obvious.** CEF only fires
   `OnBeforeClose` (→ our run-loop stop → `CefShutdown`) after its `CefBrowserHostView` is dealloc'ed. A Swift
   AppDelegate holding normal strong refs (window → contentView → container → CEF view) keeps the view alive
   after window close, so quit hangs with the window gone and processes alive. Fix: `windowWillClose` explicitly
   strips the CEF view from the container. With the fix, quit via Cmd+Q / AppleEvent / red button is clean
   (`exit 0`, all 6 processes gone in ~2 s) — **but one hang in six quit attempts was still observed** (window
   closed, `[NSApp run]` never exited; not reproduced in 4 subsequent attempts). SIGTERM-killing the app mid-run
   also produces a shutdown crash report (`_NSWindowTransformAnimation dealloc` touching torn-down CEF state).
   Production Bézier needs a deliberate close protocol (cefclient's RootWindow bookkeeping is the reference), not
   this spike's minimal version.
3. **Swift ↔ CEF interop was cheap overall** (matches the research doc's "Obj-C++ shim" recommendation):
   - Ninja/CMake cannot mix Swift and C-family sources in one target → separate `BezierUI` static lib +
     `-import-objc-header` for the bridging header + `-Wl,-force_load` (the class is only referenced via
     `NSClassFromString`) + `-L$SDK/usr/lib/swift` for the auto-linked runtime. All boilerplate, all documented
     in CMakeLists — but each was a small landmine.
   - The facade must stay C++-free (`CefBridge.h` forward-declares nothing CEF); all CEF types live behind `.mm`.
     Once that line was drawn, Swift code (window, URL bar, callbacks as closures) was frictionless.
   - Cosmetic: the Swift target ignores CEF's `CMAKE_OSX_DEPLOYMENT_TARGET=12.0` (set after `project()`), so ld
     warns "object file built for newer macOS version (26.0) than being linked (12.0)". Harmless here.
4. **`root_cache_path` red herring.** Setting `settings.root_cache_path = cache_path` (to silence CEF's warning)
   coincided with the keychain wedge and was initially blamed; reverted to cefclient-parity (only `cache_path`)
   before the real cause was found. Not re-tested after the keychain fix. CEF's "customize root_cache_path"
   warning remains unaddressed in this spike.
5. **`COPY_MAC_FRAMEWORK`'s symlink step is not idempotent**: on every rebuild after the first, its `ln -sf` into
   already-existing directory symlinks deposits junk self-referential links *inside* the framework
   (`Versions/A/A`, `Resources/Resources`, …). Harmless at runtime; would matter for signing/notarization.
6. **Tooling notes** (not CEF's fault): part 1's finding holds — synthetic AX clicks land on native AppKit
   controls (URL bar, Go button all drivable) but not on CEF web content; pages driven via CDP
   (Origin-suppressed WebSocket). `osascript` + System Events keystrokes hang on automation permission in this
   headless-ish context; AppleEvent `quit` and the `orca computer` CLI work.

## What this means for Bézier

- The exact architecture Bézier wants — **AppKit window, native chrome, CEF browser in an app-owned NSView, uBO
  Lite filtering both network and cosmetic** — is now demonstrated end-to-end in ~950 lines including build
  system. No blocker surfaced.
- The embedding itself (CreateBrowser/SetAsChild, autoresize, native URL bar → LoadURL, title/address callbacks)
  is the *easy* part. The real engineering lives at the edges: **signing/keychain**, **shutdown protocol**, and
  (from part 1) extension lifecycle limits (load-at-startup only, no popup UI in Alloy).
- Performance needs no exotic path: windowed embedding delivers ProMotion-rate compositing with a ~100-line
  message pump.

Not covered here (later spikes / prototype): proper code-signing + notarization with helper entitlements (the
keychain finding makes this *more* urgent), multiple browsers/views per window, AppKit overlays above the browser
view (Atrium-style hit-testing), OSR, `CefSetNestableTasksAllowed`/modal-loop behavior, adaptive pump throttling.
