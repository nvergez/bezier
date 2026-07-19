# CEF validation spike, part 3 — native AppKit overlays OVER the embedded CEF view

Spike for [Bézier #8](https://github.com/nvergez/bezier/issues/8). Run date: **2026-07-19**.
Builds on part 2 (`swift-embed-evidence.md`): same app (`spike/BezierSpike`), same CEF embed
(`SetAsChild` + `CEF_RUNTIME_STYLE_ALLOY`, external message pump). This part answers the question part 2
explicitly left open: **can Arc-style native UI (command bar, panels, vibrancy) be composited *on top of* the
windowed CEF browser view, in the same NSWindow — without falling back to off-screen rendering?**

Per the adversarial review of parts 1–2, every performance claim here is backed by a **committed
machine-readable trace** (`traces/*.json`, analyzed by `spike/tools/analyze_trace.py`, summary in
`traces/analysis-summary.json`), and every test records its exact conditions.

## TL;DR

**Yes. Windowed (non-OSR) CEF composites correctly under native AppKit overlay views.** No z-order, clipping,
vibrancy, animation-smoothness, or keyboard-focus blocker was found.

| Probe | Result |
|---|---|
| Static `NSVisualEffectView` panel + translucent plain view over the CEF view | ✅ correct z-order, alpha compositing, no clipping |
| **`.withinWindow` vibrancy samples the live CEF web content** (blur shows the page, updates as it scrolls and as video plays) | ✅ (surprise positive — see caveats) |
| Overlay position/appearance during page scroll (7 800 px CDP wheel scroll) | ✅ pixel-stable, backdrop live-updates |
| Overlay during continuous window resize (scripted, 300 steps ≈ 2.4 s) | ✅ stays centered & unclipped; frame drops during resize — see trace |
| Animated command bar (Core Animation slide+fade, 8× show/hide) over a static page | ✅ **99.7 %** of 120 Hz ticks on budget; 13 dropped-tick events, worst stall 21.4 ms |
| Same, while the page scrolls continuously (CDP wheel stream) | ✅ 5 dropped-tick events in 8.2 s, worst 20.6 ms |
| Same, over a playing VP9 video | ✅ 11 dropped-tick events, worst 21.8 ms; **video dropped 0 frames** (289 decoded @ 30 fps during the loop) |
| Keyboard focus: overlay text field takes focus from CEF, typing does **not** leak to the page, focus returns cleanly | ✅ verified with real CGEvent keystrokes + in-page keylogger |

The one caution for production: **continuous window resize** is the stress case (mean 12.2 ms, worst 38.8 ms
during the resize window) — consistent with part 2's maximize hiccup. Overlay animation itself is essentially
free: the only misses are 1–2 skipped refreshes at CoreAnimation *commit* points, never during the animation.

## Environment (exact)

- Machine: `Mac16,7` (MacBook Pro, Apple M4 Pro), macOS **26.5.2 (25F84)**, arm64.
- Display under test: built-in ProMotion panel — `NSScreen.localizedName` = "Built-in Retina Display"
  (system_profiler: Liquid Retina XDR, 3456×2234), **`maximumFramesPerSecond` = 120**, backing scale 2.
  Frame budget **8.333 ms**. Two external displays were attached (a 144 Hz "Q27G4ZR" and a 5K); the app moves
  its window to the built-in ProMotion screen via the new `--prefer-promotion` flag, and every trace's
  `meta.screenName`/`meta.screenMaxFPS` records where it actually ran. (First run accidentally landed on the
  144 Hz external — the flag originally picked "highest refresh"; it now prefers the built-in panel.)
- CEF `150.0.11+gb887805+chromium-150.0.7871.115` (stable, macosarm64 standard distro) at `~/cef-spike-cache/`.
- App: `spike/BezierSpike` extended with `src/OverlayController.swift` (+ small AppDelegate/CefBridge/CMake
  changes). Build: `cmake -G Ninja -B build -DCMAKE_BUILD_TYPE=Release . && ninja -C build`.
- uBO Lite was **not** loaded in these runs (orthogonal to the overlay question); dedicated fresh profile
  `~/cef-spike-cache/overlay-profile`.
- Test pages served locally: `cd docs/spike/testpages && python3 -m http.server 8899`. The video is generated,
  not committed:
  `ffmpeg -f lavfi -i "testsrc2=size=1280x720:rate=30" -t 30 -pix_fmt yuv420p -c:v libvpx-vp9 -b:v 2M docs/spike/testpages/video.webm`.

Launch command for all runs:

```sh
./build/Release/BezierSpike.app/Contents/MacOS/BezierSpike \
  --use-mock-keychain \
  --cache-path=$HOME/cef-spike-cache/overlay-profile \
  --remote-debugging-port=9223 \
  --autoplay-policy=no-user-gesture-required \
  --trace-dir=$HOME/cef-spike-cache/traces \
  --prefer-promotion \
  --url=http://localhost:8899/scroll-test.html   # (or focus-test.html for probe 3)
```

## How the overlays are built (what is under test)

`OverlayController` adds plain `NSView`/`NSVisualEffectView` subviews to the window's **contentView**, as
siblings *above* the `browserContainer` that hosts CEF's `CefBrowserHostView` — i.e. ordinary same-window
AppKit view stacking, no child windows, no OSR:

- **Static overlay (probe 1):** a 460×240 `NSVisualEffectView` (`material .hudWindow`,
  **`blendingMode .withinWindow`**, `state .active`, corner radius 14) centered over the browser area with
  flexible-margin autoresizing, plus a 130×130 plain layer-backed view at 45 % alpha `systemRed` overlapping
  the panel's corner (proves straight alpha compositing independent of vibrancy).
- **Command bar (probes 2–3):** a 620×60 `NSVisualEffectView` with an editable borderless `NSTextField`,
  slid down 60 pt + faded in/out via `NSAnimationContext` (`allowsImplicitAnimation`, 0.25 s ease-out/ease-in)
  — standard render-server-driven Core Animation, as production would use.
- **Automation:** the app listens for Darwin notifications (`notifyutil -p com.bezier.spike.{static,bar,loop,trace,resize,dump,activate}`),
  so tests don't depend on AX click targeting. `--trace-dir` receives frame traces and `state.json` dumps.

## Frame-pacing methodology

A `CADisplayLink` obtained from the content view (macOS 14+ API) runs in `.common` run-loop modes; every
callback appends `(timestamp, targetTimestamp)` to an in-memory array, written as JSON on stop. On this
display the link ticks every **8.333 ms**; an interval of ~16.7 ms means the main thread missed one refresh
slot, etc. `spike/tools/analyze_trace.py` reports interval stats and counts intervals > 1.5× budget as drops.

What this measures: the app main thread's ability to service every 120 Hz tick **while CEF's message pump,
input, layout and the overlay animation commits share that thread** — the compositor-pressure question for
Arc-style UI. What it does not measure: render-server-side hitching (the slide/fade itself is committed once
and animated out-of-process). That gap is covered visually (screenshots mid-animation) and by the video's own
decoder stats (`getVideoPlaybackQuality()`), which count dropped video frames independently of our process.

The event markers (`bar.showStart/showEnd/hideStart/hideEnd`, `resize.start/turn/end`) are recorded with
`CACurrentMediaTime()` in the same timebase as the display-link timestamps, so drops can be attributed.

## Probe 1 — static overlay: z-order, clipping, scroll, resize

- First display (page top, y=0): `img/overlay-static-y0.png` — vibrancy panel and translucent red square
  float over the CEF view; the panel's blur visibly samples the page's blue/brown section boundary; the
  square alpha-blends over web content. No clipping at the container edge, no z-order artifacts.
- After a **7 800 px trusted CDP wheel scroll** (`spike/tools/cdp_driver.py --port 9223 scroll --delta 120 …`;
  page HUD shows `y=7800`): `img/overlay-static-scrolled.png` — overlay pixel-identical in position; the
  vibrancy backdrop now blurs the *new* content beneath (sections 24–26). The backdrop is live, not a stale
  snapshot.
- **Continuous resize** (scripted: 150 shrink + 150 grow steps of `setFrame`, 8 ms apart, 1200×882 →
  840×622 → back, static overlay visible, page at y=4800): mid-resize screenshot
  `img/overlay-static-midresize.png` shows the overlay recentered by autoresizing, unclipped, backdrop
  correct, CEF content re-laid out — native overlay and browser view stay visually in sync at every
  intermediate size. Trace: `traces/resize-scripted-static-overlay.json` — within the resize window
  (246 intervals ≈ 3.0 s): mean **12.23 ms**, median 8.33 ms, p95 24.9 ms, **64 dropped-tick events
  (115 refreshes missed), worst 38.8 ms**. Continuous resize is the one scenario that visibly cannot hold
  120 Hz; it averaged ~82 Hz worth of ticks. (Caveats: the 8 ms stepping timer itself loads the main thread,
  and a scripted resize does not run in `NSEventTrackingRunLoopMode` the way a real drag does — see
  limitations. Direction matches part 2's discrete-maximize hiccup.)

## Probe 2 — animated command bar with frame traces

Each scenario: `notifyutil -p com.bezier.spike.loop` → 8 show/hide cycles (0.25 s slide+fade each way,
0.25 s shown dwell, 0.15 s hidden dwell), display-link trace running throughout. Committed traces, all on the
120 Hz built-in screen (`budget_ms: 8.333` in each file's meta):

| Trace | Conditions | Ticks | median / p95 / p99 / max (ms) | Dropped-tick events (refreshes missed) |
|---|---|---|---|---|
| `baseline-idle.json` | scroll-test page, no animation, no scroll, 6.1 s | 734 | 8.33 / 8.33 / 8.33 / **8.33** | **0 (0)** |
| `anim-static-page.json` | 8 anim cycles, page idle | 972 | 8.33 / 8.33 / 13.3 / 21.4 | 13 (14) |
| `anim-while-scrolling.json` | 8 anim cycles **while CDP streams wheel events** (500 events / 12.6 s, page scrolled 4 800→64 800) | 976 | 8.33 / 8.33 / 8.33 / 20.6 | 5 (5) |
| `anim-while-video.json` | 8 anim cycles **over playing 720p30 VP9** | 971 | 8.33 / 8.33 / 14.5 / 21.8 | 11 (12) |

Attribution (script over the committed traces): **every** animation-scenario drop is a 12.5–21.8 ms interval
at a CoreAnimation **commit point** — either ~14 ms after `bar.showStart` or ~150 ms after `bar.hideEnd`
(exactly the hidden-dwell end, i.e. the next cycle's show commit). Zero drops occur mid-animation: the render
server carries the slide/fade while the main thread keeps its 120 Hz cadence. Baseline is a flawless 8.333 ms
× 734 with zero variance.

Video corroboration: across the ~9.6 s loop window the `<video>` decoded 289 frames (447→736) — exactly
30 fps — with **droppedVideoFrames unchanged (1 → 1**, the single drop predating the loop at playback start).
Mid-animation screenshots: `img/overlay-commandbar-shown.png` (bar over scroll page),
`img/overlay-commandbar-while-scrolling.png` (bar mid-cycle, focused, page at y=37080 mid-scroll),
`img/overlay-commandbar-over-video.png` (bar's vibrancy blurring the video's color bars; burned-in timecode
00:00:19.133/frame 574 matches the in-page stats line).

## Probe 3 — first-responder / keyboard focus

Method: `focus-test.html` logs **every keydown reaching the renderer** (capture phase) plus input values and
window focus/blur, and exposes `window.probe()` for machine-readable readback. The page input was focused by
a trusted CDP click; keystrokes were **real window-server events** — CGEvents posted at the HID tap by
`spike/tools/type_cg.swift` (the app is frontmost; `orca computer type-text` refused on a focus-policy check,
and AX/osascript keystrokes hang on automation permission in this context — part 2 friction log). App-side
state read back via `notifyutil -p com.bezier.spike.dump` → `state.json`.

Sequence and results (all values from the committed transcript of `window.probe()` / `state.json`):

1. Page input focused, typed `page-before` → renderer saw 11 keydowns, `#in` value `page-before`,
   `document.hasFocus()` true. First responder: **`RenderWidgetHostViewCocoa`** (CEF's view — baseline).
2. Command bar shown (`makeFirstResponder(commandField)`): first responder becomes the field editor
   (`NSTextView`), `fieldIsEditing: true`. **CEF did not steal focus back**; the renderer logged
   `window blur` and `document.hasFocus()` went false — Chromium correctly observed focus leaving.
3. Typed `hello overlay` (13 real key pairs): overlay field text = `hello overlay`
   (`img/overlay-focus-typed.png`); page: **keydownCount still 11, input value unchanged** — zero leakage.
4. Command bar hidden (restore: `makeFirstResponder(cefView)` + `CefBrowserHost::SetFocus(true)`): first
   responder back to `RenderWidgetHostViewCocoa`; renderer logged `window focus`.
5. Typed `-after` (6 key pairs): all reached the page → value `page-before-after`, keydownCount 17. The
   page input regained its in-renderer focus without re-clicking.

Verdict: the Arc command-bar focus contract works with plain AppKit first-responder machinery + one
`SetFocus(true)` call on dismiss. No focus tug-of-war with CEF was observed in either direction.

## Incidental findings / friction log

1. **`.withinWindow` vibrancy over CEF works** — worth flagging as *fragile by nature*: it depends on
   Chromium's windowed compositing living in the same window layer tree that the vibrancy backdrop samples.
   Treat as a bonus, not a load-bearing design guarantee; re-verify on CEF upgrades (an OSR or child-window
   change would break it). A plain translucent view (also tested) is the safe fallback.
2. **CEF standard distro has no proprietary codecs**: the first video test (H.264 MP4) failed with
   `MediaError.code 4` / `NETWORK_NO_SOURCE`; VP9 WebM plays fine. Bézier needs a media-codec strategy
   (build-time `proprietary_codecs`, licensing, or accept open codecs only).
3. **Synthetic drag automation cannot drive window-manager operations**: `orca computer drag` reports ok but
   neither resizes nor moves the window (tried both on the built-in display at negative global coords and on
   the main display) — hence the scripted-resize fallback. Same tooling class as part 2's "AX clicks don't
   land on CEF content".
4. **App activation from a headless-ish shell is unreliable**: `osascript activate` / `open -a` eventually
   made the app frontmost, but `orca computer type-text` still refused (`window_not_focused`); an in-app
   `com.bezier.spike.activate` Darwin notification (`NSApp.activate(ignoringOtherApps:)`) plus HID-tap
   CGEvents was the reliable path for real keystrokes.
5. **CMake latent bug fixed**: the `-Wl,-force_load,$<TARGET_FILE:BezierUI>` link flag hid the Swift static
   library from ninja's dependency graph — editing Swift sources rebuilt the `.a` but never relinked the app
   (stale binary ran). Fixed with `LINK_DEPENDS` in `CMakeLists.txt`.
6. **`--prefer-promotion` originally picked the wrong screen** (144 Hz external beats the 120 Hz built-in on
   raw refresh); it now prefers the built-in panel via `CGDisplayIsBuiltin`. Traces record the actual screen
   either way.

## Limitations (what this spike does NOT establish)

- **Real mouse-drag live resize** (with `NSEventTrackingRunLoopMode`) was not automatable here; the resize
  numbers come from the scripted stepper described above. Part 2 observed real drag-resize keeps CEF painting;
  the combined real-drag + overlay case deserves a 2-minute manual check on the prototype.
- **Hit-testing / click-through** for overlays (Arc's peek dismiss-on-outside-click, hover pass-through) was
  not probed — keyboard focus only. This is the next overlay question if one is needed.
- Only one overlay visible at a time was animated; no test of many simultaneous animating surfaces, sidebar
  reveal (which resizes the browser container itself), or long-session GPU cost of `.active` vibrancy.
- Traces measure main-thread tick servicing (see methodology); render-server stalls would need
  CATransaction/QuartzDebug-level instrumentation if ever suspected.
- All runs ad-hoc signed with `--use-mock-keychain`, one 30 s synthetic VP9 clip, localhost pages; nothing
  here revisits part 2's signing/shutdown/extension-lifecycle risk register.

## What this means for Bézier (#8)

The engine-decision risk this spike was asked to retire — *"if overlays fail in windowed mode, the decision
tilts toward OSR"* — is retired: **windowed CEF + same-window AppKit overlays supports the Arc-style UI
pattern**, including vibrancy, 120 Hz animation over live/scrolling/video content, and command-bar keyboard
capture, with the only measured weakness (continuous-resize jank, worst 38.8 ms) being one OSR would not
obviously fix and part 2 already observed in milder form. No off-screen-rendering fallback is needed for
floating native UI.
