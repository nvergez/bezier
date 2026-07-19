#include "BezierCefApp.h"

#include "include/wrapper/cef_helpers.h"

#import "BezierMessagePump.h"
#import "CefBridge.h"

void BezierCefApp::OnContextInitialized() {
  CEF_REQUIRE_UI_THREAD();
  [CefBridge.shared markCefReady];
}

void BezierCefApp::OnScheduleMessagePumpWork(int64_t delay_ms) {
  // May be called on any thread; the pump marshals to the main thread.
  [BezierMessagePump.shared scheduleWork:delay_ms];
}
