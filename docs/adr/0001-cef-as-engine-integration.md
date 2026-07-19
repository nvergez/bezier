# CEF as the engine integration

Bézier needs Chromium (Chrome extensions are non-negotiable) but a fully native Swift/AppKit UI. We integrate via CEF rather than a full Chromium fork or the bare `//content` layer: CEF's stable API absorbs Chromium's churn, precompiled distributions avoid routine engine builds, and validation spikes ([#3](https://github.com/nvergez/bezier/issues/3), [#8](https://github.com/nvergez/bezier/issues/8)) confirmed the load-bearing capabilities — uBO Lite network + cosmetic filtering in an embedded browser, and native overlay compositing — under adversarial review.

## Considered Options

- **`//content` layer + custom integration** (Arc's ADK path): maximum control, but a solo dev reimplements extension APIs and absorbs unstable-API churn every release. Retained as the documented fallback if CEF becomes limiting.
- **Full Chromium fork** (Brave/Vivaldi path): everything works day one, but Arc-level UI polish is hard from C++ Views, and rebases land every 4 weeks.
- **WKWebView**: zero engine maintenance but no Chrome extensions — eliminated by requirements.

## Consequences

Extension support rides on Chrome-style runtime semantics: MV2 (classic uBlock Origin) is gone upstream, extensions load via startup flag + restart ([CEF #3877](https://github.com/chromiumembedded/cef/issues/3877)), and fresh-profile uBO Lite needs one-time Complete-mode configuration. These live on the product risk register, not the engine's.
