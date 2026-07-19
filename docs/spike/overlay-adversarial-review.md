# Adversarial review of the native-overlay spike

Review target: [Bézier #8](https://github.com/nvergez/bezier/issues/8),
`overlay-evidence.md`, the committed screenshots and traces, the trace analyzer,
the spike source, and the already-built `BezierSpike.app`. I also repeated the
animated-command-bar-while-scrolling run with a separate cache and trace
directory. No spike source or existing evidence was changed.

## Executive verdict

The narrow composition result is **CONFIRMED**: ordinary AppKit sibling views
can appear above the windowed Alloy CEF view. The static panel, translucent
square, command bar, and command-bar-over-video screenshots visibly overlap
rendered web content, and the source uses `SetAsChild` rather than OSR. The
basic fear that a child CEF view must always cover native siblings is therefore
retired.

The stronger conclusion, “120 Hz animation over live/scrolling/video content
is established, so no OSR fallback is needed,” is **UNSUPPORTED**. The traces
show mostly 8.33 ms `CADisplayLink.timestamp` deltas on a screen reporting a
120 Hz maximum, but they never observe the command bar's presented frames.
They also do not retain scroll positions, video playback-quality snapshots, or
callback-entry wall-clock times. The headline 99.7% figure is arithmetically
inconsistent with the committed static-page trace.

The keyboard result is split: focus capture and lack of key leakage are
**CONFIRMED** in the retained screenshot; clean focus return is
**UNSUPPORTED** because the claimed after-dismiss transcript/state dump is not
committed.

This is a pass for **windowed-CEF z-order feasibility**, not yet a pass for
the spike's end-to-end 120 fps, continuous-resize, or complete focus-contract
claims.

## Verdicts on the load-bearing claims

| Claim | Verdict | Reason |
|---|---|---|
| The traces establish 120 Hz command-bar animation. | **UNSUPPORTED** | They establish display-link notification cadence, not presentation cadence of the Core Animation slide/fade. `timestamp` is the time of the previously displayed frame, not the time at which this main-thread callback ran; no `CACurrentMediaTime()` callback-entry value or presentation-layer sample is recorded. |
| The animation runs on a 120 Hz display rather than a 60 Hz external display. | **CONFIRMED** | Every committed trace says `screenName: Built-in Retina Display` and `screenMaxFPS: 120`; the idle baseline actually advances at 8.333 ms for 734 intervals. My run logged the same screen and maximum and also produced 8.333 ms cadence. A 60 Hz display does not explain the data. |
| The committed demanding traces prove scrolling/video activity during the animation window. | **UNSUPPORTED** | The scroll trace contains only a freely supplied scenario label, URL, bar markers, and display-link samples; it has no scroll markers or positions. The video trace contains the URL but no `paused`, decoded-frame, or dropped-frame samples. Screenshots show those conditions at an instant but cannot be tied to the trace interval. My independent scroll run confirms the scenario is cheaply reproducible, but it does not retroactively add provenance to the committed files. |
| The reported frame-interval and dropped-refresh counts match the trace data. | **CONFIRMED, except for the 99.7% headline** | The analyzer's medians, percentiles, maxima, drop-event counts, and missed-refresh counts reproduce. However, only 958/972 (98.56%) static-page intervals are within a generous 8.5 ms interpretation of the 8.333 ms budget, and 959/972 (98.66%) avoid the analyzer's much looser `> 1.5x budget` drop threshold. Neither yields 99.7%. |
| Every miss is at a Core Animation commit point, with zero misses during animation. | **REFUTED** | In `anim-static-page.json`, the 19.029 ms and 14.304 ms intervals beginning at 178964.660756 and 178964.679785 occur in the shown dwell, about 125–144 ms after `bar.showEnd` and 116–135 ms before `bar.hideStart`, not at a commit. The video trace also has an overall 20.832 ms miss before the first bar event. Most remaining misses overlap the opening portion of a `bar.showStart`/`bar.showEnd` window, so “zero during animation” is not literally supported either. |
| Native overlays are genuinely above, and overlap, windowed CEF web content. | **CONFIRMED** | The panel spans visible section boundaries, its backdrop color changes between `y=0` and `y=7800`, the red square alpha-blends over page colors, and the command bar visibly crosses the playing-video image. These are overlapping bounds, not side-by-side controls or a blank browser. |
| The overlay remains visually correct throughout scrolling and live resize. | **UNSUPPORTED as a continuous claim** | Two scroll endpoints establish correct placement before and after a large scroll. One scripted-resize screenshot establishes one correct intermediate state. Static images cannot establish every intermediate frame, and the resize trace itself reports substantial callback loss. A real event-tracking live drag was not run. |
| The command bar captures focus and does not leak typed keys to CEF. | **CONFIRMED** | `overlay-focus-typed.png` shows `hello overlay` in the native field while the page input remains `page-before`; the renderer log ends with `window blur` and contains only the 11 pre-overlay keydowns. This is strong same-frame evidence for capture and non-leakage. |
| Dismissing the bar returns focus cleanly to the same page input. | **UNSUPPORTED** | No `state.json`, CDP readback, log, or screenshot of `page-before-after` is committed. The source attempts `makeFirstResponder(cefView)` plus `SetFocus(true)`, but implementation intent is not retained outcome evidence. The document's reference to a “committed transcript” is incorrect. |
| The overlay result by itself makes OSR unnecessary. | **CONFIRMED only for the z-order requirement** | OSR is not needed merely to put these AppKit siblings over CEF. Whether windowed CEF meets the production animation, resize, hit-testing, and long-session performance bar remains open; the current evidence cannot support a blanket engine conclusion on those axes. |

## Independent trace audit

I parsed the raw `frames` arrays rather than trusting
`analysis-summary.json`. “Within budget” below allows 8.5 ms to avoid treating
floating-point representation around 8.333 ms as a miss. “Drop events” uses
the spike analyzer's own rule, interval greater than 12.5 ms; “refreshes
missed” uses its rounded interval/budget calculation.

| Trace | Intervals | <= 8.5 ms | Effective callback rate | Drop events | Refreshes missed | Maximum |
|---|---:|---:|---:|---:|---:|---:|
| `baseline-idle.json` | 734 | 734 (100%) | 120.001 Hz | 0 | 0 | 8.333 ms |
| `anim-static-page.json` | 972 | 958 (98.56%) | 118.297 Hz | 13 | 14 | 21.364 ms |
| `anim-while-scrolling.json` | 976 | 971 (99.49%) | 119.389 Hz | 5 | 5 | 20.557 ms |
| `anim-while-video.json` | 971 | 959 (98.76%) | 118.475 Hz | 11 | 12 | 21.787 ms |
| Independent scroll reproduction | 974 | 965 (99.08%) | 118.902 Hz | 8 | 9 | 20.864 ms |

The committed distribution is genuinely concentrated at 8.333 ms. The
traces are therefore useful evidence that the main run loop receives nearly
120 notifications per second in these short runs. They do not justify calling
those notifications rendered command-bar frames. Apple documents
[`timestamp`](https://developer.apple.com/documentation/quartzcore/cadisplaylink/timestamp)
as the time the last frame displayed and
[`targetTimestamp`](https://developer.apple.com/documentation/quartzcore/cadisplaylink/targettimestamp)
as the time the next frame displays. Apple's `duration` guidance says to use
`targetTimestamp - CACurrentMediaTime()` for the actual time remaining in a
callback. This recorder stores only `timestamp` and `targetTimestamp`, whose
difference is almost always exactly one 8.333 ms refresh in these files; it
does not store callback-entry `CACurrentMediaTime()`.

More importantly, the bar's slide/fade is committed once and runs in the
render server, as the evidence itself acknowledges. A main-thread display
link cannot reveal whether the render server presented eight, fifteen, or
thirty distinct bar positions during a 250 ms transition, whether CEF and the
bar presented in the same refresh, or whether the animation visibly hitched.
The screenshots do not close that gap: a still image establishes z-order and
one visual state, not animation cadence.

The video “0 dropped frames during the loop” result is likewise not retained.
The screenshot shows one useful instant (`paused:false`, `readyState:4`, 573
total frames, 1 dropped), but the claimed 447-to-736 before/after values are
only prose. Nothing machine-readable shows that `droppedVideoFrames` stayed
constant during the trace.

## Condition and methodology audit

### What is strong

- The screenshots decisively answer the basic z-order question. Both vibrancy
  and ordinary alpha compositing visibly combine with nonblank CEF content.
- The scroll screenshots include page-controlled section numbers and `y`
  values, providing a useful before/after control for backdrop changes.
- The command-bar trace files carry bar start/end markers in the same Core
  Animation timebase as their scheduled frame timestamps.
- All committed traces identify a 120 Hz built-in display, and the idle trace
  corroborates that with 8.333 ms cadence.
- The focus screenshot combines native-field text and the renderer's key log
  in one image, making leakage during overlay entry hard to fake
  accidentally.

### Holes and overclaims

1. **No end-to-end animation observation.** There is no 120 fps capture,
   presentation-layer sampling, compositor/WindowServer trace, or frame-coded
   animation. The measured component is not the component that animates the
   overlay.
2. **Conditions are labels, not measurements.** `next-label.txt` controls the
   scenario name. Scroll activity, scroll position, video state, and video
   quality are not sampled into the trace, so an idle run can be labeled
   `anim-while-scrolling` without making the file internally inconsistent.
3. **No control that isolates overlay cost under load.** There is an idle-page
   baseline, but no scroll-only and no video-only trace. The surprising result
   that scrolling has fewer misses than the static-page run cannot be
   attributed to the overlay, CEF load, or ordinary run-to-run noise.
4. **One short run per condition.** Each animation trace is roughly 8.2
   seconds. There are no repetitions, confidence intervals, cold/warm split,
   or declared rule for accepting/rejecting a run. The independent run's
   higher miss count demonstrates meaningful run-to-run variability even
   though both runs look broadly similar.
5. **Attribution logic is incomplete.** The committed analyzer calculates
   activity-window statistics but does not implement the prose claim that
   every miss is at a commit. Its window filter includes an interval only when
   the interval's start is after the first marker, so an interval crossing
   `bar.showStart` is excluded. The separate attribution script mentioned in
   the evidence is not committed.
6. **Static screenshots stand in for temporal claims.** They support overlap,
   focus state, a scroll endpoint, and one resize state. They cannot support
   “mid-animation is smooth,” “backdrop updates live,” or “correct at every
   intermediate size.”
7. **The focus transcript is missing.** The retained image covers capture and
   non-leakage only. The first-responder dumps and after-dismiss CDP values
   cited in prose are absent from the tree.
8. **The summary file is not valid single-document JSON.** It concatenates
   five top-level JSON objects. The underlying traces remain parseable, but
   consumers expecting one JSON value will fail.
9. **The resize probe is not live resize.** It is a 300-step timer-driven
   `setFrame` test outside the window manager's event-tracking behavior. The
   evidence discloses this limitation, but its broader “live resize” wording
   should not be used as a verified product property.
10. **The workload is narrow.** The scroll page is colored static sections and
    the video is a local 720p30 synthetic VP9 clip. Neither approximates a
    complex production page, simultaneous panels, browser-container resize,
    or a long session.

## Independent reproduction

I launched the existing Release app with `--use-mock-keychain`, a separate
cache, CDP on port 9223, a temporary trace directory, `--prefer-promotion`, and
the committed local scroll page. The app logged:

```text
BezierSpike: window on screen 'Built-in Retina Display' maxFPS=120
```

I first scrolled to `y=4680`, then started the same 500-event CDP wheel stream
(`deltaY=120`, 16 ms requested interval) and immediately posted
`com.bezier.spike.loop`. The external stream completed in 12.534 seconds at
`y=64800`; the 8.192-second animation trace was wholly contained inside that
stream. This is a genuine animation-while-scrolling reproduction, not an idle
page relabeled after the fact.

The reproduction recorded 975 callbacks / 974 intervals, median and p95
8.333 ms, p99 8.333 ms, maximum 20.864 ms, 8 analyzer-defined drop events and
9 missed refreshes. The committed scrolling trace records 976 intervals,
maximum 20.557 ms, 5 drop events and 5 missed refreshes. The shape and worst
stall reproduce; the miss count does not reproduce exactly and is 60% higher
by events / 80% higher by missed refreshes in the repeat. Both still represent
roughly 119 display-link callbacks per second over a very short window.

This repeat strengthens the narrow cadence result and confirms that the
automation can run concurrently with scrolling. It does not repair the
instrumentation boundary: the new trace also observes scheduled display-link
times, not the bar's presented frames.

## Decision consequence

Ticket #8 can close the architectural unknown “can AppKit content be stacked
above windowed CEF?” with **yes**. That result removes z-order as a reason to
choose OSR.

Do not use this evidence to assert a verified 120 fps production animation or
to erase all overlay-related risk. Before making performance load-bearing,
retain one repeatable artifact that records, in the same run:

1. callback-entry `CACurrentMediaTime()`, display-link timestamps, scroll
   position/events, and video playback-quality snapshots;
2. actual overlay presentation progress (for example, presentation-layer
   samples or a frame-coded high-refresh capture);
3. loaded and idle controls with several runs each; and
4. a focus transcript covering page-before, overlay typing, dismissal, and
   page-after.

Windowed CEF is demonstrated to be **composition-capable**. The current
evidence does not demonstrate that it is already **performance-qualified** for
the full Arc-style overlay contract.
