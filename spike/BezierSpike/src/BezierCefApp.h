// Browser-process CefApp: wires OnScheduleMessagePumpWork to the external
// pump and signals the bridge when the CEF context is ready.

#pragma once

#include "include/cef_app.h"

class BezierCefApp : public CefApp, public CefBrowserProcessHandler {
 public:
  BezierCefApp() = default;

  // CefApp methods:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  // CefBrowserProcessHandler methods:
  void OnContextInitialized() override;
  void OnScheduleMessagePumpWork(int64_t delay_ms) override;

 private:
  IMPLEMENT_REFCOUNTING(BezierCefApp);
};
