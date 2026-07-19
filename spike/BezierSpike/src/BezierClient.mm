#include "BezierClient.h"

#import <Cocoa/Cocoa.h>

#include "include/cef_app.h"
#include "include/wrapper/cef_helpers.h"

#import "CefBridge.h"

// Defined in main.mm. True when the app runs the external-pump configuration;
// false when it runs CefRunMessageLoop (--cef-loop).
extern bool g_use_external_pump;

namespace {

// [NSApp stop:] only takes effect once the run loop processes an event, so
// post a synthetic one to wake it.
void StopNSAppRunLoop() {
  if (!g_use_external_pump) {
    CefQuitMessageLoop();
    return;
  }
  [NSApp stop:nil];
  NSEvent* event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                      location:NSZeroPoint
                                 modifierFlags:0
                                     timestamp:0
                                  windowNumber:0
                                       context:nil
                                       subtype:0
                                         data1:0
                                         data2:0];
  [NSApp postEvent:event atStart:YES];
}

}  // namespace

void BezierClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  browsers_.push_back(browser);
}

bool BezierClient::DoClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  NSLog(@"[spike] DoClose (browsers=%zu)", browsers_.size());
  // Closing the last browser: allow the in-progress NSWindow close (the
  // NSWindowDelegate checks IsClosing) and let CEF destroy the browser view.
  if (browsers_.size() == 1) {
    is_closing_ = true;
  }
  return false;
}

void BezierClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  NSLog(@"[spike] OnBeforeClose (browsers=%zu)", browsers_.size());
  for (auto it = browsers_.begin(); it != browsers_.end(); ++it) {
    if ((*it)->IsSame(browser)) {
      browsers_.erase(it);
      break;
    }
  }
  if (browsers_.empty()) {
    StopNSAppRunLoop();
  }
}

void BezierClient::OnTitleChange(CefRefPtr<CefBrowser> browser,
                                 const CefString& title) {
  CEF_REQUIRE_UI_THREAD();
  if (CefBridge.shared.onTitleChange) {
    CefBridge.shared.onTitleChange(
        [NSString stringWithUTF8String:title.ToString().c_str()]);
  }
}

void BezierClient::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   const CefString& url) {
  CEF_REQUIRE_UI_THREAD();
  if (frame->IsMain() && CefBridge.shared.onAddressChange) {
    CefBridge.shared.onAddressChange(
        [NSString stringWithUTF8String:url.ToString().c_str()]);
  }
}

void BezierClient::CloseAllBrowsers(bool force_close) {
  CEF_REQUIRE_UI_THREAD();
  if (browsers_.empty()) {
    StopNSAppRunLoop();
    return;
  }
  for (auto& browser : browsers_) {
    browser->GetHost()->CloseBrowser(force_close);
  }
}

CefRefPtr<CefBrowser> BezierClient::GetFirstBrowser() {
  CEF_REQUIRE_UI_THREAD();
  if (browsers_.empty()) {
    return nullptr;
  }
  return browsers_.front();
}
