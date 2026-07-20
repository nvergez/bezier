# Bézier

An open source, macOS-only, Arc-style web browser built on CEF (Chromium) with a native Swift/AppKit UI. Built first for its author to replace Arc as a daily driver.

## Language

The UI vocabulary is a deliberate geometry metaphor (a Bézier curve). Universal terms (**sidebar**, **tab**, **window**) are kept as-is — fighting them costs clarity for no identity gain.

**Space**:
A named workspace in the sidebar grouping related tabs and pins. Keeps its plain name — the concept where clarity matters most.
_Avoid_: Spline, workspace, profile (a Space is not a cookie-isolation boundary in the MVP — see ADR/scope; all Spaces share one profile).

**Compass**:
The command bar — the keyboard-driven surface for navigation, search, and actions.
_Avoid_: Command bar, launcher, omnibox, palette.

**Chord**:
The minimal single-purpose window that opens external links outside the main window, with an action to promote its tab into the main window. Bézier's equivalent of Arc's "Little Arc"; a chord subtends an arc.
_Avoid_: Little Arc, mini window, popup window.

**Glance**:
A transient floating overlay that previews a link's content without navigating away from the current page.
_Avoid_: Peek, preview, hover card.

**Split**:
Two tabs displayed side by side within one main-window content area.
_Avoid_: Split view, split screen, dual pane.
