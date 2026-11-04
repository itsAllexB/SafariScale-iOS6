// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB
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

static void SDRun(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        void (*lock)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "WebThreadLock");
        if (lock) lock();
        NSString *script = [NSString stringWithContentsOfFile:@"/tmp/ssdebug.js" encoding:NSUTF8StringEncoding error:NULL];
        NSMutableArray *found = [NSMutableArray array];
        NSMutableString *trace = [NSMutableString string];
        for (UIWindow *window in [UIApplication sharedApplication].windows) SDCollect(window, found, trace, 0);
        UIWebDocumentView *view = nil;
        for (UIWebDocumentView *candidate in found) if (SDShown(candidate)) { view = candidate; break; }
        NSString *result;
        if (!script) result = @"ERROR: no /tmp/ssdebug.js";
        else if (!view) result = [NSString stringWithFormat:@"ERROR: no visible web view (%lu found)\n%@", (unsigned long)found.count, trace];
        else result = [[view webView] stringByEvaluatingJavaScriptFromString:script] ?: @"(nil)";
        [result writeToFile:@"/tmp/ssdebug.out" atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    });
}

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SDRun,
                                    CFSTR("com.itsallexb.safariscale.debug/run"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
