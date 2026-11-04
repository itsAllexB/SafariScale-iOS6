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

static UIView *SDVisibleDocumentView(UIView *view) {
    if (view.hidden || view.alpha < 0.01) return nil;
    for (UIView *sub in [view.subviews reverseObjectEnumerator]) {
        UIView *found = SDVisibleDocumentView(sub);
        if (found) return found;
    }
    return [view isKindOfClass:objc_getClass("UIWebDocumentView")] ? view : nil;
}

static void SDRun(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        void (*lock)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "WebThreadLock");
        if (lock) lock();
        NSString *script = [NSString stringWithContentsOfFile:@"/tmp/ssdebug.js" encoding:NSUTF8StringEncoding error:NULL];
        UIWebDocumentView *view = (UIWebDocumentView *)SDVisibleDocumentView([UIApplication sharedApplication].keyWindow);
        NSString *result;
        if (!script) result = @"ERROR: no /tmp/ssdebug.js";
        else if (!view) result = @"ERROR: no visible web view";
        else result = [[view webView] stringByEvaluatingJavaScriptFromString:script] ?: @"(nil)";
        [result writeToFile:@"/tmp/ssdebug.out" atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    });
}

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SDRun,
                                    CFSTR("com.itsallexb.safariscale.debug/run"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
