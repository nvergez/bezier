# BezierSpike — CEF-in-NSView validation app (spike, throwaway)

Minimal AppKit app for [Bézier #3](https://github.com/nvergez/bezier/issues/3) part 2:
a Swift `NSWindow` + URL bar with a CEF browser embedded in an app-owned `NSView`
(Alloy style, `CefWindowInfo.SetAsChild(parent_view)`). Results in
`docs/spike/swift-embed-evidence.md`.

## Layout

- `src/AppDelegate.swift` — window, native URL bar, container NSView (Swift)
- `src/CefBridge.{h,mm}` — pure-ObjC facade over the CEF C++ API (the Swift bridging header)
- `src/BezierClient.{h,mm}` — CefClient (life-span + display handlers)
- `src/BezierCefApp.{h,mm}` — CefApp / browser-process handler
- `src/BezierMessagePump.{h,mm}` — external message pump (port of cefclient's mac pump, 8 ms idle ceiling)
- `src/main.mm` — bootstrap: library loader, `CefAppProtocol` NSApplication subclass, CefInitialize, `[NSApp run]`
- `helper/process_helper_mac.cc` — helper-process entry point (verbatim cefsimple)
- `mac/*.plist.in` — app + helper Info.plists

## Build

Requires the CEF binary distribution from part 1 (default path
`~/cef-spike-cache/cef_binary_150.0.11+gb887805+chromium-150.0.7871.115_macosarm64`,
override with `-DCEF_ROOT=`), cmake ≥ 3.21, ninja, Xcode toolchain.

```sh
cmake -G Ninja -B build -DCMAKE_BUILD_TYPE=Release .
ninja -C build
# → build/Release/BezierSpike.app
```

## Run

```sh
./build/Release/BezierSpike.app/Contents/MacOS/BezierSpike \
  --use-mock-keychain \
  --load-extension=$HOME/cef-spike-cache/uBOLite_unpacked \
  --cache-path=$HOME/cef-spike-cache/profile \
  --remote-debugging-port=9223 \
  --url=http://localhost:8899/netblock-test.html
```

**`--use-mock-keychain` is required for dev builds.** Without it the network
service blocks forever on Chromium Safe Storage keychain access (every rebuild
changes the ad-hoc code signature, so the Keychain ACL no longer matches) and
no navigation ever commits. See the evidence doc's friction log.

`--cef-loop` switches from the external message pump to `CefRunMessageLoop()`
for A/B comparison. `--cache-path` and `--url` as in cefclient.
