#!/usr/bin/env python3
"""Analyze a BezierSpike CADisplayLink frame-pacing trace (overlay spike, #8).

Input: trace JSON written by FrameTraceRecorder (meta / events / frames).
Output: human-readable summary + one machine-readable JSON line per trace.

A "frame interval" is the delta between consecutive CADisplayLink callback
timestamps on the main thread. Budget = 1000 / meta.screenMaxFPS ms. An
interval > 1.5x budget means at least one display refresh went by without the
main thread getting its tick — reported as dropped (interval/budget - 1,
rounded, refreshes missed).
"""

import json
import statistics
import sys


def analyze(path):
    with open(path) as f:
        trace = json.load(f)
    meta = trace["meta"]
    frames = trace["frames"]
    events = trace["events"]
    ts = [f["t"] for f in frames]
    if len(ts) < 10:
        return {"file": path, "error": "too few frames", "frames": len(ts)}

    max_fps = meta.get("screenMaxFPS") or 60
    budget_ms = 1000.0 / max_fps
    intervals = [(b - a) * 1000.0 for a, b in zip(ts, ts[1:])]

    # Activity windows: frames between the first and last event of a family
    # (bar.* = command-bar animation cycles, resize.* = scripted resize).
    def window_intervals(prefix):
        marks = [e["t"] for e in events if e["label"].startswith(prefix)]
        if not marks:
            return []
        lo, hi = min(marks), max(marks)
        return [(b - a) * 1000.0 for a, b in zip(ts, ts[1:]) if lo <= a <= hi]

    anim_intervals = window_intervals("bar.")
    resize_intervals = window_intervals("resize.")

    def stats(iv):
        if not iv:
            return None
        s = sorted(iv)
        dropped = [x for x in iv if x > 1.5 * budget_ms]
        return {
            "n": len(iv),
            "mean_ms": round(statistics.mean(iv), 3),
            "median_ms": round(statistics.median(iv), 3),
            "p95_ms": round(s[int(len(s) * 0.95) - 1], 3),
            "p99_ms": round(s[int(len(s) * 0.99) - 1], 3),
            "max_ms": round(max(iv), 3),
            "dropped_events": len(dropped),
            "refreshes_missed": sum(round(x / budget_ms) - 1 for x in dropped),
            "worst_stall_ms": round(max(iv), 3),
        }

    return {
        "file": path,
        "scenario": meta.get("scenario"),
        "date": meta.get("date"),
        "machine": meta.get("machine"),
        "os": meta.get("os"),
        "screen": meta.get("screenName"),
        "screenMaxFPS": max_fps,
        "budget_ms": round(budget_ms, 3),
        "url": meta.get("currentURL"),
        "duration_s": round(ts[-1] - ts[0], 3),
        "overall": stats(intervals),
        "animation_active": stats(anim_intervals),
        "resize_active": stats(resize_intervals),
        "cycles": meta.get("cycles"),
        "events": [e["label"] for e in events],
    }


def main():
    for path in sys.argv[1:]:
        r = analyze(path)
        print(json.dumps(r, indent=2))


if __name__ == "__main__":
    main()
