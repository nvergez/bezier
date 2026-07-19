# Obj-C++ wrapper as the Swift↔CEF bridge

Swift never sees CEF headers: a thin Objective-C++ (`.mm`) layer wraps CEF's C++ API behind a clean Obj-C interface that Swift imports natively. The embed spike proved this out (~950 LOC including the bridge) with low friction, while direct Swift/C++ interop with CEF's macro-heavy, ref-counted headers is unproven and was flagged as risky in research — a bad foundation bet without its own spike.

## Consequences

The one sharp edge is object lifetime: CEF ties browser teardown to its NSView's dealloc, and Swift/ARC strong references silently defeat it (the spike hit a flaky quit, exit status 1). The bridge must own an explicit ownership/shutdown convention rather than leaning on ARC; a repeatable shutdown test is a build-phase gate.
