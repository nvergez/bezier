// Browser-process entry point, modeled on cefsimple_mac.mm — but with the
// external message pump (AppKit owns [NSApp run]) and a Swift AppDelegate.

#import <Cocoa/Cocoa.h>

#include "include/base/cef_logging.h"
#include "include/cef_application_mac.h"
#include "include/cef_command_line.h"
#include "include/wrapper/cef_library_loader.h"

#include "BezierCefApp.h"
#import "BezierMessagePump.h"
#import "CefBridge.h"

// NSApplication subclass implementing CefAppProtocol, required by Chromium's
// event handling on macOS.
@interface BezierApplication : NSApplication <CefAppProtocol> {
 @private
  BOOL handlingSendEvent_;
}
@end

@implementation BezierApplication

- (BOOL)isHandlingSendEvent {
  return handlingSendEvent_;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  handlingSendEvent_ = handlingSendEvent;
}

- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}

// Route orderly-quit paths (Cmd+Q, Dock menu, logout) through browser
// close-down instead of exit(); see the long comment in cefsimple_mac.mm.
- (void)terminate:(id)sender {
  [CefBridge.shared closeAllBrowsers:NO];
  // Return, don't exit. OnBeforeClose of the last browser stops the run loop.
}

@end

// True when running the external-pump configuration (the default). The
// --cef-loop switch flips to CefRunMessageLoop for A/B comparison.
bool g_use_external_pump = true;

int main(int argc, char* argv[]) {
  // Load the CEF framework library at runtime instead of linking directly
  // as required by the macOS sandbox implementation.
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInMain()) {
    return 1;
  }

  CefMainArgs main_args(argc, argv);

  @autoreleasepool {
    [BezierApplication sharedApplication];
    CHECK([NSApp isKindOfClass:[BezierApplication class]]);

    CefRefPtr<CefCommandLine> command_line =
        CefCommandLine::CreateCommandLine();
    command_line->InitFromArgv(argc, argv);

    if (command_line->HasSwitch("cef-loop")) {
      g_use_external_pump = false;
    }

    CefSettings settings;
    // AppKit owns the run loop; CEF requests work via
    // OnScheduleMessagePumpWork (multi_threaded_message_loop is not supported
    // on macOS). With --cef-loop, CEF spins NSApplication itself instead
    // (cefsimple-style CefRunMessageLoop).
    settings.external_message_pump = g_use_external_pump;
#if !defined(CEF_USE_SANDBOX)
    settings.no_sandbox = true;
#endif
    // Note: only cache_path, like cefclient's --cache-path. Setting
    // root_cache_path to the same directory reproducibly wedged navigation
    // (page target never committed); see the evidence doc's friction log.
    if (command_line->HasSwitch("cache-path")) {
      CefString(&settings.cache_path) =
          command_line->GetSwitchValue("cache-path");
    }
    if (command_line->HasSwitch("remote-debugging-port")) {
      settings.remote_debugging_port = std::stoi(
          command_line->GetSwitchValue("remote-debugging-port").ToString());
    }
    if (command_line->HasSwitch("url")) {
      CefBridge.shared.initialURL = [NSString
          stringWithUTF8String:command_line->GetSwitchValue("url")
                                   .ToString()
                                   .c_str()];
    }

    CefRefPtr<BezierCefApp> app(new BezierCefApp);
    if (!CefInitialize(main_args, settings, app.get(), nullptr)) {
      return CefGetExitCode();
    }

    // The AppDelegate is implemented in Swift (BezierUI static library) and
    // only referenced by name here — the library is linked with -force_load
    // so the class is registered with the ObjC runtime.
    Class delegateClass = NSClassFromString(@"BZAppDelegate");
    CHECK(delegateClass != nil);
    id<NSApplicationDelegate> delegate = [[delegateClass alloc] init];
    NSApp.delegate = delegate;

    if (g_use_external_pump) {
      // AppKit owns the message loop. Returns after [NSApp stop:] when the
      // last browser has closed.
      [NSApp run];

      // Drain remaining CEF work before shutdown (no "pump until idle" API);
      // same approach as cefclient's external pump sample.
      [BezierMessagePump.shared shutdown];
      for (int i = 0; i < 10; ++i) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, 1);
        CefDoMessageLoopWork();
        [NSThread sleepForTimeInterval:0.05];
      }
    } else {
      // CEF owns the loop; returns after CefQuitMessageLoop().
      CefRunMessageLoop();
    }

    CefShutdown();
    delegate = nil;
  }

  return 0;
}
