# CEF validation spike, part 1 — uBO Lite in cefclient (Chrome style vs Alloy style)

Spike for [Bézier #3](https://github.com/nvergez/bezier/issues/3). Run date: **2026-07-19**, on macOS 26.5.2 (arm64, Apple Silicon).
Builds on the research in `research/cef-macos` (`docs/research/cef-macos.md`), which left one pivotal unknown:

> Content scripts in Alloy-style browsers: **unknown — must prototype**. This is the pivotal unknown for "adblock in an NSView-embedded browser".

## TL;DR

**uBO Lite (MV3) works fully in Alloy-style browsers — including cosmetic filtering via content scripts.**

| Check | Chrome style (`--use-views`) | Alloy style (native window, `--use-alloy-style`) |
|---|---|---|
| Extension loads via `--load-extension` | ✅ works (visible in `chrome://extensions`) | ✅ works (service worker running, filtering active) |
| Network blocking (declarativeNetRequest) | ✅ 4/4 on synthetic test | ✅ 4/4 on synthetic test |
| **Cosmetic filtering (content scripts, generic EasyList selectors)** | ✅ 3/3 hidden (Complete mode) | ✅ **3/3 hidden (Complete mode)** |
| adblock-tester.com overall | not re-run (validated in Alloy) | ✅ **100/100** (11 services, 22 checks) |
| `chrome://extensions` page | ✅ renders | ❌ navigation silently refused (expected, [#3859]) |
| Extension options page (`chrome-extension://…/dashboard.html`) | ✅ renders, interactive | ✅ **renders, interactive** (settings persist) |
| Extension toolbar icon / popup UI | ✅ toolbar + Extensions menu present | ❌ not exercisable — no Chrome toolbar exists |

The one caveat that matters for product design: cosmetic filtering is **not on by default**. uBO Lite defaults
to per-site content-script injection only ("Optimal" mode; generic selectors need "Complete"), configured through
uBOL's own UI. Its options page works inside an Alloy browser (screenshot below), and settings persist in the
profile (`--cache-path`), so this is a solvable onboarding/config concern, not a blocker.

## Environment and versions

| Item | Value |
|---|---|
| CEF | `150.0.11+gb887805+chromium-150.0.7871.115` (current **stable** channel), `macosarm64`, **standard** distribution |
| Chromium | 150.0.7871.115 (confirmed at runtime via CDP `/json/version`) |
| uBO Lite | `2026.714.1952` (latest release, 2026-07-14), `uBOLite_2026.714.1952.chromium.zip` from uBlockOrigin/uBOL-home |
| macOS | 26.5.2 (Darwin 25.5.0), arm64 |
| Toolchain | Xcode CLT clang, cmake 4.4.0 (Homebrew), ninja 1.13.2 (Homebrew) |

Binaries live outside the repo in `~/cef-spike-cache/` (CEF tarball 285 MB, uBOL zip 9.9 MB — not committed).

## Build

```sh
# Download (URL-encode '+' as %2B)
curl -sL -o cef_binary_150.0.11_macosarm64.tar.bz2 \
  "https://cef-builds.spotifycdn.com/cef_binary_150.0.11%2Bgb887805%2Bchromium-150.0.7871.115_macosarm64.tar.bz2"
tar xjf cef_binary_150.0.11_macosarm64.tar.bz2

cd cef_binary_150.0.11+gb887805+chromium-150.0.7871.115_macosarm64
mkdir build && cd build
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release ..   # 3.0 s, one harmless Doxygen warning
ninja cefclient                                 # 21.3 s wall / 190 s CPU, 359 targets
```

Zero build friction: the standard distribution compiles `libcef_dll_wrapper` + cefclient out of the box; output is
`build/tests/cefclient/Release/cefclient.app` with the five standard helper apps. (cmake/ninja were not preinstalled
on this machine — `brew install cmake ninja` was the only setup step.)

## How the two styles were exercised

Confirmed in this distribution's `include/internal/cef_types_mac.h` (same rule as master):
*"Alloy style will always be used if `windowless_rendering_enabled` is true or if `parent_view` is provided."*
cefclient's native macOS window creates the browser with `SetAsChild(parent_view, …)`
(`tests/cefclient/browser/browser_window_std_mac.mm`) — i.e. exactly Bézier's planned embedding, and forced Alloy.

- **Chrome style**: `--use-views` → CEF Views window with the full Chrome toolbar/omnibox.
- **Alloy style**: default native window (parented browser) plus explicit `--use-alloy-style`
  (sets `runtime_style = CEF_RUNTIME_STYLE_ALLOY` on top of the parent-view forcing).
  Style confirmed behaviorally: no Chrome UI, and `chrome://extensions` navigation is refused in this window.

Launch commands:

```sh
CEFCLIENT=…/build/tests/cefclient/Release/cefclient.app/Contents/MacOS/cefclient

# Chrome style
"$CEFCLIENT" --use-views \
  --load-extension=$HOME/cef-spike-cache/uBOLite_unpacked \
  --cache-path=$HOME/cef-spike-cache/profile \
  --remote-debugging-port=9222 --url=<test-url>

# Alloy style (same profile → same uBOL settings)
"$CEFCLIENT" --use-alloy-style \
  --load-extension=$HOME/cef-spike-cache/uBOLite_unpacked \
  --cache-path=$HOME/cef-spike-cache/profile \
  --remote-debugging-port=9222 --url=<test-url>
```

`--remote-debugging-port` was used to drive pages and read results deterministically over CDP
(page interaction notes below). Both sessions share `--cache-path`, so the uBOL configuration made in the
Chrome-style session carried over to the Alloy session.

## Test pages

`https://d3ward.github.io/toolz/adblock.html` (suggested in the task) is **archived and no longer functional** —
it renders only an "archived" notice (screenshot `img/chrome-style-d3ward-archived.png`). Replacements:

1. **Network blocking** — `testpages/netblock-test.html` (served over `http://localhost:8899`): loads three real,
   currently-live ad/tracker scripts that are on uBOL's default-enabled rulesets
   (`pagead2.googlesyndication.com/pagead/js/adsbygoogle.js`, `static.doubleclick.net/instream/ad_status.js`,
   `www.googletagmanager.com/gtag/js`) plus a benign jsDelivr control script. Verdict = blocked/loaded per row.
2. **Cosmetic filtering** — `testpages/cosmetic-test.html`: three elements matching **generic EasyList cosmetic
   selectors verified to ship inside this uBOL build** (`#AdBanner`, `#Ad-Container`, `.advertembed` — present in
   `rulesets/scripting/generic/easylist.js` of the unpacked extension) plus a green control element. The page
   self-reports how many are `display:none`. Cosmetic hiding requires content-script injection — there is no DNR
   path that can produce it, so a 3/3 verdict is direct proof content scripts run.
3. **Real-site check** — `https://adblock-tester.com` (v3.1.1).

Served locally (content scripts don't run on `file://` URLs by default): `python3 -m http.server 8899`.

## uBO Lite configuration nuance (important)

- uBOL's manifest registers **zero static content scripts**; all cosmetic/scriptlet injection is registered
  dynamically via the `chrome.scripting`/`userScripts` APIs from its MV3 service worker.
- With `--load-extension`, its `<all_urls>` host permission was **granted automatically** (no prompt), and uBOL
  initialized itself to **"Optimal"** default filtering mode (per-site "specific" cosmetic filters only).
- In Optimal mode our generic-selector page shows **0/3 hidden — cosmetic NOT active** even in Chrome style
  (screenshot `img/chrome-style-cosmetic-basic-mode-notactive.png`). This is uBOL policy, not a CEF limitation.
- Switching **Default filtering mode → Complete** in uBOL's dashboard enables generic cosmetic filtering
  everywhere. After that: 3/3 hidden in Chrome style *and* in Alloy style.

## Results with evidence

### Chrome style (`--use-views`)

- **Extension loaded**: `chrome://extensions` lists "uBlock Origin Lite", enabled — `img/chrome-style-extensions-page.png`.
  Chrome toolbar incl. Extensions menu is present.
- **Network blocking**: 4/4 (3 ad scripts blocked, control loaded) — `img/chrome-style-netblock-works.png`.
- **Cosmetic filtering**: 0/3 at default Optimal mode (`img/chrome-style-cosmetic-basic-mode-notactive.png`);
  **3/3 after switching to Complete** — `img/chrome-style-cosmetic-complete-works.png`.
- uBOL dashboard (`chrome-extension://…/dashboard.html`) renders and is interactive.

### Alloy style (native parented window + `--use-alloy-style`)

- **Extension active without any Chrome UI**: uBOL MV3 service worker up (visible as a CDP target).
- **Network blocking**: 4/4 — `img/alloy-style-netblock-works.png`. Window shows cefclient's own minimal
  AppKit controls, no Chrome toolbar.
- **Cosmetic filtering: 3/3 hidden — WORKS** — `img/alloy-style-cosmetic-works.png`. All three generic-EasyList
  elements are `display:none` (verified via computed style over CDP, plus screenshot). **This answers the
  spike's central question: uBO Lite content scripts inject and act in Alloy-style browsers.**
- **adblock-tester.com: 100/100** (11 services, 22 checks) — `img/alloy-style-adblocktester-100.png`.
- **`chrome://extensions`**: navigation silently refused (URL unchanged) — matches CEF #3859; also serves as
  behavioral proof the browser is Alloy style.
- **uBOL options page works in Alloy**: `chrome-extension://ddfleegngaplmlgjpejnlhkpdeoliodn/dashboard.html`
  loads and shows the persisted Complete mode — `img/alloy-style-ubol-dashboard.png`. So `chrome-extension://`
  content is *not* subject to the `chrome://` block, and extension configuration UI can be surfaced inside an
  NSView-embedded browser.
- **Not exercisable in Alloy**: toolbar icon, popup, element picker/zapper — they hang off the Chrome toolbar,
  which doesn't exist here (as expected from the research).

## Friction log

- `cmake`/`ninja` not preinstalled; `brew install cmake ninja` (~1 min). Everything else built first try.
- d3ward adblock test page is dead (archived) — replaced with deterministic local pages (committed under
  `testpages/`).
- **cefclient page-content input quirk** (tooling, not CEF-functional): macOS synthetic AX clicks work on
  browser chrome but coordinate clicks never reached web content in either style, and cefclient does not expose
  renderer accessibility by default. Driving pages via CDP (`--remote-debugging-port=9222`) worked flawlessly;
  note CDP WebSocket connections need either `--remote-allow-origins` or an Origin-less client
  (`websocket-client` with `suppress_origin=True`).
- uBOL's mode switch (Optimal → Complete) requires a *trusted* user gesture on its options UI; done via CDP
  `Input.dispatchMouseEvent` on the radio. No permission prompt appeared (host permissions already granted at
  load).

## What this means for Bézier (and what part 1 does NOT cover)

Validated: the `--load-extension` + Alloy path delivers full uBO Lite filtering (network + cosmetic) in the exact
window configuration Bézier plans to use (browser parented into an app-owned view). Config UI is reachable via
`chrome-extension://` pages even in Alloy.

Still open, for later parts of the spike / the prototype:

- Load-at-startup only: no runtime install/enable/disable API (CEF #3877) — restart required to add/remove the
  extension (settings changes, however, apply live: the Optimal→Complete switch took effect without restart).
- Popup/element-picker UX would need to be rebuilt natively (or a Views-based Chrome-style window opened ad hoc).
- Behavior inside a *real* app-owned NSView (cefclient's native window is the closest proxy; an actual
  `CefWindowInfo.SetAsChild(myNSView)` embed in a Swift/AppKit app is part 2 territory).
- OSR (windowless) was not exercised.
