# CEF on macOS for Bézier: extensions, rendering, event loop, practicalities

Research date: **2026-07-19**. Verified against CEF **master (CEF 151, Chromium 151.0.7922.0, tagged 2026-07-10)**, the current binary channels (**stable = CEF 150**, **beta = CEF 151**, **LTS = CEF 144**), and primary sources (CEF repo/docs, issue tracker, cef-announce, CEF forum posts by maintainer Marshall Greenblatt "magreenblatt", Chromium source at the 150/151 tags). Every load-bearing claim carries a version/date. Note: the CEF wiki moved off Bitbucket in **January 2026**; current docs live at `chromiumembedded.github.io/cef` / the `docs/` dir of the GitHub repo — several sections of those docs are themselves stale (flagged below where it matters).

## TL;DR / what this means for Bézier

- **The engine model is settled**: since **CEF 128 (Aug 2024)** there is only one bootstrap (Chrome). You choose a *style* per browser/window: **Chrome style** (full Chrome UI layer: extensions, toolbars) or **Alloy style** (content layer: lean, supports OSR and native `parent_view` embedding). [#3685], [architecture.md]
- **The adblock bet needs care, but is viable**: uBlock Origin **classic (MV2) is dead** on current Chromium/CEF (hard-disabled in Chrome 138, July 2025; the last compile-time escape hatch is deleted in Chromium 151 = current CEF beta). The realistic path is **uBlock Origin Lite (MV3)** loaded via `--load-extension` (still supported in non-branded Chromium builds, i.e. CEF) — but full extension support (popups, tabs API, chrome://extensions) **only works in Chrome-style browsers**, and **on macOS any browser embedded in your own NSView is forced to Alloy style**. Network-level blocking (declarativeNetRequest) operates at the profile/RequestContext level and per the maintainer "should already work with Alloy style browsers" — but content-script cosmetic filtering in Alloy-style browsers is **unverified**. This is the single biggest thing to prototype first.
- **Rendering**: windowed (native NSView child) is the sane default — Chromium composites itself at display refresh (ProMotion-capable), and a shipped 2026 app (Atrium) proves AppKit-over-CEF overlay compositing works in production. OSR now has a real GPU path on macOS (IOSurface via `OnAcceleratedPaint`, since mid-2024) with no frame-rate cap in code, but it is Alloy-only, has open macOS bugs, disables smooth scrolling, and the sample code is deprecated NSOpenGLView.
- **Event loop**: use `external_message_pump=true` + `OnScheduleMessagePumpWork` → `CefDoMessageLoopWork()` on the main thread; `multi_threaded_message_loop` is **Windows/Linux only**. cefclient's mac pump (NSTimer in `NSRunLoopCommonModes` + `NSEventTrackingRunLoopMode`) is the reference; its 30 fps max-delay constant must be lowered for 120 Hz feel.
- **Ops reality**: ~monthly CEF majors tracking Chromium; separate x64/arm64 distributions (no universal — you lipo yourself); 5 helper apps to sign (JIT entitlements on Renderer/GPU helpers); **new API-versioning system (2025) substantially improves the historical "recompile every release" pain**. Swift bindings do not meaningfully exist — plan an Obj-C++ wrapper layer.

---

## (a) Extensions

### Timeline of the Alloy removal (verified)

| Event | Version / date | Source |
|---|---|---|
| Chrome runtime introduced (opt-in `--enable-chrome-runtime`) | 2020 | [architecture.md] |
| Alloy *runtime* split into **bootstrap** + **style**; Chrome bootstrap + Alloy style browsers possible; Alloy bootstrap deprecated | **CEF 125**, announced 2024-05-03 | [cef-announce M125], [#3681] |
| Alloy **bootstrap deleted**; `CefSettings.chrome_runtime` field removed (present in branch 6533/M127 headers, gone in 6613/M128); **Alloy extension API removed**, incl. `CefRequestContext::LoadExtension` (4 mentions in M127 header, 0 in M128) | **CEF 128** (mid-2024) | [#3685], [cef_request_context.h @6533 vs @6613], [architecture.md] |
| `cef_runtime_style_t` (`CHROME`/`ALLOY`/`DEFAULT`) is the per-browser/per-window switch | CEF 125+ … current (151) | [cef_types_runtime.h] |

So: **there is no "Chrome runtime vs Alloy runtime" choice anymore** — Chrome bootstrap always, style per browser. `CefRequestContext::LoadExtension`, `CefExtension`, `CefExtensionHandler` are gone since CEF 128; issue #3685 states plainly: *"The Alloy extension API is not supported (has been removed in M128)."*

### What extension support the Chrome bootstrap gives you today (CEF 150/151, mid-2026)

CEF now rides Chrome's own extension system. Loading paths:

1. **`--load-extension=/path/to/unpacked`** command-line flag at startup. Still present in Chromium 150's `extension_service.cc` behind `#if !BUILDFLAG(GOOGLE_CHROME_BRANDING) || BUILDFLAG(IS_CHROMEOS)` — the March 2025 Chrome RFC removing it applied **only to Google-branded Chrome** ("we're only making this change for branded Chrome builds"); CEF builds Chromium unbranded, so the flag works. [chromium extension_service.cc @150], [RFC load-extension]
2. **`chrome://extensions` + developer mode / "Load unpacked"** — works, but **only in a Chrome-style browser**: *"Navigation to chrome://extensions/ is blocked in Alloy-style browser"*; maintainer: *"You can create a windowed Chrome style browser if you wish to load chrome://extensions."* (2024-12-18) [#3859]
3. **Programmatic**: none. There is **no runtime load API** in the Chrome bootstrap; the old API is deleted. A pref-based workaround (writing `extensions.settings`) requires an app restart; the request for a proper API is **open** as of 2026 (#3877, filed 2025-01-30, magreenblatt suggested only "listening for the pref change inside CEF" as a possible future direction). [#3877]

### Chrome-style vs Alloy-style scope (maintainer statements)

- *"Extensions are only supported with Chrome style windows that show some portion of the Chrome UI (like the Chrome toolbar)."* — magreenblatt, 2024-10-15 [forum t=20003]
- *"Extensions that don't require Chrome UI dependencies (toolbar windows, icons, etc) may work with Alloy style windows and OSR, but that would be up to you to test and support on a case-by-case basis."* — magreenblatt, 2024-10-16 [forum t=20003]
- *"Extension functionality that works at the RequestContext level (like network intercepts, etc) should already work with Alloy style browsers. Extension functionality that requires Chrome UI (like toolbars, etc) will not be supported with Alloy style browsers."* — magreenblatt, 2024-12-18 [#3859]
- *"Alloy style only supports Browser/Tab extension APIs to the extent necessary to load the PDF viewer. There are no plans for general-purpose Tab API support with Alloy style."* — magreenblatt, 2025-10-06 [#4011]

Interpretation for an adblocker: **request blocking (declarativeNetRequest / network interception) is profile-level and applies to Alloy-style browsers**; anything needing tab identity (tabs/scripting API — used by uBO Lite's popup, per-site switches, element picker) or extension UI (action buttons, popups) needs **Chrome-style browsers**. CEF's own code confirms extension tab lookup for Alloy-style browsers exists only narrowly (`GetAlloyTabById` in `libcef/browser/chrome/extensions/chrome_extension_util.cc`, added 2024, used for the PDF viewer case).

### Can Bézier run uBlock Origin?

**uBlock Origin classic (MV2): effectively no.**

- Chrome MV2 deprecation (official timeline page): disabled-by-default for all users **March 31, 2025**; **Chrome 138 (July 24, 2025)**: *"All users … have now Manifest V2 extensions disabled. Users can no longer turn them back on"*; the `ExtensionManifestV2Availability` enterprise policy *"will be removed with Chrome 139"*; Chrome Web Store purges remaining MV2 listings **Aug 31, 2026**. [mv2-timeline]
- Verified in Chromium source: at tag **150.0.7871.115** (current CEF stable) `extensions/common/extension_features.cc` still contains `kExtensionManifestV2Unsupported` (**enabled by default**) and a **disabled-by-default** `kAllowLegacyMV2Extensions` escape hatch; at tag **151.0.7922.0** (current CEF beta) **all MV2 feature flags are deleted from that file**, and `chrome/browser/extensions/manifest_v2_experiment_manager.h` is gone from Chromium main. So on CEF 150 an embedder *might* still resurrect MV2 via `--enable-features=AllowLegacyMV2Extensions` (untested, unsupported); from CEF 151 the code path is being physically removed. Keeping MV2 alive long-term means maintaining Chromium patches (what forks like Supermium do) — not a sane bet.

**uBlock Origin Lite (MV3): the realistic path.**

- MV3/DNR is fully supported by the Chrome layer CEF now embeds. Expect: loading via `--load-extension` at startup ✓; ruleset-based blocking across the profile ✓ (RequestContext-level, per magreenblatt should also cover Alloy-style browsers); popup/per-site controls/element zapper — **Chrome-style browsers only**, and the popup/action UI lives in the Chrome toolbar, which CEF only shows on Chrome-style windows (Views framework on macOS — see below).
- **Not verified anywhere**: whether uBO Lite's *content scripts* (cosmetic filtering) inject into **Alloy-style** browsers. No primary source addresses this; magreenblatt's "case-by-case" phrasing implies it's untested upstream too.

### macOS-specific caveat (this one shapes the whole architecture)

From `cef_types_mac.h` (master, CEF 151): *"Alloy style will always be used if `windowless_rendering_enabled` is true **or if `parent_view` is provided**."* The Windows equivalent forces Alloy only for windowless. **On macOS, embedding a browser into your own NSView means Alloy style, hence no extension UI and no chrome:// pages in that browser.** Chrome-style browsers on macOS exist only as CEF-created windows (Views framework via `CefWindow`/`CefBrowserView`, or a CEF-created default NSWindow). A Jan 2024 forum thread asked exactly for "embed in my NSView but keep extensions"; magreenblatt's options were: use the Views framework, use one whole-window browser with the `<webview>` tag for content, or fork the Chrome layer like Edge/Opera. [forum t=19688]

### Confidence and gaps (a)

- Timeline/API removals: **high confidence** (verified in headers across branches + official issue/announcement).
- "DNR blocking applies to Alloy-style browsers": **medium** — direct maintainer statement, but no end-to-end test report found for uBO Lite specifically.
- Content scripts in Alloy-style browsers: **unknown — must prototype**. This is the pivotal unknown for "adblock in an NSView-embedded browser".
- Extension popup anchoring in Chrome-style Views windows on macOS: forum answers imply it works where the Chrome toolbar is shown; no explicit macOS confirmation found.

---

## (b) Rendering: windowed vs OSR on macOS

### Windowed (native view) rendering

- Mechanics (master, CEF 151): `CefWindowInfo.SetAsChild(NSView*, bounds)` → CEF creates a wrapper `CefBrowserHostView : NSView` and adds it as a subview of your `parent_view`; destruction of the view tears down the browser (`libcef/browser/native/browser_platform_delegate_native_mac.mm`). The web content inside is composited by Chromium's GPU process into CALayers exactly as in Chrome — you never see pixels.
- **Style**: native-parented = **Alloy style on macOS, always** (see (a)). Chrome-style windowed requires CEF's Views framework (`CefWindow`, `CefBrowserView`; cefclient's `views_window_mac.mm` demonstrates it), which owns the NSWindow.
- **Refresh rate**: windowed content is vsync-paced by Chromium; Chromium supports ProMotion/120 Hz on macOS (umbrella crbug 40202100 "New Mac: Support for ProMotion display"; adaptive-rate bugs were worked through in 2022–2023 — Chrome on a ProMotion MBP renders at 120 Hz today). Your AppKit sidebar animates in its own layers; there is no shared frame budget problem beyond normal process scheduling.
- **Layering native UI over web content**: macOS is the *good* platform for this (no Windows-style HWND airspace problem). AppKit sibling views/layers can overlap the browser view. Proof it ships: **Atrium** (Tauri-based agent workspace, blog post 2026-05-22) embeds CEF windowed in an NSView behind a transparent main webview ("punchout"), with native/DOM UI above it; their pain points were **hit-testing** (zPosition doesn't affect event routing — they run an NSEvent local monitor plus a hit-region registry and override `hitTest:` on the CEF wrapper) and layer-backing interactions. [atrium]
- Views-framework alternative for overlays: `CefWindow::AddOverlayView` (documented in `include/views/cef_window.h`) — but overlays are Views widgets, not AppKit views; mixing arbitrary AppKit into a Views CefWindow is unsupported territory.
- Other limits of windowed mode: no per-pixel control of web content (can't shader/warp it), window-drag regions and rounded-corner tricks must be done with AppKit around the browser view.

### Off-screen rendering (OSR)

- **Style**: *"Windowless rendering will always use Alloy style"* (`cef_types_runtime.h`, master) → all extension-UI limitations from (a) apply to every OSR browser. OSR under the Chrome bootstrap became possible with the M125 split (issue #3293 "chrome: Add support for off-screen rendering", closed **2024-04-16**); before that OSR required the (now-deleted) Alloy bootstrap.
- **Software path**: `CefRenderHandler::OnPaint` delivers a BGRA buffer + dirty rects; you upload to your own layer/texture. CPU copy cost scales with area — a 120 Hz full-window paint of a Retina 14″ (~3024×1964 px ≈ 24 MB/frame ≈ 2.8 GB/s) is the wrong tool.
- **Frame rate cap**: `CefBrowserSettings.windowless_frame_rate` — header comment (master): *"minimum value is 1 and the default value is 30"*; dynamic via `CefBrowserHost::SetWindowlessFrameRate`. The current clamp (`libcef/browser/osr/osr_util.cc`, master) enforces **only ≥1 — there is no 60 fps upper clamp in current code** (the old documented max of 60 is gone), and the value drives the compositor's vsync interval. So 120 is settable; whether the capture pipeline sustains 120 on your content is workload-dependent and unbenchmarked in any primary source I found.
- **Accelerated path (`OnAcceleratedPaint`)**: GPU shared-texture OSR was broken/removed in the viz era (2019, issues #1006/#2575) and **re-implemented by commit `77c1e82` "osr: Implement shared texture support (fixes #1006, fixes #2575)" (authored 2024-03-08 by "reito"/reitowo, landed for the M124/M125 releases, mid-2024)**. On macOS it delivers an **IOSurface** per frame: `CefAcceleratedPaintInfo.shared_texture_io_surface` (`cef_types_mac.h`), *"an IOSurface pointer that can be opened with Metal or OpenGL"* (`cef_render_handler.h`, master). Frames come from a pool: reopen the handle each callback, copy out, don't cache.
  - **Stale doc warning**: the `shared_texture_enabled` field comment still says *"Currently only supported on Windows (D3D11)"* — contradicted by the implementation (`video_consumer_osr.cc` maps `gmb_handle.io_surface()` on macOS) and by the render-handler docs. Trust the implementation; the settings comment simply wasn't updated.
- **Known OSR problems (current)**:
  - **Open bug (macOS)**: `OnPaint`/`OnAcceleratedPaint` never fire when `--external-begin-frame-enabled` is combined with OSR on macOS (issue #4033, filed 2025-11-18 against CEF 142, still open; bisected to the shared-texture commit). cefclient never implemented `SendExternalBeginFrame` on mac. So externally-driven frame pacing (the natural way to sync to a CVDisplayLink at 120 Hz) is currently broken on macOS.
  - **Smooth scrolling is disabled in OSR**, including with shared textures (issue #3842, closed **not_planned** 2024-12-03).
  - DevTools popups don't load in combination with windowless rendering (known issue in the M125 announcement, 2024-05-03).
  - cefclient's macOS OSR viewer is **deprecated `NSOpenGLView`** (`browser_window_osr_mac.mm` wraps it in deprecation-warning pragmas); no Metal sample exists, and the shared-texture author's own assessment of the mac sample: *"rendering IOSurface on that OpenGL thing very slow"* (issue #4033 comment, 2025-11-19). A production Metal/CAMetalLayer consumer is on you.
  - You re-implement input forwarding, IME (`text_input_client_osr_mac.mm` is the reference), drag-and-drop, accessibility, context menus, tooltips.
- The current `general_usage.md` OSR section still says OSR *"does not currently support accelerated compositing"* — **stale** (predates the 2024 rework); ignore it.

### What comparable apps ship

- **Spotify desktop**: CEF since 2011 — *"the great Chromium Embedded Framework that is used by the Spotify Desktop client"* (spotify.com/opensource, listing exact CEF versions per release). Spotify also funds/hosts the official CEF binary CDN. Its UI is web content in CEF windows (windowed, not OSR — inference from app behavior; Spotify doesn't document the mode).
- **Atrium** (2026): CEF **windowed** in an NSView with native/DOM overlay compositing on macOS (see above) — the closest published analogue to Bézier's architecture.
- Accelerated-OSR users are mostly game/overlay/VTuber apps on **Windows** (D3D11); I found no shipped macOS app publicly known to use accelerated OSR.
- Arc itself was a Chromium *fork* (Views/Swift hybrid), not CEF — not an existence proof for the CEF path.

### Recommendation-shaped summary

For an Arc-style shell: **windowed embedding (Alloy style) for the web content, AppKit around/over it** matches what ships today and gets Chromium-native 120 Hz compositing for free; accept the extension constraints from (a) and prototype the uBO-Lite-in-Alloy question immediately. Keep OSR as a fallback for exotic compositing only; on macOS it is currently the higher-risk path (open bugs, Alloy-only, DIY Metal pipeline, input/IME/a11y re-implementation).

### Confidence and gaps (b)

- Style rules, API shapes, clamp code, issue statuses: **high** (read from master source + tracker).
- ProMotion at 120 Hz through CEF windowed specifically: **medium** — Chromium-level support is established (crbug 40202100), but I found no CEF-specific 120 Hz measurement; Bézier should measure `CADisplayLink`-observed frame pacing over a CEF windowed view early.
- OSR 120 fps sustained throughput on Apple Silicon: **no data** anywhere; would need benchmarking.
- Spotify's exact rendering mode: **inference**, not documented.

---

## (c) Event loop integration on macOS

### The three official options (general_usage.md "Message Loop Integration" + `cef_app.h`, master)

1. **`CefRunMessageLoop()`** — CEF runs the loop; on macOS this spins `NSApplication` (cefsimple's comment chain: `CefQuitMessageLoop` "ends the NSApplication event loop"). Official docs: *"Use this function … to get the best balance between performance and CPU usage"*. Fine until your app needs to own startup/lifecycle — for a real AppKit app you usually outgrow it.
2. **`CefDoMessageLoopWork()` on your own cadence** — *"Use of this function is not recommended for most users … care must be taken to balance performance against excessive CPU usage. It is recommended to enable the `cef_settings_t.external_message_pump` option when using this function so that `OnScheduleMessagePumpWork()` callbacks can facilitate the scheduling process."* (`cef_app.h`, master). Naive fixed-interval timers either starve CEF or burn CPU (general_usage.md says exactly this).
3. **`multi_threaded_message_loop`** — **not available on macOS**: *"This option is only supported on Windows and Linux."* (`cef_types.h` master, line ~249; general_usage.md: "(Windows and Linux only)"). On macOS the CEF UI thread **is** your main thread, full stop.

⇒ For Bézier the correct configuration is **option 2 with `external_message_pump = true`**: AppKit owns `[NSApp run]`; CEF tells you when it wants work via `OnScheduleMessagePumpWork(delay_ms)`; you call `CefDoMessageLoopWork()` on the main thread accordingly.

### The reference implementation and its AppKit-specific lessons

`tests/shared/browser/main_message_loop_external_pump_mac.mm` (+ base class `main_message_loop_external_pump.cc`), master:

- `OnScheduleMessagePumpWork` **may be called on any thread** → it marshals to the owner (main) thread via `performSelector:onThread:`.
- Work is driven by a one-shot `NSTimer` that is added to **both `NSRunLoopCommonModes` and `NSEventTrackingRunLoopMode`** — this is the mitigation for AppKit modal-ish loops: menu tracking, popovers, and **live window resize** run the run loop in tracking mode, and a default-mode-only timer would freeze all browser output during them.
- The base pump clamps the maximum wait between `CefDoMessageLoopWork()` calls to `kMaxTimerDelay = 1000/30` (33 ms, "30fps") — a **cefclient sample choice, not a CEF limit**; for a 120 Hz-feeling app lower it (≈8 ms) or reschedule off a display link.
- Shutdown quirk: after `[NSApp run]` returns, the sample drains CEF by looping `CFRunLoopRunInMode` + `CefDoMessageLoopWork()` ~10 times, because there is no "pump until idle" API.
- App-side requirements from cefsimple/cefclient mac (`cefsimple_mac.mm`, master): your `NSApplication` subclass **must implement `CefAppProtocol`** (`isHandlingSendEvent` tracking, required by Chromium's event handling); `-terminate:` must be intercepted and rerouted so browsers close before teardown (`applicationShouldTerminate:` "is not supported" as the normal path).
- Truly modal AppKit loops (`runModalForWindow:`, native dialogs) still block the main thread → no `CefDoMessageLoopWork()` → web content freezes for their duration. That is inherent to single-threaded-UI CEF on macOS; design around sheets/inline UI, or accept the freeze. CEF added `CefSetNestableTasksAllowed` (API version 14100 → CEF 141, late 2025) for the narrower re-entrancy problem of OS APIs that enter native message loops on the CEF UI thread.

### Confidence and gaps (c)

- Everything above is read directly from master sources/docs: **high confidence**.
- No official guidance exists on driving `CefDoMessageLoopWork` from a `CADisplayLink` at 120 Hz; the `OnScheduleMessagePumpWork` contract (call `DoWork` after the requested delay, plus whenever you did work that may schedule more) permits it, but it is uncharted territory to validate by profiling.

---

## (d) Practicalities

### Binary distribution (cef-builds.spotifycdn.com, index fetched 2026-07-19)

- Platforms: `macosarm64` and `macosx64` (plus linux32/64/arm/arm64, windows32/64/arm64). **No universal macOS build** — you ship per-arch or lipo the framework yourself (community recipe: forum t=18098; wrinkle: `snapshot_blob.bin` is arch-specific with identical names — omit it or handle it out-of-band; `v8_context_snapshot.<arch>.bin` are already arch-suffixed).
- Current builds (2026-07-19): stable **`150.0.11+gb887805+chromium-150.0.7871.115`** (built 2026-07-10), beta **`151.2.1+g2b80a3b+chromium-151.0.7922.34`** (built 2026-07-17), LTS **`144.0.30+…chromium-144.0.7559.257`**.
- Per-version artifacts (macosarm64 sizes): **standard** ~265–298 MB (Debug **and** Release framework, `include/`, `libcef_dll/` wrapper source, cmake+bazel configs, `tests/` incl. cefclient/cefsimple/ceftests) — contents per `tools/distrib/mac/README.standard.txt`; **minimal** ~115–131 MB (Release only + headers + wrapper source); **client** (prebuilt cefclient.app); **tools**; **debug_symbols / release_symbols** shipped separately (~1.9–2.0 GB each).
- The framework is an **unversioned** `Chromium Embedded Framework.framework` containing all binaries + resources (.pak, icudtl.dat, V8 snapshots, locales) — layout per general_usage.md "MacOS".

### Release cadence, versioning, maintenance (branches_and_building.md, master, read 2026-07-19)

- A CEF branch per Chromium milestone; branch dates in the official table are ~monthly (145: Jan 2026 → 151: Jul 2026), tracking Chromium's ~4-week majors. *"Support for newer branches begins when they enter the Chromium beta channel. Support for older branches ends when they exit the Chromium stable channel."*
- **LTS is new**: *"Every sixth branch (starting with M138) proceeds through the … LTC/LTS channels after exiting stable"* with **~8 additional months of platform-agnostic security fixes** (issue #3947). Current LTS = 144 (refresh through Oct 2026). For Bézier this is the sanity option: hop LTS→LTS (~6-month cadence) instead of chasing monthly majors.
- Version scheme `X.Y.Z+gHHHHHHH+chromium-A.B.C.D`: X = CEF/Chromium major; **Y increments only when the C/C++ API changes within the branch**; Z on every commit; g-hash = CEF commit; trailing = exact Chromium version.
- **API stability changed materially in 2025** (api_versioning.md): historically *"any change in CEF major/minor version would require a recompilation of the client application"* (ABI unversioned — this is the classic "CEF API is not stable" fact, still true by default). Since 2025, defining **`CEF_API_VERSION=XXXYY`** pins a Stable API surface with **back/forward ABI compatibility across binaries supporting that version** (pre-2025 API is grandfathered as stable; experimental API is compiled out). Caveats: wrapper + app must be rebuilt if you change the pin, and *"API versioning does not … guarantee behavioral compatibility, particularly when moving between major Chromium versions."* A version bump therefore costs: download new binaries, rebuild `libcef_dll_wrapper` (if using C++ API), fix churn only when you move your API-version pin, re-test behavior.

### .app bundle structure (verified against cefsimple/cefclient CMake, master + branches 6533/6613/7151)

`CEF_HELPER_APP_SUFFIXES` is identical in M127, M128, M137 and master:

```
MyApp.app/Contents/
  Frameworks/
    Chromium Embedded Framework.framework/
    MyApp Helper.app
    MyApp Helper (Alerts).app
    MyApp Helper (GPU).app
    MyApp Helper (Plugin).app
    MyApp Helper (Renderer).app
  MacOS/MyApp
```

- **There is no "Helper (Alloy)" and none existed in any branch I checked (M127→master)** — the five helpers mirror Google Chrome's own naming; nothing changed in the bundle when the Alloy bootstrap was removed. Each helper has its own bundle ID suffix (`.helper.gpu` etc.), `LSUIElement=1` (no Dock icon), and all run the same tiny executable calling `CefExecuteProcess`.
- **Library loading**: executables must **not** link the framework; main app calls `CefScopedLibraryLoader.LoadInMain()`, helpers `LoadInHelper()` (wrapping C `cef_load_library()` / `cef_unload_library()`, `include/wrapper/cef_library_loader.h`) — *"Load the CEF framework library at runtime instead of linking directly as required by the macOS sandbox implementation"* (cefsimple_mac.mm). Helpers initialize the macOS V2 sandbox via `CefScopedSandboxContext` **before** loading the framework.
- **Code signing / entitlements**: every helper bundle + the framework must be signed individually. CEF ships no entitlement templates; the upstream reference is Chrome's own: `chrome/app/helper-renderer-entitlements.plist` and `helper-gpu-entitlements.plist` in Chromium main both grant **`com.apple.security.cs.allow-jit`** — with the hardened runtime (required for notarization) the Renderer (V8 JIT) and GPU helpers need that entitlement; sign inside-out (framework → helpers → app).

### Swift interop

- **CEF exposes a C API** (`include/capi/*`, generated; see using_the_capi.md — manual `cef_base_t` ref-counting, function-pointer structs) and a **C++ API** (virtual classes, multiple inheritance of `CefBaseRefCounted` interfaces, `CefRefPtr<T>` templates) whose wrapper (`libcef_dll_wrapper`) you compile yourself.
- **Swift/C++ interop (Swift 5.9+) cannot consume the C++ API usefully**: per swift.org's interop status docs, class templates aren't directly available (only pre-instantiated specializations), and Swift cannot subclass C++ classes — but implementing every CEF handler (`CefClient`, `CefLifeSpanHandler`, `CefRenderHandler`…) *is* subclassing C++ virtual classes. Dead end for direct use.
- Practical options, in order of sanity: **(1) Obj-C++ shim layer** — hand-written Objective-C facade over the C++ API, imported into Swift (what shipped apps do; Atrium's macOS layer is Obj-C++); **(2) C API directly from Swift** — feasible (C imports cleanly) but you hand-write ref-counting glue for every callback struct; the new API-versioning system (2025) at least stabilizes that surface across updates.
- Existing bindings are stale: **lvsti/CEF.swift** — last push **2021-11-01**, newest supported branch **4638 = Chromium 95** (Oct 2021), x86_64 only, README: *"incomplete, untested, and most likely unstable"*. ~55 Chromium majors behind; treat as reference reading, not a dependency. I found no other maintained Swift CEF binding (2026-07-19).

### Confidence and gaps (d)

- Index contents, versions, bundle layout, helper list, entitlements filenames: **high** (fetched/read directly).
- Universal-binary handling: community recipes only; no official CEF support — expect to own a small lipo/merge script and validate `snapshot_blob.bin` handling per version.
- API versioning is young (2025): the promise is documented, but long-term real-world track record across many majors is still thin.
- Obj-C++-shim effort estimate is engineering judgment, not sourced.

---

## Sources (all accessed 2026-07-19)

**Official CEF repo / docs (master = CEF 151, tagged 2026-07-10)**
- https://github.com/chromiumembedded/cef — source cloned; files cited: `include/internal/cef_types.h`, `cef_types_mac.h`, `cef_types_win.h`, `cef_types_runtime.h`, `cef_types_osr.h`, `include/cef_app.h`, `include/cef_render_handler.h`, `include/views/cef_window.h`, `include/wrapper/cef_library_loader.h`, `libcef/browser/osr/*` (osr_util.cc, video_consumer_osr.cc, render_widget_host_view_osr.cc), `libcef/browser/native/browser_platform_delegate_native_mac.mm`, `libcef/browser/chrome/extensions/chrome_extension_util.cc`, `cmake/cef_variables.cmake.in`, `tests/cefsimple/cefsimple_mac.mm`, `tests/cefsimple/process_helper_mac.cc`, `tests/cefsimple/mac/helper-Info.plist.in`, `tests/shared/browser/main_message_loop_external_pump{.cc,_mac.mm}`, `tests/cefclient/browser/browser_window_osr_mac.mm`, `tools/distrib/mac/README.{standard,minimal}.txt`
- [general_usage.md] https://github.com/chromiumembedded/cef/blob/master/docs/general_usage.md (mirrors https://chromiumembedded.github.io/cef/general_usage — note: OSR + bundle sections partly stale)
- [architecture.md] https://github.com/chromiumembedded/cef/blob/master/docs/architecture.md
- [branches_and_building.md] https://github.com/chromiumembedded/cef/blob/master/docs/branches_and_building.md
- [api_versioning.md] https://github.com/chromiumembedded/cef/blob/master/docs/api_versioning.md
- Branch header diffs: https://raw.githubusercontent.com/chromiumembedded/cef/{6478,6533,6613,7151,7871}/… (`cef_request_context.h`, `cef_types.h`, `cef_variables.cmake.in`, `cef_types_mac.h`)
- Bitbucket wiki (now a tombstone; "Moved to GitHub", commit 2026-01-29): https://bitbucket.org/chromiumembedded/cef/wiki/

**CEF issue tracker / PRs / announcements**
- [#3685] https://github.com/chromiumembedded/cef/issues/3685 — "alloy: Delete Alloy bootstrap (M128)" (opened 2024-04-22)
- [#3681] https://github.com/chromiumembedded/cef/issues/3681 — style/bootstrap split plan (2024-04-11, closed 2025-12-06)
- [#3293] https://github.com/chromiumembedded/cef/issues/3293 — "chrome: Add support for off-screen rendering" (closed 2024-04-16)
- [#3859] https://github.com/chromiumembedded/cef/issues/3859 — chrome://extensions blocked in Alloy style + magreenblatt comment (2024-12-18)
- [#4011] https://github.com/chromiumembedded/cef/issues/4011 — extension tab API vs OSR, magreenblatt comment (2025-10-06)
- [#3877] https://github.com/chromiumembedded/cef/issues/3877 — no runtime extension-load API (open, 2025-01-30)
- [#4033] https://github.com/chromiumembedded/cef/issues/4033 — mac OSR + external begin frame broken (open, 2025-11-18; incl. reitowo comments)
- [#3842] https://github.com/chromiumembedded/cef/issues/3842 — smooth scrolling w/ shared texture: not planned (2024-12-03)
- Shared-texture rework commit: https://github.com/chromiumembedded/cef/commit/77c1e82898a7f46164e0b997431318bcf9743592 (2024-03-08); Bitbucket PR 734 metadata via https://api.bitbucket.org/2.0/repositories/chromiumembedded/cef/pullrequests/734
- [cef-announce M125] https://groups.google.com/g/cef-announce/c/s1WaovAopFo — "Alloy style is supported in M125…" (2024-05-03)

**CEF forum (magpcss.org, maintainer posts)**
- [forum t=20003] https://www.magpcss.org/ceforum/viewtopic.php?f=6&t=20003 — "Queries on chrome extensions" (Oct 2024)
- [forum t=19688] https://www.magpcss.org/ceforum/viewtopic.php?f=6&t=19688 — "[macOS] support for embedded non-Views windows" (Jan 2024)
- [forum t=19401] https://magpcss.org/ceforum/viewtopic.php?f=10&t=19401 — "Future of onAcceleratedPaint?" (Mar 2023; historical, pre-rework)
- [forum t=18098] https://magpcss.org/ceforum/viewtopic.php?f=6&t=18098 — universal cef.framework / lipo recipe

**Binary distribution**
- https://cef-builds.spotifycdn.com/index.json — fetched 2026-07-19 (platform list, current stable/beta/LTS versions, artifact types/sizes/dates)

**Chromium**
- [mv2-timeline] https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline
- [RFC load-extension] https://groups.google.com/a/chromium.org/g/chromium-extensions/c/aEHdhDZ-V0E — branded-builds-only removal (Mar 2025)
- Chromium source @ tags 150.0.7871.115 / 151.0.7922.0 / main: `extensions/common/extension_features.cc`, `chrome/browser/extensions/extension_service.cc`, `chrome/app/helper-renderer-entitlements.plist`, `chrome/app/helper-gpu-entitlements.plist` (via raw.githubusercontent.com/chromium/chromium)
- ProMotion umbrella bug: https://issues.chromium.org/issues/40202100

**Third-party / ecosystem**
- [atrium] https://getatrium.dev/blog/embedding-real-browser-tauri — CEF windowed + AppKit overlay compositing on macOS (2026-05-22)
- Spotify uses CEF: https://www.spotify.com/us/opensource/
- CEF.swift status: https://github.com/lvsti/CEF.swift + https://api.github.com/repos/lvsti/CEF.swift (pushed_at 2021-11-01)
- Swift C++ interop limits: https://www.swift.org/documentation/cxx-interop/status/
