# Windowed embedding via parent_view, with an external message pump

The CEF browser lives in an app-owned NSView (`CefWindowInfo::SetAsChild(parent_view)`), which forces CEF's Alloy runtime style, and CEF integrates with AppKit's run loop via `external_message_pump`. Both were validated hands-on: overlays (vibrancy panels, animated command bar) composite correctly above the windowed browser with clean keyboard-focus capture, retiring z-order as a reason to use off-screen rendering; the external pump worked without friction.

## Considered Options

- **Off-screen rendering (OSR)**: full compositing control, but unvalidated here, open macOS bugs upstream, and it reimplements IME/accessibility/drag-and-drop. Fallback if build-phase performance gates fail.
- **Timer-driven `CefDoMessageLoopWork`**: simpler but polls at a fixed interval — a latency floor with wasted wakeups.

## Consequences

Alloy style blocks `chrome://` pages and extension toolbar/popup UI inside the browser view — Bézier provides its own native surfaces for those (it wants to anyway). `chrome-extension://` pages (e.g. the uBO Lite dashboard) render fine. Quantified animation smoothness is not yet proven; a repeatable presentation-trace harness is a build-phase quality gate.
