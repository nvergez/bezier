#import "BezierMessagePump.h"

#import <AppKit/AppKit.h>

#include <climits>

#include "include/cef_app.h"

// Special delay placeholder used by DoWork to request "the maximum idle
// delay" without clobbering an already-pending shorter timer.
static const int64_t kTimerDelayPlaceholder = INT_MAX;

// Maximum wait between CefDoMessageLoopWork() calls while idle. cefclient
// ships 1000/30 (30 fps); the research doc flags that as too coarse for a
// 120 Hz-feeling app, so we use ~8 ms (125 Hz). CEF usually asks for work
// sooner via OnScheduleMessagePumpWork; this is only the idle ceiling.
static const int64_t kMaxTimerDelay = 8;

@implementation BezierMessagePump {
  NSTimer *_timer;      // pending work timer (main thread only)
  BOOL _isActive;       // inside CefDoMessageLoopWork
  BOOL _reentrancyDetected;
}

+ (BezierMessagePump *)shared {
  static BezierMessagePump *pump;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    pump = [[BezierMessagePump alloc] init];
  });
  return pump;
}

- (void)scheduleWork:(int64_t)delayMs {
  // Marshal to the main thread. performSelectorOnMainThread queues async even
  // when already on the main thread, matching the sample's semantics.
  [self performSelectorOnMainThread:@selector(handleScheduleWork:)
                         withObject:@(delayMs)
                      waitUntilDone:NO];
}

- (void)shutdown {
  [self killTimer];
}

#pragma mark - Main-thread internals

- (void)handleScheduleWork:(NSNumber *)delayNumber {
  int64_t delayMs = delayNumber.longLongValue;

  if (delayMs == kTimerDelayPlaceholder && _timer != nil) {
    // Don't replace a shorter in-flight timer with the idle maximum.
    return;
  }

  [self killTimer];

  if (delayMs <= 0) {
    [self doWork];
  } else {
    if (delayMs > kMaxTimerDelay) {
      delayMs = kMaxTimerDelay;
    }
    [self setTimer:delayMs];
  }
}

- (void)timerFired:(NSTimer *)timer {
  [self killTimer];
  [self doWork];
}

- (void)doWork {
  const BOOL wasReentrant = [self performMessageLoopWork];
  if (wasReentrant) {
    // Execute the remaining work as soon as possible.
    [self scheduleWork:0];
  } else if (_timer == nil) {
    [self scheduleWork:kTimerDelayPlaceholder];
  }
}

- (BOOL)performMessageLoopWork {
  if (_isActive) {
    // CefDoMessageLoopWork triggered a nested call (paint/IPC callbacks).
    // Flag it so the discarded call is re-posted.
    _reentrancyDetected = YES;
    return NO;
  }

  _reentrancyDetected = NO;
  _isActive = YES;
  CefDoMessageLoopWork();
  _isActive = NO;

  return _reentrancyDetected;
}

- (void)setTimer:(int64_t)delayMs {
  _timer = [NSTimer timerWithTimeInterval:(double)delayMs / 1000.0
                                   target:self
                                 selector:@selector(timerFired:)
                                 userInfo:nil
                                  repeats:NO];
  NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
  [runLoop addTimer:_timer forMode:NSRunLoopCommonModes];
  [runLoop addTimer:_timer forMode:NSEventTrackingRunLoopMode];
}

- (void)killTimer {
  if (_timer != nil) {
    [_timer invalidate];
    _timer = nil;
  }
}

@end
