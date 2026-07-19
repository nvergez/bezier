// External message pump for CEF on macOS, ported from cefclient's
// tests/shared/browser/main_message_loop_external_pump{.cc,_mac.mm}.
// AppKit owns [NSApp run]; CEF requests work via OnScheduleMessagePumpWork and
// we call CefDoMessageLoopWork() on the main thread from a one-shot NSTimer
// registered in both NSRunLoopCommonModes and NSEventTrackingRunLoopMode (so
// the browser keeps painting during live window resize and menu tracking).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BezierMessagePump : NSObject

@property(class, readonly, strong) BezierMessagePump *shared;

/// Called from CefBrowserProcessHandler::OnScheduleMessagePumpWork.
/// May be called on any thread.
- (void)scheduleWork:(int64_t)delayMs;

/// Invalidate any pending timer (after [NSApp run] returns, before shutdown).
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
