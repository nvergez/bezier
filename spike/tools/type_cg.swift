// Posts real CGEvent keystrokes (HID tap) — routed by the window server to
// the frontmost app, exactly like physical typing. Used by the overlay focus
// probe because higher-level automation (AX keystrokes) is blocked in this
// environment. Build: swiftc -O -o type_cg type_cg.swift
// Usage: ./type_cg "text to type"
// Requires Accessibility permission for the responsible (parent) process.

import CoreGraphics
import Foundation

let text = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test"
let src = CGEventSource(stateID: .combinedSessionState)
for scalar in text.unicodeScalars {
  var utf16 = Array(String(scalar).utf16)
  guard
    let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
    let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
  else {
    fatalError("CGEvent creation failed")
  }
  down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
  up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  usleep(30000)
}
print("posted \(text.unicodeScalars.count) key pairs")
