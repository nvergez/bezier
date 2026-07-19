#import "CefBridge.h"

#include "include/cef_browser.h"
#include "include/internal/cef_types_mac.h"

#include "BezierClient.h"

@implementation CefBridge {
  BOOL _cefReady;
  NSView *_pendingView;
  NSString *_pendingURL;
  CefRefPtr<BezierClient> _client;
}

+ (CefBridge *)shared {
  static CefBridge *bridge;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    bridge = [[CefBridge alloc] init];
  });
  return bridge;
}

- (instancetype)init {
  if (self = [super init]) {
    _client = new BezierClient();
    _initialURL = @"https://example.com";
  }
  return self;
}

- (BOOL)isClosing {
  return _client->IsClosing();
}

- (void)markCefReady {
  _cefReady = YES;
  if (_pendingView != nil) {
    NSView *view = _pendingView;
    NSString *url = _pendingURL;
    _pendingView = nil;
    _pendingURL = nil;
    [self createBrowserInView:view url:url];
  }
}

- (void)createBrowserInView:(NSView *)view url:(NSString *)url {
  if (!_cefReady) {
    _pendingView = view;
    _pendingURL = url;
    return;
  }

  // The embed under test: Alloy-style browser parented into an app-owned
  // NSView. parent_view forces Alloy style on macOS; set it explicitly too.
  CefWindowInfo window_info;
  NSRect bounds = view.bounds;
  CefRect rect(0, 0, static_cast<int>(bounds.size.width),
               static_cast<int>(bounds.size.height));
  window_info.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(view), rect);
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  CefBrowserSettings browser_settings;
  CefBrowserHost::CreateBrowser(window_info, _client,
                                CefString(url.UTF8String), browser_settings,
                                nullptr, nullptr);
}

- (void)loadURL:(NSString *)url {
  CefRefPtr<CefBrowser> browser = _client->GetFirstBrowser();
  if (browser) {
    browser->GetMainFrame()->LoadURL(CefString(url.UTF8String));
  }
}

- (void)closeAllBrowsers:(BOOL)force {
  _client->CloseAllBrowsers(force);
}

@end
