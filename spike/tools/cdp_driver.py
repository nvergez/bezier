#!/usr/bin/env python3
"""Minimal CDP driver for the overlay spike (Bézier #8).

Talks to the BezierSpike app's --remote-debugging-port. Subcommands:

  targets                       list debug targets
  eval  --expr EXPR             evaluate JS in the page, print the result
  click --x X --y Y             trusted mouse click at page coords
  scroll --x X --y Y --delta D --count N --interval S
                                stream of mouseWheel events (trusted input)

Uses websocket-client with suppress_origin (CEF rejects browser origins).
"""

import argparse
import json
import sys
import time

import websocket


def page_ws_url(port):
    import urllib.request
    with urllib.request.urlopen(f"http://localhost:{port}/json") as r:
        targets = json.load(r)
    pages = [t for t in targets if t.get("type") == "page"]
    if not pages:
        sys.exit("no page target found")
    return pages[0]["webSocketDebuggerUrl"], pages[0]["url"]


class Session:
    def __init__(self, port):
        url, self.page_url = page_ws_url(port)
        self.ws = websocket.create_connection(url, suppress_origin=True, timeout=30)
        self.msg_id = 0

    def cmd(self, method, params=None):
        self.msg_id += 1
        self.ws.send(json.dumps(
            {"id": self.msg_id, "method": method, "params": params or {}}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == self.msg_id:
                return msg.get("result", msg)

    def eval(self, expr):
        r = self.cmd("Runtime.evaluate",
                     {"expression": expr, "returnByValue": True})
        return r.get("result", {}).get("value")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=9223)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("targets")
    e = sub.add_parser("eval")
    e.add_argument("--expr", required=True)
    c = sub.add_parser("click")
    c.add_argument("--x", type=float, required=True)
    c.add_argument("--y", type=float, required=True)
    s = sub.add_parser("scroll")
    s.add_argument("--x", type=float, default=500)
    s.add_argument("--y", type=float, default=400)
    s.add_argument("--delta", type=float, default=-60)
    s.add_argument("--count", type=int, default=200)
    s.add_argument("--interval", type=float, default=0.016)
    args = p.parse_args()

    if args.cmd == "targets":
        import urllib.request
        with urllib.request.urlopen(f"http://localhost:{args.port}/json") as r:
            print(json.dumps(json.load(r), indent=2))
        return

    sess = Session(args.port)
    if args.cmd == "eval":
        print(json.dumps(sess.eval(args.expr)))
    elif args.cmd == "click":
        for t in ("mousePressed", "mouseReleased"):
            sess.cmd("Input.dispatchMouseEvent",
                     {"type": t, "x": args.x, "y": args.y,
                      "button": "left", "clickCount": 1})
        print("clicked")
    elif args.cmd == "scroll":
        t0 = time.time()
        for _ in range(args.count):
            sess.cmd("Input.dispatchMouseEvent",
                     {"type": "mouseWheel", "x": args.x, "y": args.y,
                      "deltaX": 0, "deltaY": args.delta})
            time.sleep(args.interval)
        print(json.dumps({"events": args.count, "seconds": time.time() - t0,
                          "scrollY": sess.eval("window.scrollY")}))


if __name__ == "__main__":
    main()
