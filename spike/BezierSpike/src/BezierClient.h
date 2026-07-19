// Minimal CefClient modeled on cefsimple's SimpleHandler.

#pragma once

#include <list>

#include "include/cef_client.h"

class BezierClient : public CefClient,
                     public CefLifeSpanHandler,
                     public CefDisplayHandler {
 public:
  BezierClient() = default;

  // CefClient methods:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }

  // CefLifeSpanHandler methods:
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  // CefDisplayHandler methods:
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override;
  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override;

  void CloseAllBrowsers(bool force_close);
  bool IsClosing() const { return is_closing_; }
  CefRefPtr<CefBrowser> GetFirstBrowser();

 private:
  std::list<CefRefPtr<CefBrowser>> browsers_;
  bool is_closing_ = false;

  IMPLEMENT_REFCOUNTING(BezierClient);
};
