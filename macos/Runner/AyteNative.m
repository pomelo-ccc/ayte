#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CommonCrypto/CommonDigest.h>
#include <stdlib.h>
#include <string.h>

// ============================================================================
// AyteNative — macOS Native Bridge for Embedded Browser (WKWebView) and
// Computer Use (Permissions, Window Enumeration, Snapshot, Global Stop Hotkey,
// Floating Stop Bar).
//
// Compiled as a standalone dynamic library (libAyteNative.dylib) and loaded by
// Dart FFI. All returned char* strings are heap-allocated (strdup) and must be
// freed by the caller via AyteNativeFreeString.
// ============================================================================

static char *AyteCopyJSONString(id obj) {
  if (!obj) return strdup("{}");
  NSError *err = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&err];
  if (!data || err) return strdup("{}");
  NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return strdup(str ? [str UTF8String] : "{}");
}

static void AyteRunOnMainSync(dispatch_block_t block) {
  if ([NSThread isMainThread]) {
    block();
  } else {
    dispatch_sync(dispatch_get_main_queue(), block);
  }
}

void AyteNativeFreeString(char *ptr) {
  if (ptr) free(ptr);
}

// ============================================================================
// PART 1: EMBEDDED BROWSER (WKWebView)
// ============================================================================

@interface AyteWebTab : NSObject <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, copy) NSString *tabId;
@property (nonatomic, copy) NSString *profileId;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) NSWindow *detachedWindow;
@property (nonatomic, assign) BOOL detached;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, assign) BOOL googleSignInCompat;
@property (nonatomic, copy) NSString *defaultUserAgent;
@property (nonatomic, assign) NSRect lastFrame;
@end

static NSMutableDictionary<NSString *, AyteWebTab *> *gWebTabs = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *gJsResults = nil;
static NSObject *gJsLock = nil;
static NSString *const kFirefoxSignInUA =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:132.0) Gecko/20100101 Firefox/132.0";

static void AyteEnsureBrowserInit(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    gWebTabs = [NSMutableDictionary dictionary];
    gJsResults = [NSMutableDictionary dictionary];
    gJsLock = [[NSObject alloc] init];
  });
}

static NSUUID *AyteUUIDForProfile(NSString *profileId) {
  const char *utf8 = [profileId UTF8String];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(utf8, (CC_LONG)strlen(utf8), digest);
  // Set version 4 and variant bits for a deterministic valid UUID.
  digest[6] = (digest[6] & 0x0F) | 0x40;
  digest[8] = (digest[8] & 0x3F) | 0x80;
  return [[NSUUID alloc] initWithUUIDBytes:digest];
}

static WKWebsiteDataStore *AyteDataStoreForProfile(NSString *profileId) {
  if (!profileId || profileId.length == 0 || [profileId isEqualToString:@"default"]) {
    return [WKWebsiteDataStore defaultDataStore];
  }
  if (@available(macOS 14.0, *)) {
    NSUUID *uuid = AyteUUIDForProfile(profileId);
    return [WKWebsiteDataStore dataStoreForIdentifier:uuid];
  }
  return [WKWebsiteDataStore defaultDataStore];
}

static BOOL AyteIsGoogleSignInHost(NSString *host) {
  if (!host || host.length == 0) return NO;
  NSString *lower = host.lowercaseString;
  if ([lower isEqualToString:@"accounts.google.com"] ||
      [lower hasSuffix:@".accounts.google.com"] ||
      [lower isEqualToString:@"accounts.youtube.com"] ||
      [lower hasSuffix:@".accounts.youtube.com"]) {
    return YES;
  }
  const char *extra = getenv("AYTE_BROWSER_SIGN_IN_HOSTS");
  if (extra && extra[0] != '\0') {
    NSString *extraStr = [NSString stringWithUTF8String:extra];
    for (NSString *raw in [extraStr componentsSeparatedByString:@","]) {
      NSString *h = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
      if (h.length > 0 && ([lower isEqualToString:h] || [lower hasSuffix:[@"." stringByAppendingString:h]])) {
        return YES;
      }
    }
  }
  return NO;
}

static NSWindow *AyteFindHostWindow(void) {
  NSWindow *key = [NSApp keyWindow];
  if (key && key.contentView && ![key isKindOfClass:[NSPanel class]]) {
    return key;
  }
  NSWindow *main = [NSApp mainWindow];
  if (main && main.contentView && ![main isKindOfClass:[NSPanel class]]) {
    return main;
  }
  for (NSWindow *win in [NSApp windows]) {
    if (win.isVisible && win.contentView && ![win isKindOfClass:[NSPanel class]]) {
      // Skip our own detached browser windows
      BOOL isDetached = NO;
      for (AyteWebTab *tab in gWebTabs.allValues) {
        if (tab.detachedWindow == win) {
          isDetached = YES;
          break;
        }
      }
      if (!isDetached) return win;
    }
  }
  return nil;
}

@implementation AyteWebTab

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  NSURL *url = navigationAction.request.URL;
  NSString *scheme = url.scheme.lowercaseString;
  if (scheme && ![@[@"http", @"https", @"about", @"blob", @"data", @"file"] containsObject:scheme]) {
    [[NSWorkspace sharedWorkspace] openURL:url];
    decisionHandler(WKNavigationActionPolicyCancel);
    return;
  }
  if (self.googleSignInCompat && !self.detached) {
    if (AyteIsGoogleSignInHost(url.host)) {
      webView.customUserAgent = kFirefoxSignInUA;
    } else {
      webView.customUserAgent = self.defaultUserAgent;
    }
  }
  decisionHandler(WKNavigationActionPolicyAllow);
}

- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
  if (!navigationAction.targetFrame || !navigationAction.targetFrame.isMainFrame) {
    [webView loadRequest:navigationAction.request];
  }
  return nil;
}

- (void)webView:(WKWebView *)webView
    runJavaScriptAlertPanelWithMessage:(NSString *)message
                      initiatedByFrame:(WKFrameInfo *)frame
                     completionHandler:(void (^)(void))completionHandler {
  NSWindow *win = webView.window ?: AyteFindHostWindow();
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = message ?: @"";
  if (win) {
    [alert beginSheetModalForWindow:win completionHandler:^(NSModalResponse resp) {
      completionHandler();
    }];
  } else {
    [alert runModal];
    completionHandler();
  }
}

- (void)webView:(WKWebView *)webView
    runJavaScriptConfirmPanelWithMessage:(NSString *)message
                        initiatedByFrame:(WKFrameInfo *)frame
                       completionHandler:(void (^)(BOOL))completionHandler {
  NSWindow *win = webView.window ?: AyteFindHostWindow();
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = message ?: @"";
  [alert addButtonWithTitle:@"OK"];
  [alert addButtonWithTitle:@"Cancel"];
  if (win) {
    [alert beginSheetModalForWindow:win completionHandler:^(NSModalResponse resp) {
      completionHandler(resp == NSAlertFirstButtonReturn);
    }];
  } else {
    completionHandler([alert runModal] == NSAlertFirstButtonReturn);
  }
}

@end

int AyteWebViewCreate(const char *tabIdC,
                      const char *profileIdC,
                      const char *urlC,
                      int googleSignInCompat,
                      int inspectorEnabled,
                      int detached) {
  if (!tabIdC) return 0;
  NSString *tabId = [NSString stringWithUTF8String:tabIdC];
  NSString *profileId = profileIdC ? [NSString stringWithUTF8String:profileIdC] : @"default";
  NSString *urlStr = urlC ? [NSString stringWithUTF8String:urlC] : @"about:blank";
  __block int ok = 0;

  AyteRunOnMainSync(^{
    AyteEnsureBrowserInit();
    AyteWebTab *existing = gWebTabs[tabId];
    if (existing) {
      [existing.webView removeFromSuperview];
      [existing.detachedWindow close];
      [gWebTabs removeObjectForKey:tabId];
    }

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = AyteDataStoreForProfile(profileId);
    config.applicationNameForUserAgent = @"Version/17.5 Safari/605.1.15";
    @try {
      [config.preferences setValue:@(inspectorEnabled != 0) forKey:@"developerExtrasEnabled"];
    } @catch (NSException *ex) {
      // Ignore if KVC key unavailable on future macOS.
    }

    WKWebView *wv = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:config];
    if (@available(macOS 13.3, *)) {
      wv.inspectable = (inspectorEnabled != 0);
    }
    wv.wantsLayer = YES;
    wv.hidden = YES;

    AyteWebTab *tab = [[AyteWebTab alloc] init];
    tab.tabId = tabId;
    tab.profileId = profileId;
    tab.webView = wv;
    tab.detached = (detached != 0);
    tab.visible = NO;
    tab.googleSignInCompat = (googleSignInCompat != 0);
    tab.defaultUserAgent = nil;
    wv.navigationDelegate = tab;
    wv.UIDelegate = tab;

    if (tab.detached) {
      NSWindow *win = [[NSWindow alloc]
          initWithContentRect:NSMakeRect(120, 120, 1024, 720)
                    styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                               NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
                      backing:NSBackingStoreBuffered
                        defer:NO];
      win.title = @"Ayte Browser";
      win.releasedWhenClosed = NO;
      win.contentView = wv;
      wv.hidden = NO;
      tab.detachedWindow = win;
      [win makeKeyAndOrderFront:nil];
    } else {
      NSWindow *host = AyteFindHostWindow();
      if (host && host.contentView) {
        [host.contentView addSubview:wv positioned:NSWindowAbove relativeTo:nil];
      }
    }

    gWebTabs[tabId] = tab;

    NSURL *url = [NSURL URLWithString:urlStr];
    if (url) {
      if (url.isFileURL) {
        NSURL *dir = [url URLByDeletingLastPathComponent];
        [wv loadFileURL:url allowingReadAccessToURL:dir];
      } else {
        [wv loadRequest:[NSURLRequest requestWithURL:url]];
      }
    }
    ok = 1;
  });
  return ok;
}

void AyteWebViewSetFrame(const char *tabIdC,
                         double x,
                         double y,
                         double width,
                         double height,
                         int visible) {
  if (!tabIdC) return;
  NSString *tabId = [NSString stringWithUTF8String:tabIdC];
  dispatch_async(dispatch_get_main_queue(), ^{
    AyteEnsureBrowserInit();
    AyteWebTab *tab = gWebTabs[tabId];
    if (!tab || tab.detached) return;

    NSWindow *host = AyteFindHostWindow();
    if (!host || !host.contentView) return;

    if (tab.webView.superview != host.contentView) {
      [tab.webView removeFromSuperview];
      [host.contentView addSubview:tab.webView positioned:NSWindowAbove relativeTo:nil];
    }

    BOOL shouldShow = (visible != 0) && width > 4.0 && height > 4.0;
    tab.visible = shouldShow;
    tab.webView.hidden = !shouldShow;
    if (!shouldShow) return;

    // Convert Flutter logical coordinates (top-left origin inside contentView)
    // to AppKit coordinates (bottom-left origin unless contentView isFlipped).
    NSView *cv = host.contentView;
    CGFloat frameY = cv.isFlipped ? y : (cv.bounds.size.height - y - height);
    NSRect rect = NSMakeRect(floor(x), floor(frameY), ceil(width), ceil(height));
    if (!NSEqualRects(tab.lastFrame, rect)) {
      tab.lastFrame = rect;
      tab.webView.frame = rect;
    }
  });
}

void AyteWebViewNavigate(const char *tabIdC, const char *urlC) {
  if (!tabIdC || !urlC) return;
  NSString *tabId = [NSString stringWithUTF8String:tabIdC];
  NSString *urlStr = [NSString stringWithUTF8String:urlC];
  dispatch_async(dispatch_get_main_queue(), ^{
    AyteEnsureBrowserInit();
    AyteWebTab *tab = gWebTabs[tabId];
    if (!tab) return;
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    if (url.isFileURL) {
      NSURL *dir = [url URLByDeletingLastPathComponent];
      [tab.webView loadFileURL:url allowingReadAccessToURL:dir];
    } else {
      [tab.webView loadRequest:[NSURLRequest requestWithURL:url]];
    }
  });
}

void AyteWebViewAction(const char *tabIdC, const char *actionC) {
  if (!tabIdC || !actionC) return;
  NSString *tabId = [NSString stringWithUTF8String:tabIdC];
  NSString *action = [NSString stringWithUTF8String:actionC];
  dispatch_async(dispatch_get_main_queue(), ^{
    AyteEnsureBrowserInit();
    AyteWebTab *tab = gWebTabs[tabId];
    if (!tab) return;
    if ([action isEqualToString:@"back"]) {
      [tab.webView goBack];
    } else if ([action isEqualToString:@"forward"]) {
      [tab.webView goForward];
    } else if ([action isEqualToString:@"reload"]) {
      [tab.webView reload];
    } else if ([action isEqualToString:@"stop"]) {
      [tab.webView stopLoading];
    } else if ([action isEqualToString:@"detach"]) {
      if (!tab.detached) {
        tab.detached = YES;
        [tab.webView removeFromSuperview];
        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(120, 120, 1080, 740)
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        win.title = tab.webView.title.length > 0 ? tab.webView.title : @"Ayte Browser";
        win.releasedWhenClosed = NO;
        win.contentView = tab.webView;
        tab.webView.hidden = NO;
        tab.detachedWindow = win;
        [win makeKeyAndOrderFront:nil];
      } else if (tab.detachedWindow) {
        [tab.detachedWindow makeKeyAndOrderFront:nil];
      }
    } else if ([action isEqualToString:@"attach"]) {
      if (tab.detached) {
        tab.detached = NO;
        NSWindow *win = tab.detachedWindow;
        tab.detachedWindow = nil;
        [tab.webView removeFromSuperview];
        [win close];
        NSWindow *host = AyteFindHostWindow();
        if (host && host.contentView) {
          [host.contentView addSubview:tab.webView positioned:NSWindowAbove relativeTo:nil];
        }
        tab.lastFrame = NSZeroRect;
      }
    } else if ([action isEqualToString:@"inspector"]) {
      @try {
        id inspector = [tab.webView valueForKey:@"_inspector"];
        SEL showSel = NSSelectorFromString(@"show");
        if (inspector && [inspector respondsToSelector:showSel]) {
          #pragma clang diagnostic push
          #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
          [inspector performSelector:showSel];
          #pragma clang diagnostic pop
        }
      } @catch (NSException *ex) {
        // Private API best-effort fallback.
      }
    } else if ([action isEqualToString:@"close"]) {
      [tab.webView stopLoading];
      [tab.webView removeFromSuperview];
      if (tab.detachedWindow) {
        [tab.detachedWindow close];
        tab.detachedWindow = nil;
      }
      [gWebTabs removeObjectForKey:tabId];
    }
  });
}

void AyteWebViewHideAll(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    AyteEnsureBrowserInit();
    for (AyteWebTab *tab in gWebTabs.allValues) {
      if (!tab.detached) {
        tab.webView.hidden = YES;
        tab.visible = NO;
      }
    }
  });
}

char *AyteWebViewGetState(const char *tabIdC) {
  if (!tabIdC) return strdup("{}");
  NSString *tabId = [NSString stringWithUTF8String:tabIdC];
  __block char *out = NULL;
  AyteRunOnMainSync(^{
    AyteEnsureBrowserInit();
    AyteWebTab *tab = gWebTabs[tabId];
    if (!tab) {
      out = strdup("{\"exists\":false}");
      return;
    }
    NSDictionary *dict = @{
      @"exists": @YES,
      @"url": tab.webView.URL.absoluteString ?: @"",
      @"title": tab.webView.title ?: @"",
      @"loading": @(tab.webView.isLoading),
      @"canGoBack": @(tab.webView.canGoBack),
      @"canGoForward": @(tab.webView.canGoForward),
      @"progress": @(tab.webView.estimatedProgress),
      @"detached": @(tab.detached),
    };
    out = AyteCopyJSONString(dict);
  });
  return out ?: strdup("{}");
}

void AyteWebViewEvalJs(const char *tabIdC, const char *reqIdC, const char *scriptC) {
  if (!tabIdC || !reqIdC || !scriptC) return;
  NSString *tabId = [NSString stringWithUTF8String:tabIdC];
  NSString *reqId = [NSString stringWithUTF8String:reqIdC];
  NSString *script = [NSString stringWithUTF8String:scriptC];
  dispatch_async(dispatch_get_main_queue(), ^{
    AyteEnsureBrowserInit();
    AyteWebTab *tab = gWebTabs[tabId];
    if (!tab) {
      @synchronized(gJsLock) {
        gJsResults[reqId] = @{@"done": @YES, @"error": @"Tab not found"};
      }
      return;
    }
    [tab.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
      NSMutableDictionary *payload = [NSMutableDictionary dictionary];
      payload[@"done"] = @YES;
      if (error) {
        payload[@"error"] = error.localizedDescription ?: @"JavaScript error";
      } else if (result == nil || result == [NSNull null]) {
        payload[@"value"] = @"";
      } else if ([result isKindOfClass:[NSString class]]) {
        payload[@"value"] = result;
      } else if ([NSJSONSerialization isValidJSONObject:result]) {
        NSError *jerr = nil;
        NSData *jdata = [NSJSONSerialization dataWithJSONObject:result options:0 error:&jerr];
        payload[@"value"] = jdata ? [[NSString alloc] initWithData:jdata encoding:NSUTF8StringEncoding] : [result description];
      } else {
        payload[@"value"] = [result description];
      }
      @synchronized(gJsLock) {
        gJsResults[reqId] = payload;
      }
    }];
  });
}

void AyteWebViewTakeSnapshot(const char *tabIdC, const char *reqIdC, const char *outputPathC) {
  if (!tabIdC || !reqIdC || !outputPathC) return;
  NSString *tabId = [NSString stringWithUTF8String:tabIdC];
  NSString *reqId = [NSString stringWithUTF8String:reqIdC];
  NSString *outputPath = [NSString stringWithUTF8String:outputPathC];
  dispatch_async(dispatch_get_main_queue(), ^{
    AyteEnsureBrowserInit();
    AyteWebTab *tab = gWebTabs[tabId];
    if (!tab) {
      @synchronized(gJsLock) {
        gJsResults[reqId] = @{@"done": @YES, @"error": @"Tab not found"};
      }
      return;
    }
    WKSnapshotConfiguration *cfg = [[WKSnapshotConfiguration alloc] init];
    [tab.webView takeSnapshotWithConfiguration:cfg completionHandler:^(NSImage *image, NSError *error) {
      NSMutableDictionary *payload = [NSMutableDictionary dictionary];
      payload[@"done"] = @YES;
      if (error || !image) {
        payload[@"error"] = error.localizedDescription ?: @"Snapshot failed";
      } else {
        NSData *tiff = [image TIFFRepresentation];
        NSBitmapImageRep *rep = tiff ? [NSBitmapImageRep imageRepWithData:tiff] : nil;
        NSData *png = rep ? [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
        if (png && [png writeToFile:outputPath atomically:YES]) {
          payload[@"value"] = outputPath;
        } else {
          payload[@"error"] = @"Failed to write PNG snapshot";
        }
      }
      @synchronized(gJsLock) {
        gJsResults[reqId] = payload;
      }
    }];
  });
}

char *AyteWebViewPollResult(const char *reqIdC) {
  if (!reqIdC) return strdup("{\"done\":false}");
  AyteEnsureBrowserInit();
  NSString *reqId = [NSString stringWithUTF8String:reqIdC];
  NSDictionary *found = nil;
  @synchronized(gJsLock) {
    found = gJsResults[reqId];
    if (found) {
      [gJsResults removeObjectForKey:reqId];
    }
  }
  if (!found) return strdup("{\"done\":false}");
  return AyteCopyJSONString(found);
}

void AyteWebViewClearProfile(const char *profileIdC) {
  NSString *profileId = profileIdC ? [NSString stringWithUTF8String:profileIdC] : @"default";
  dispatch_async(dispatch_get_main_queue(), ^{
    WKWebsiteDataStore *store = AyteDataStoreForProfile(profileId);
    NSSet<NSString *> *types = [WKWebsiteDataStore allWebsiteDataTypes];
    [store removeDataOfTypes:types modifiedSince:[NSDate dateWithTimeIntervalSince1970:0] completionHandler:^{}];
  });
}

// ============================================================================
// PART 2: COMPUTER USE NATIVE HELPER
// (Permissions, Window List, Window Capture, Global Stop Hotkey, Stop Bar)
// ============================================================================

static EventHotKeyRef gCuStopHotKeyRef = NULL;
static EventHandlerRef gCuHotKeyHandlerRef = NULL;
static volatile int gCuStopTriggered = 0;
static NSPanel *gCuStopBarPanel = nil;
static NSTextField *gCuStopBarLabel = nil;

@interface AyteStopBarTarget : NSObject
- (void)onStopClicked:(id)sender;
@end

@implementation AyteStopBarTarget
- (void)onStopClicked:(id)sender {
  gCuStopTriggered = 1;
  if (gCuStopBarPanel) {
    [gCuStopBarPanel orderOut:nil];
  }
}
@end

static AyteStopBarTarget *gCuStopBarTarget = nil;

static OSStatus AyteCuHotKeyHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
  EventHotKeyID hotKeyId;
  OSStatus err = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                   NULL, sizeof(hotKeyId), NULL, &hotKeyId);
  if (err == noErr && hotKeyId.signature == 'ACUS' && hotKeyId.id == 1) {
    gCuStopTriggered = 1;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (gCuStopBarPanel) {
        [gCuStopBarPanel orderOut:nil];
      }
    });
  }
  return noErr;
}

char *AyteCuCheckPermissions(void) {
  BOOL ax = AXIsProcessTrusted();
  BOOL sr = NO;
  if (@available(macOS 10.15, *)) {
    sr = CGPreflightScreenCaptureAccess();
  } else {
    sr = YES;
  }
  NSDictionary *dict = @{
    @"accessibility": @(ax),
    @"screenRecording": @(sr),
    @"pid": @([[NSProcessInfo processInfo] processIdentifier]),
    @"bundleId": ([[NSBundle mainBundle] bundleIdentifier] ?: @"dev.ayte.desktop"),
  };
  return AyteCopyJSONString(dict);
}

int AyteCuRequestAccessibility(void) {
  NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
  return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts) ? 1 : 0;
}

int AyteCuRequestScreenRecording(void) {
  if (@available(macOS 10.15, *)) {
    return CGRequestScreenCaptureAccess() ? 1 : 0;
  }
  return 1;
}

void AyteCuOpenPrivacyPane(const char *paneC) {
  NSString *pane = paneC ? [NSString stringWithUTF8String:paneC] : @"accessibility";
  NSString *urlStr = [pane isEqualToString:@"screenRecording"]
      ? @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
      : @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
  NSURL *url = [NSURL URLWithString:urlStr];
  if (url) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [[NSWorkspace sharedWorkspace] openURL:url];
    });
  }
}

char *AyteCuListWindows(void) {
  CFArrayRef list = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
      kCGNullWindowID);
  if (!list) return strdup("[]");

  pid_t selfPid = [[NSProcessInfo processInfo] processIdentifier];
  NSString *selfBundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"dev.ayte.desktop";
  NSMutableDictionary<NSNumber *, NSRunningApplication *> *appCache = [NSMutableDictionary dictionary];
  NSMutableArray *result = [NSMutableArray array];

  CFIndex count = CFArrayGetCount(list);
  for (CFIndex i = 0; i < count; i++) {
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
    NSNumber *layer = info[(__bridge NSString *)kCGWindowLayer];
    if (layer && layer.intValue != 0) continue; // Only normal application windows.

    NSNumber *wid = info[(__bridge NSString *)kCGWindowNumber];
    NSNumber *pidNum = info[(__bridge NSString *)kCGWindowOwnerPID];
    if (!wid || !pidNum) continue;

    NSDictionary *boundsDict = info[(__bridge NSString *)kCGWindowBounds];
    CGRect bounds = CGRectZero;
    if (boundsDict) {
      CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDict, &bounds);
    }
    if (bounds.size.width < 60 || bounds.size.height < 40) continue;

    NSString *ownerName = info[(__bridge NSString *)kCGWindowOwnerName] ?: @"";
    NSString *title = info[(__bridge NSString *)kCGWindowName] ?: @"";
    if ([ownerName isEqualToString:@"WindowManager"] ||
        [ownerName isEqualToString:@"cua-driver"] ||
        [ownerName isEqualToString:@"CuaDriver"] ||
        [ownerName isEqualToString:@"Control Center"] ||
        [ownerName isEqualToString:@"Dock"]) {
      continue;
    }

    NSRunningApplication *app = appCache[pidNum];
    if (!app) {
      app = [NSRunningApplication runningApplicationWithProcessIdentifier:pidNum.intValue];
      if (app) appCache[pidNum] = app;
    }
    NSString *bundleId = app.bundleIdentifier ?: @"";
    NSString *execPath = app.executableURL.path ?: @"";
    BOOL isSelf = (pidNum.intValue == selfPid) ||
                  (bundleId.length > 0 && [bundleId isEqualToString:selfBundle]);

    [result addObject:@{
      @"windowId": wid,
      @"pid": pidNum,
      @"appName": ownerName,
      @"bundleId": bundleId,
      @"execPath": execPath,
      @"title": title,
      @"x": @(bounds.origin.x),
      @"y": @(bounds.origin.y),
      @"width": @(bounds.size.width),
      @"height": @(bounds.size.height),
      @"isSelf": @(isSelf),
    }];
  }

  CFRelease(list);
  return AyteCopyJSONString(result);
}

int AyteCuCaptureWindow(int windowId, const char *outputPathC) {
  if (!outputPathC || windowId <= 0) return 0;
  NSString *path = [NSString stringWithUTF8String:outputPathC];
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
  task.arguments = @[@"-x", @"-o", @"-l", [NSString stringWithFormat:@"%d", windowId], path];
  NSError *err = nil;
  if (![task launchAndReturnError:&err]) return 0;
  [task waitUntilExit];
  return (task.terminationStatus == 0 && [[NSFileManager defaultManager] fileExistsAtPath:path]) ? 1 : 0;
}

int AyteCuRegisterStopHotkey(int keyCode, int carbonModifiers) {
  __block int ok = 0;
  AyteRunOnMainSync(^{
    if (gCuStopHotKeyRef) {
      UnregisterEventHotKey(gCuStopHotKeyRef);
      gCuStopHotKeyRef = NULL;
    }
    if (!gCuHotKeyHandlerRef) {
      EventTypeSpec spec;
      spec.eventClass = kEventClassKeyboard;
      spec.eventKind = kEventHotKeyPressed;
      InstallApplicationEventHandler(&AyteCuHotKeyHandler, 1, &spec, NULL, &gCuHotKeyHandlerRef);
    }
    EventHotKeyID hotKeyId;
    hotKeyId.signature = 'ACUS';
    hotKeyId.id = 1;
    OSStatus status = RegisterEventHotKey(
        (UInt32)keyCode,
        (UInt32)carbonModifiers,
        hotKeyId,
        GetApplicationEventTarget(),
        0,
        &gCuStopHotKeyRef);
    ok = (status == noErr) ? 1 : 0;
  });
  return ok;
}

void AyteCuUnregisterStopHotkey(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (gCuStopHotKeyRef) {
      UnregisterEventHotKey(gCuStopHotKeyRef);
      gCuStopHotKeyRef = NULL;
    }
  });
}

int AyteCuPollStopEvent(void) {
  if (gCuStopTriggered) {
    gCuStopTriggered = 0;
    return 1;
  }
  return 0;
}

void AyteCuShowStopBar(const char *statusTextC, const char *stopLabelC) {
  NSString *statusText = statusTextC ? [NSString stringWithUTF8String:statusTextC] : @"Ayte Computer Use Active";
  NSString *stopLabel = stopLabelC ? [NSString stringWithUTF8String:stopLabelC] : @"Stop Sharing";
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!gCuStopBarTarget) {
      gCuStopBarTarget = [[AyteStopBarTarget alloc] init];
    }
    if (!gCuStopBarPanel) {
      CGFloat width = 460.0;
      CGFloat height = 40.0;
      NSScreen *screen = [NSScreen mainScreen];
      NSRect sf = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
      NSRect frame = NSMakeRect(
          sf.origin.x + (sf.size.width - width) / 2.0,
          sf.origin.y + sf.size.height - height - 14.0,
          width,
          height);

      NSPanel *panel = [[NSPanel alloc]
          initWithContentRect:frame
                    styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                      backing:NSBackingStoreBuffered
                        defer:NO];
      panel.level = NSStatusWindowLevel;
      panel.opaque = NO;
      panel.backgroundColor = [NSColor clearColor];
      panel.hasShadow = YES;
      panel.movableByWindowBackground = YES;
      panel.collectionBehavior =
          NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

      NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
      bg.material = NSVisualEffectMaterialHUDWindow;
      bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
      bg.state = NSVisualEffectStateActive;
      bg.wantsLayer = YES;
      bg.layer.cornerRadius = 20.0;
      bg.layer.masksToBounds = YES;
      bg.layer.borderWidth = 1.0;
      bg.layer.borderColor = [[NSColor colorWithRed:0.95 green:0.35 blue:0.30 alpha:0.65] CGColor];

      NSView *dot = [[NSView alloc] initWithFrame:NSMakeRect(16, 15, 10, 10)];
      dot.wantsLayer = YES;
      dot.layer.cornerRadius = 5.0;
      dot.layer.backgroundColor = [[NSColor colorWithRed:0.96 green:0.30 blue:0.26 alpha:1.0] CGColor];
      [bg addSubview:dot];

      NSTextField *label = [NSTextField labelWithString:statusText];
      label.frame = NSMakeRect(34, 10, width - 150, 20);
      label.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
      label.textColor = [NSColor whiteColor];
      label.lineBreakMode = NSLineBreakByTruncatingTail;
      [bg addSubview:label];
      gCuStopBarLabel = label;

      NSButton *btn = [NSButton buttonWithTitle:stopLabel
                                         target:gCuStopBarTarget
                                         action:@selector(onStopClicked:)];
      btn.frame = NSMakeRect(width - 108, 7, 96, 26);
      btn.bezelStyle = NSBezelStyleRounded;
      btn.contentTintColor = [NSColor colorWithRed:1.0 green:0.42 blue:0.38 alpha:1.0];
      btn.tag = 101;
      [bg addSubview:btn];

      panel.contentView = bg;
      gCuStopBarPanel = panel;
    }

    gCuStopBarLabel.stringValue = statusText;
    NSButton *btn = [gCuStopBarPanel.contentView viewWithTag:101];
    if ([btn isKindOfClass:[NSButton class]]) {
      btn.title = stopLabel;
    }
    [gCuStopBarPanel orderFrontRegardless];
  });
}

void AyteCuHideStopBar(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (gCuStopBarPanel) {
      [gCuStopBarPanel orderOut:nil];
    }
  });
}
