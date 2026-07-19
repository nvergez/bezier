// Pure Objective-C facade over the CEF C++ API. This header is imported into
// Swift as the bridging header, so it must not include any C++ or CEF headers.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface CefBridge : NSObject

@property(class, readonly, strong) CefBridge *shared;

/// Initial URL parsed from the command line (set by main() before UI creation).
@property(nonatomic, copy) NSString *initialURL;

/// UI callbacks, set by Swift. Invoked on the main thread (which is also the
/// CEF UI thread in this single-threaded macOS configuration).
@property(nonatomic, copy, nullable) void (^onTitleChange)(NSString *title);
@property(nonatomic, copy, nullable) void (^onAddressChange)(NSString *url);

/// True once browser close-down has started; NSWindowDelegate uses this to
/// allow the in-progress window close (see cefsimple's is_closing flag).
@property(nonatomic, readonly) BOOL isClosing;

/// Create the CEF browser as a child of |view| — the Alloy-style
/// CefWindowInfo.SetAsChild(parent_view) embed under test. Safe to call before
/// CEF finishes initializing; the request is queued until OnContextInitialized.
- (void)createBrowserInView:(NSView *)view url:(NSString *)url;

- (void)loadURL:(NSString *)url;

/// Tell CEF the browser gained/lost input focus (overlay spike: hand keyboard
/// focus back to web content after a native overlay had it).
- (void)focusBrowser;
- (void)unfocusBrowser;

/// Begin closing all browsers. When the last browser is gone the NSApp run
/// loop is stopped and main() proceeds to CefShutdown.
- (void)closeAllBrowsers:(BOOL)force;

/// Called from CefApp::OnContextInitialized. Not for UI use.
- (void)markCefReady;

@end

NS_ASSUME_NONNULL_END
