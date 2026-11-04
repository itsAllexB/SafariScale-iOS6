// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// SafariScale 1.0.0
// Makes web pages in Safari (iOS 6 and 7) smaller, like zooming out in a desktop browser.
//
// How Safari sizes a page (UIKit, iOS 6.1.3, checked on an iPhone 4S):
//   WebKit parses <meta name="viewport"> and hands UIKit a dictionary:
//     -[UIWebDocumentView webView:didReceiveViewportArguments:forFrame:]
//       -> -[UIWebDocumentView _applyViewportArguments:]   (returns a mask of what changed)
//   keys: width, height, initial-scale, minimum-scale, maximum-scale, user-scalable.
//   -1 means "not set". Apple's WebKit has already turned width=device-width into the screen width
//   in points (320 on iPhone, 768 on iPad). Web Port's modern WebKit may pass -2 / -3 instead
//   (WebCore's ValueDeviceWidth / ValueDeviceHeight), so both forms are handled.
//
// What SafariScale changes, for pages that size themselves to the device (width=device-width,
// or only an initial-scale), at scale s (0.5 ... 1.0):
//   width  -> device width / s      (320 pt at 80% becomes a 400 CSS px wide layout)
//   height -> device height / s     (only when it is device-height)
//   initial-, minimum- and maximum-scale -> value * s
// So the page lays out wider and is shown at s. Everything stays real: media queries, window.innerWidth,
// fixed elements, forms, pinch zoom and rotation all see a normal, wider viewport. It's what desktop
// browsers do when you zoom out. Pages with a fixed pixel width (width=600) and desktop pages with no
// viewport tag are left alone: Safari already fits those to the screen.
//
// Hooking _applyViewportArguments: rather than the delegate method means it works with Apple's WebKit
// and with Web Port's (which installs its own handler for the delegate method), whatever order the
// tweaks load in.
//
// Text autosizing: iOS enlarges text that would be too small to read in the visible width. Safari tells
// WebKit that width on every load with -[WebFrame _setTextAutosizingWidth:] (320 on an iPhone). With the
// page laid out 400 px wide, 320 would make WebKit inflate the text again (Hacker News: 15 px became
// 17 px at 80%), undoing the change. So for scaled pages that width is divided by s as well: autosizing
// then works on the page exactly as it does at 100%.
//
// Settings changes: the original arguments of every page we scaled are kept on its view. When Safari
// comes back to the front after a change, they're applied again, so open pages update in place
// without reloading (form contents and scroll position are kept).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <substrate.h>

#define kSSDomain CFSTR("com.itsallexb.safariscale")
#define kSSNotification "com.itsallexb.safariscale/prefschanged"
static NSString *const kSSPrefsPath = @"/var/mobile/Library/Preferences/com.itsallexb.safariscale.plist";
static NSString *const kSSScaledMarker = @"com.itsallexb.safariscale.scaled";   // set on dictionaries we made

@interface WebFrame : NSObject
- (void)_setTextAutosizingWidth:(float)width;
@end

@interface WebView : NSObject
- (WebFrame *)mainFrame;
@end

@interface UIWebDocumentView : UIView
- (WebView *)webView;
- (unsigned int)_applyViewportArguments:(NSDictionary *)arguments;
- (void)viewportConfigurationsDidChange:(unsigned int)mask;
@end

#pragma mark - Preferences

static BOOL gEnabled = YES;
static NSInteger gPercent = 80;
static BOOL gNeedsReapply = NO;

static CGFloat SSScale(void) {
    return gEnabled ? gPercent / 100.0 : 1.0;
}

static void SSLoadPreferences(void) {
    // Read the plist the Settings pane writes; CFPreferences is only the fallback when there is no file yet.
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:kSSPrefsPath];
    id enabled = file ? file[@"enabled"] : CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("enabled"), kSSDomain));
    id percent = file ? file[@"percent"] : CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("percent"), kSSDomain));
    gEnabled = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : YES;
    NSInteger p = [percent respondsToSelector:@selector(integerValue)] ? [percent integerValue] : 80;
    p = ((p + 5) / 10) * 10;                       // steps of 10%
    gPercent = MAX(50, MIN(100, p));
}

#pragma mark - Viewport arguments

static float SSFloat(NSDictionary *d, NSString *key) {
    id v = d[key];
    return [v respondsToSelector:@selector(floatValue)] ? [v floatValue] : -1;
}

static CGSize SSDeviceSize(void) {
    // Portrait size in points. On iOS 6 and 7, UIScreen bounds don't rotate.
    CGSize s = [UIScreen mainScreen].bounds.size;
    return CGSizeMake(MIN(s.width, s.height), MAX(s.width, s.height));
}

// YES for pages that size themselves to the device: the only ones that look cramped and the only
// ones scaling makes sense for.
static BOOL SSIsDeviceSized(NSDictionary *args) {
    if (![args isKindOfClass:[NSDictionary class]]) return NO;
    float width = SSFloat(args, @"width");
    if (width == -2) return YES;                                         // device-width, unresolved
    if (fabs(width - SSDeviceSize().width) < 0.5) return YES;          // device-width, resolved
    return width == -1 && SSFloat(args, @"initial-scale") > 0;           // initial-scale only
}

static NSDictionary *SSScaledArguments(NSDictionary *args, CGFloat scale) {
    if (scale >= 0.999 || args[kSSScaledMarker] || !SSIsDeviceSized(args)) return args;
    CGSize device = SSDeviceSize();
    NSMutableDictionary *scaled = [args mutableCopy];
    float width = SSFloat(args, @"width"), height = SSFloat(args, @"height");
    if (width != -1) scaled[@"width"] = @(roundf(device.width / scale));
    if (height == -3 || fabs(height - device.height) < 0.5) scaled[@"height"] = @(roundf(device.height / scale));
    for (NSString *key in @[ @"initial-scale", @"minimum-scale", @"maximum-scale" ]) {
        float value = SSFloat(args, key);
        if (value > 0) scaled[key] = @(value * scale);
    }
    scaled[kSSScaledMarker] = @(scale);
    return scaled;
}

#pragma mark - Text autosizing

static char kSSAutosizingWidthKey;   // on a WebFrame: the last width Safari asked for
static char kSSAutosizingScaleKey;   // on a WebFrame: the scale its page is shown at (absent = 1)

// -[WebFrame _setTextAutosizingWidth:] is hooked on the frame's actual class the first time a page is
// scaled. WebFrame comes from Apple's WebKit or from Web Port's, and the right one may not be loaded yet
// when this tweak starts.
static void (*SSOrigSetTextAutosizingWidth)(id, SEL, float);
static void SSSetTextAutosizingWidth(id self, SEL _cmd, float width) {
    objc_setAssociatedObject(self, &kSSAutosizingWidthKey, @(width), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSNumber *scale = objc_getAssociatedObject(self, &kSSAutosizingScaleKey);
    SSOrigSetTextAutosizingWidth(self, _cmd, scale ? width / scale.floatValue : width);
}

// WebKit on iOS 6 and 7 runs WebCore on its own "WebThread". Anything that calls into WebKit from the
// main thread has to hold the WebThread lock first, as UIKit does, or WebCore may be in the middle of a
// layout. WebThreadLock() does nothing when already on the WebThread, and the main thread keeps the
// lock until the end of the current run loop pass.
// With Web Port, Safari has two WebCores loaded (Apple's and Web Port's in /var/wkd), each with its own
// WebThreadLock, and dlsym(RTLD_DEFAULT) finds Apple's. So the lock is taken from the WebCore next to
// the WebKit that the given object (a WebView or WebFrame) comes from.
static void SSWebThreadLockFor(id webKitObject) {
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

static void SSUpdateTextAutosizing(UIWebDocumentView *view, CGFloat scale) {
    WebView *webView = [view respondsToSelector:@selector(webView)] ? [view webView] : nil;
    SSWebThreadLockFor(webView);
    WebFrame *frame = [webView mainFrame];
    SEL sel = @selector(_setTextAutosizingWidth:);
    if (![frame respondsToSelector:sel]) return;
    if (!SSOrigSetTextAutosizingWidth)
        MSHookMessageEx([frame class], sel, (IMP)&SSSetTextAutosizingWidth, (IMP *)&SSOrigSetTextAutosizingWidth);
    NSNumber *old = objc_getAssociatedObject(frame, &kSSAutosizingScaleKey);
    NSNumber *now = scale < 0.999 ? @(scale) : nil;
    // (-isEqualToNumber: throws on nil, and nil is what 100% looks like here.)
    if ((!old && !now) || (old && now && [old isEqualToNumber:now])) return;
    objc_setAssociatedObject(frame, &kSSAutosizingScaleKey, now, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSNumber *width = objc_getAssociatedObject(frame, &kSSAutosizingWidthKey) ?: @(SSDeviceSize().width);
    [frame _setTextAutosizingWidth:width.floatValue];   // goes through the hook, which divides by the scale
    // Not -[WebFrame resetTextAutosizingBeforeLayout]: Web Port's WebCore traps inside it (EXC_BREAKPOINT,
    // every time, on the iPhone 4S). The new width is used on the next layout anyway.
}

#pragma mark - Hooks

static NSHashTable *gScaledViews;                    // weak; views showing a device-sized page
static char kSSOriginalArgumentsKey;

%hook UIWebDocumentView

- (unsigned int)_applyViewportArguments:(NSDictionary *)arguments {
    if (![arguments isKindOfClass:[NSDictionary class]] || arguments[kSSScaledMarker]) return %orig;
    BOOL deviceSized = SSIsDeviceSized(arguments);
    if (deviceSized) {
        objc_setAssociatedObject(self, &kSSOriginalArgumentsKey, arguments, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gScaledViews addObject:self];
    } else {
        // A new page without a device-sized viewport: forget the old one.
        objc_setAssociatedObject(self, &kSSOriginalArgumentsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gScaledViews removeObject:self];
    }
    CGFloat scale = deviceSized ? SSScale() : 1.0;
    unsigned int changed = %orig(SSScaledArguments(arguments, scale));
    SSUpdateTextAutosizing(self, scale);
    return changed;
}

%end

static void SSReapplyAll(void) {
    gNeedsReapply = NO;
    for (UIWebDocumentView *view in [gScaledViews allObjects]) {
        NSDictionary *original = objc_getAssociatedObject(view, &kSSOriginalArgumentsKey);
        if (!original) continue;
        // This runs on the main thread, outside any UIKit call that would take the lock.
        if ([view respondsToSelector:@selector(webView)]) SSWebThreadLockFor([view webView]);
        unsigned int changed = [view _applyViewportArguments:original];
        if ([view respondsToSelector:@selector(viewportConfigurationsDidChange:)])
            [view viewportConfigurationsDidChange:changed];
    }
}

// Reloads the settings. When the scale changed, open pages are updated now if Safari is in front,
// otherwise the next time it comes to the front.
static void SSRefresh(void) {
    CGFloat old = SSScale();
    SSLoadPreferences();
    if (SSScale() != old) gNeedsReapply = YES;
    if (gNeedsReapply && [UIApplication sharedApplication].applicationState == UIApplicationStateActive) SSReapplyAll();
}

static void SSPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ SSRefresh(); });
}

%ctor {
    @autoreleasepool {
        if (![UIWebDocumentView instancesRespondToSelector:@selector(_applyViewportArguments:)]) {
            NSLog(@"[SafariScale] -[UIWebDocumentView _applyViewportArguments:] not found; not loading.");
            return;
        }
        gScaledViews = [NSHashTable weakObjectsHashTable];
        SSLoadPreferences();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SSPreferencesChanged,
                                        CFSTR(kSSNotification), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                           queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            SSRefresh();
        }];
        %init;
    }
}
