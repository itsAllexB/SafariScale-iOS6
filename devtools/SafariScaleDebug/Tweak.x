// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AllexB
//
// SafariScaleDebug (dev only): when com.itsallexb.safariscale.debug/run is posted, runs /tmp/ssdebug.js in
// the page Safari is showing and writes the result (or an error) to /tmp/ssdebug.out.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@interface WebView : NSObject
- (NSString *)stringByEvaluatingJavaScriptFromString:(NSString *)script;
@end

@interface UIWebDocumentView : UIView
- (WebView *)webView;
@end

// Every UIWebDocumentView in a window, depth first; the visible tab's is the one that is not hidden.
static void SDCollect(UIView *view, NSMutableArray *found, NSMutableString *trace, int depth) {
    if ([view isKindOfClass:objc_getClass("UIWebDocumentView")]) [found addObject:view];
    if (depth < 6) [trace appendFormat:@"%*s%@%@\n", depth * 2, "", NSStringFromClass([view class]), view.hidden ? @" (hidden)" : @""];
    for (UIView *sub in view.subviews) SDCollect(sub, found, trace, depth + 1);
}

static BOOL SDShown(UIView *view) {
    for (UIView *v = view; v; v = v.superview) if (v.hidden || v.alpha < 0.01) return NO;
    return view.window != nil;
}

// WebKit on iOS 6 runs WebCore on its own "WebThread". Anything that calls into WebKit from the
// main thread has to hold the WebThread lock first, as UIKit does, or WebCore may be in the middle of a
// layout. WebThreadLock() does nothing when already on the WebThread, and the main thread keeps the
// lock until the end of the current run loop pass.
// With Web Port, Safari has two WebCores loaded (Apple's and Web Port's in /var/wkd), each with its own
// WebThreadLock, and dlsym(RTLD_DEFAULT) finds Apple's. So the lock is taken from the WebCore next to
// the WebKit that the given object (a WebView or WebFrame) comes from.
static void SDWebThreadLockFor(id webKitObject) {
    static NSMutableDictionary *locks;   // WebKit image path -> lock function
    if (!webKitObject) return;
    Dl_info info;
    if (!dladdr((__bridge const void *)[webKitObject class], &info) || !info.dli_fname) return;
    NSString *kit = @(info.dli_fname);
    if (!locks) locks = [NSMutableDictionary dictionary];
    NSValue *cached = locks[kit];
    void (*lock)(void) = (void (*)(void))cached.pointerValue;
    if (!cached) {
        // .../WebKit.framework/WebKit or .../WebKitLegacy.framework/WebKitLegacy -> .../WebCore.framework/WebCore
        NSString *core = [[[kit stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
                          stringByAppendingPathComponent:@"WebCore.framework/WebCore"];
        void *image = dlopen(core.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
        lock = image ? (void (*)(void))dlsym(image, "WebThreadLock") : NULL;
        if (!lock) lock = (void (*)(void))dlsym(RTLD_DEFAULT, "WebThreadLock");
        locks[kit] = [NSValue valueWithPointer:(const void *)lock];
    }
    if (lock) lock();
}

static void SDRun(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *script = [NSString stringWithContentsOfFile:@"/tmp/ssdebug.js" encoding:NSUTF8StringEncoding error:NULL];
        NSMutableArray *found = [NSMutableArray array];
        NSMutableString *trace = [NSMutableString string];
        for (UIWindow *window in [UIApplication sharedApplication].windows) SDCollect(window, found, trace, 0);
        UIWebDocumentView *view = nil;
        for (UIWebDocumentView *candidate in found) if (SDShown(candidate)) { view = candidate; break; }
        NSString *result;
        if (!script) result = @"ERROR: no /tmp/ssdebug.js";
        else if (!view) result = [NSString stringWithFormat:@"ERROR: no visible web view (%lu found)\n%@", (unsigned long)found.count, trace];
        else {
            SDWebThreadLockFor([view webView]);
            result = [[view webView] stringByEvaluatingJavaScriptFromString:script] ?: @"(nil)";
        }
        [result writeToFile:@"/tmp/ssdebug.out" atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    });
}

%ctor {
    // Not in webbookmarksd, which shares Safari's bundle id.
    if (![[NSProcessInfo processInfo].processName isEqualToString:@"MobileSafari"]) return;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SDRun,
                                    CFSTR("com.itsallexb.safariscale.debug/run"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
