# Adversarial review of CEF spike evidence

Review target: [Bézier #3](https://github.com/nvergez/bezier/issues/3),
`cefclient-evidence.md`, `swift-embed-evidence.md`, their screenshots, the
committed test pages and spike source, and the built artifacts in
`~/cef-spike-cache/` and `spike/BezierSpike/build/`.

## Executive verdict

The spike answers its pivotal engine question: **CONFIRMED — uBO Lite can
inject cosmetic-filtering CSS into an Alloy-style CEF browser embedded in an
app-owned NSView.** This is not merely a network-blocking result, and I
independently reproduced it in the built Swift app.

The evidence does **not** justify the broader statement that the demonstrated
extension setup is already something Bézier can ship. That claim is
**UNSUPPORTED**: every successful generic-cosmetic run uses an unpacked
extension loaded from a developer cache, a startup flag, and a shared profile
manually put into Complete mode in a previous session. A fresh profile loads
the extension but produces 0/3 on the generic cosmetic test. Production
packaging, stable extension identity, first-run configuration/consent,
updates, and restart UX remain untested.

This is therefore a pass for **CEF capability**, not a pass for **production
extension integration**.

## Verdicts on the load-bearing claims

| Claim | Verdict | Reason |
|---|---|---|
| The Alloy and Swift results demonstrate cosmetic element hiding, not only network blocking. | **CONFIRMED** | The committed page contains three visible red elements and no rule that hides them. Its script reports their computed `display`; the screenshots show all three absent and report 3/3. The selectors are in the unpacked uBOL EasyList generic rules. My live CDP inspection found the matching injected rule containing `#AdBanner`, `#Ad-Container`, and `.advertembed` with `display: none !important`; without the extension the same elements remained `block`. |
| A 100/100 adblock-tester.com score proves cosmetic filtering. | **REFUTED** | That score is not an isolated cosmetic-filtering test and could be achieved largely through network rules. It is corroborative only. The local cosmetic page, not the score, carries the cosmetic claim. |
| Chrome style and Alloy style were genuinely exercised. | **CONFIRMED** | The Chrome screenshots show Chromium's toolbar/omnibox and `chrome://extensions`; the native cefclient screenshots show cefclient's AppKit controls; the Swift screenshots show its own one-line native URL bar. CEF source forces Alloy when `parent_view` is present, and the Swift bridge additionally sets `CEF_RUNTIME_STYLE_ALLOY`. In my Swift run, navigation to `chrome://extensions` returned `net::ERR_ABORTED` and left the prior URL unchanged, as expected for Alloy. |
| uBO Lite is active in the embedded app. | **CONFIRMED** | The original dashboard screenshot and filtering result support this. Independently, the CDP target list contained `Service Worker chrome-extension://ddfleegngaplmlgjpejnlhkpdeoliodn/js/background.js`; the target disappeared in a no-extension control run. |
| The shown startup loading path is production-shippable. | **UNSUPPORTED** | `--load-extension` works at process startup, but the spike uses an unpacked directory under `~/cef-spike-cache/` and an already-mutated external profile. It does not test an app-bundled, signed/notarized layout, relocation/stable extension identity, upgrades, corruption recovery, or first-run policy. CEF's runtime-load request remains open ([CEF #3877](https://github.com/chromiumembedded/cef/issues/3877)); adding/removing an extension requires restart. A product can supply its own hidden startup arguments, but that alone is not an extension lifecycle. |
| “Everything Bézier needs works” on first launch. | **REFUTED** | With a fresh profile plus the same `--load-extension` flag, the uBOL service worker ran but the test stayed at 0/3 because uBOL starts below Complete mode. The successful Swift evidence inherits Complete mode from the shared profile configured during part 1. The documents disclose this caveat, but their top-line wording overstates the result. |
| The extension dashboard is usable in Alloy. | **CONFIRMED for rendering; UNSUPPORTED for the full interaction claim** | Both Alloy hosts visibly render the real `chrome-extension://.../dashboard.html`, including persisted Complete mode. The retained evidence does not show an interaction or prove that a fresh Alloy-only flow can grant/configure Complete mode; the described trusted CDP click was performed during the earlier setup, with no trace retained. |
| Clean shutdown exits with status 0. | **REFUTED in this reproduction** | Three AppleEvent quit attempts reached `DoClose` and `OnBeforeClose` and left no processes, but the launched main process returned status 1 each time. This does not undermine filtering, but it contradicts the stated `exit 0` result and deserves a dedicated lifecycle test before treating shutdown as solved. |

## Independent reproduction

I used the already-built
`spike/BezierSpike/build/Release/BezierSpike.app`, the unpacked uBOL build, the
committed `cosmetic-test.html`, and separate CDP ports. No spike source or
existing evidence was changed.

### Shared configured profile, extension enabled

The app was launched with the same material flags as the evidence:

```sh
BezierSpike \
  --use-mock-keychain \
  --load-extension=$HOME/cef-spike-cache/uBOLite_unpacked \
  --cache-path=$HOME/cef-spike-cache/profile \
  --remote-debugging-port=9237 \
  --url=http://localhost:8898/cosmetic-test.html
```

Observed over CDP:

- page target URL: `http://localhost:8898/cosmetic-test.html`;
- uBOL MV3 service-worker target present;
- `#AdBanner`: `display: none`;
- `#Ad-Container`: `display: none`;
- `.advertembed`: `display: none`;
- `#control`: `display: block`;
- page verdict: `3/3 ad elements hidden`;
- the matched CSS rule included all three test selectors and declared
  `display: none !important` with CDP origin `user-agent`;
- `chrome://extensions` navigation failed with `net::ERR_ABORTED`, leaving the
  page URL unchanged.

This is direct evidence of cosmetic CSS application in the Swift-owned Alloy
embed. DNR alone cannot change those computed styles, and the no-extension
control below excludes the page itself as the cause.

### Fresh-profile controls

I repeated the same page in the same binary with temporary fresh profiles:

| Run | Service worker | Test result |
|---|---|---|
| No `--load-extension` | absent | 0/3; all test elements and control `display: block` |
| Same `--load-extension`, fresh profile | present | 0/3; all test elements and control `display: block` |

The second row is important: it proves extension loading and Complete-mode
cosmetic activation are separate claims. The spike proves the latter only
after profile configuration.

### Origin sensitivity found during reproduction

In the configured-profile run,
`http://127.0.0.1:8898/cosmetic-test.html` produced 0/3 while the exact
`http://localhost:8898/cosmetic-test.html` origin produced 3/3 in the same live
browser. I did not isolate whether this comes from uBOL's site policy,
permission handling, or an origin-specific override. It does not refute
content scripts on normal hostnames, but it refutes the evidence's casual
wording that Complete mode enables the test “everywhere” and shows why exact
origins and filtering-mode state must be recorded.

## Methodology audit

### What is strong

- The cosmetic page is purpose-built for the pivotal question. Its page CSS
  colors elements but never hides them, its JavaScript checks computed style,
  and its selectors occur in the tested uBOL artifact's generic EasyList
  rules. This is much stronger than a third-party aggregate score.
- The visible UI in the screenshots is consistent with the claimed host in
  each case. The Swift images include its distinct native URL bar, so there is
  no indication that a cefclient window was mistaken for the app.
- Source inspection independently establishes the Swift embedding path:
  `SetAsChild(view, rect)` plus `CEF_RUNTIME_STYLE_ALLOY`.
- The pre-configuration 0/3 screenshot is a useful negative control and
  correctly shows that extension presence/network filtering does not imply
  generic cosmetic filtering.

### Holes and overclaims

1. **Shared mutable profile.** Chrome cefclient, Alloy cefclient, and the Swift
   app all use the same cache path. This is useful for proving persistence but
   prevents the successful runs from representing independent installs or a
   first-run product experience. The decisive Complete-mode state was created
   before the Swift run.
2. **No retained machine-readable run record.** The documents describe CDP
   target inspection, computed styles, navigation failures, frame timings, and
   a trusted input event, but commit only screenshots and prose. Screenshots
   substantiate visible state, not launch arguments, network failure reasons,
   interactivity, or timing distributions. A small command transcript or JSON
   result would make the experiment auditable.
3. **The network test conflates failure with blocking.** Its `script.onerror`
   treats DNS, TLS, server, connectivity, and policy failures as successful ad
   blocking. A benign jsDelivr control proves general connectivity, not that
   each ad-host failure was caused by DNR. The URLs are not cache-busted, and
   no CDP `blockedReason`, DNR matched-rule output, or netlog is retained.
   Thus the network screenshots are supportive but not conclusive about the
   mechanism.
4. **Third-party scores are volatile and non-specific.** adblock-tester.com is
   useful as a smoke test but cannot carry the content-script claim. The
   archived d3ward page correctly was discarded.
5. **Dashboard screenshots prove render state, not interaction.** Complete is
   visibly selected in Alloy and Swift, but that state was inherited. No
   retained evidence shows a fresh-profile user completing the required
   permission/configuration flow inside the product-style embed.
6. **Production conditions were not exercised.** All runs use an unpacked
   extension and ad-hoc-signed app; dev runs need `--use-mock-keychain`.
   Stable signing/keychain behavior, helper entitlements, notarization,
   app-bundle extension placement, and updates are explicitly outside the
   spike. They should remain outside any “ship-ready” conclusion too.
7. **Ancillary claims are less auditable than the filtering result.** The
   ~120 fps and resize numbers have no trace, and the stated clean `exit 0`
   was not reproduced. Neither should be used as decision evidence without a
   repeatable harness.

## Decision consequence

If ticket #3's decision gate is narrowly “Can current CEF run uBO Lite's
network and cosmetic machinery in the AppKit/NSView Alloy architecture?”, the
answer is **yes** and the central unknown is retired.

Before treating uBO Lite integration as a product plan, require a second gate:

1. load the extension from its final signed app-bundle location with a stable
   identity;
2. define and test the fresh-profile permission/Complete-mode flow entirely
   inside the Alloy product UI;
3. define extension and ruleset update behavior and the user-visible restart
   contract;
4. rerun cosmetic and network tests from a fresh profile with machine-readable
   CDP/netlog output; and
5. add a repeatable shutdown test that asserts process status and absence of
   helper processes.

The evidence supports committing to CEF on technical feasibility, but not
removing extension lifecycle, first-run configuration, signing, or shutdown
from the risk register.
