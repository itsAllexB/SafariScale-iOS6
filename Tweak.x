// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// PageScale 1.0.0
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
// What PageScale changes, for pages that size themselves to the device (width=device-width,
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
// Settings changes: the original arguments of every page we scaled are kept on its view. When Safari
// comes back to the front after a change, they're applied again, so open pages update in place
// without reloading (form contents and scroll position are kept).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define kPSDomain CFSTR("com.itsallexb.pagescale")
#define kPSNotification "com.itsallexb.pagescale/prefschanged"
static NSString *const kPSPrefsPath = @"/var/mobile/Library/Preferences/com.itsallexb.pagescale.plist";
static NSString *const kPSScaledMarker = @"com.itsallexb.pagescale.scaled";   // set on dictionaries we made

@interface UIWebDocumentView : UIView
- (unsigned int)_applyViewportArguments:(NSDictionary *)arguments;
- (void)viewportConfigurationsDidChange:(unsigned int)mask;
@end

#pragma mark - Preferences

static BOOL gEnabled = YES;
static NSInteger gPercent = 80;
static BOOL gNeedsReapply = NO;

static CGFloat PSScale(void) {
    return gEnabled ? gPercent / 100.0 : 1.0;
}

static void PSLoadPreferences(void) {
    // Read the plist the Settings pane writes; CFPreferences is only the fallback when there is no file yet.
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:kPSPrefsPath];
    id enabled = file ? file[@"enabled"] : CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("enabled"), kPSDomain));
    id percent = file ? file[@"percent"] : CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("percent"), kPSDomain));
    gEnabled = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : YES;
    NSInteger p = [percent respondsToSelector:@selector(integerValue)] ? [percent integerValue] : 80;
    p = ((p + 5) / 10) * 10;                       // steps of 10%
    gPercent = MAX(50, MIN(100, p));
}

#pragma mark - Viewport arguments

static float PSFloat(NSDictionary *d, NSString *key) {
    id v = d[key];
    return [v respondsToSelector:@selector(floatValue)] ? [v floatValue] : -1;
}

static CGSize PSDeviceSize(void) {
    // Portrait size in points. On iOS 6 and 7, UIScreen bounds don't rotate.
    CGSize s = [UIScreen mainScreen].bounds.size;
    return CGSizeMake(MIN(s.width, s.height), MAX(s.width, s.height));
}

// YES for pages that size themselves to the device: the only ones that look cramped and the only
// ones scaling makes sense for.
static BOOL PSIsDeviceSized(NSDictionary *args) {
    if (![args isKindOfClass:[NSDictionary class]]) return NO;
    float width = PSFloat(args, @"width");
    if (width == -2) return YES;                                         // device-width, unresolved
    if (fabsf(width - PSDeviceSize().width) < 0.5f) return YES;          // device-width, resolved
    return width == -1 && PSFloat(args, @"initial-scale") > 0;           // initial-scale only
}

static NSDictionary *PSScaledArguments(NSDictionary *args, CGFloat scale) {
    if (scale >= 0.999 || args[kPSScaledMarker] || !PSIsDeviceSized(args)) return args;
    CGSize device = PSDeviceSize();
    NSMutableDictionary *scaled = [args mutableCopy];
    float width = PSFloat(args, @"width"), height = PSFloat(args, @"height");
    if (width != -1) scaled[@"width"] = @(roundf(device.width / scale));
    if (height == -3 || fabsf(height - device.height) < 0.5f) scaled[@"height"] = @(roundf(device.height / scale));
    for (NSString *key in @[ @"initial-scale", @"minimum-scale", @"maximum-scale" ]) {
        float value = PSFloat(args, key);
        if (value > 0) scaled[key] = @(value * scale);
    }
    scaled[kPSScaledMarker] = @(scale);
    return scaled;
}

#pragma mark - Hooks

static NSHashTable *gScaledViews;                    // weak; views showing a device-sized page
static char kPSOriginalArgumentsKey;

%hook UIWebDocumentView

- (unsigned int)_applyViewportArguments:(NSDictionary *)arguments {
    if (![arguments isKindOfClass:[NSDictionary class]] || arguments[kPSScaledMarker]) return %orig;
    if (PSIsDeviceSized(arguments)) {
        objc_setAssociatedObject(self, &kPSOriginalArgumentsKey, arguments, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gScaledViews addObject:self];
    } else {
        // A new page without a device-sized viewport: forget the old one.
        objc_setAssociatedObject(self, &kPSOriginalArgumentsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gScaledViews removeObject:self];
    }
    return %orig(PSScaledArguments(arguments, PSScale()));
}

%end

static void PSReapplyAll(void) {
    gNeedsReapply = NO;
    for (UIWebDocumentView *view in [gScaledViews allObjects]) {
        NSDictionary *original = objc_getAssociatedObject(view, &kPSOriginalArgumentsKey);
        if (!original) continue;
        unsigned int changed = [view _applyViewportArguments:original];
        if ([view respondsToSelector:@selector(viewportConfigurationsDidChange:)])
            [view viewportConfigurationsDidChange:changed];
    }
}

// Reloads the settings. When the scale changed, open pages are updated now if Safari is in front,
// otherwise the next time it comes to the front.
static void PSRefresh(void) {
    CGFloat old = PSScale();
    PSLoadPreferences();
    if (PSScale() != old) gNeedsReapply = YES;
    if (gNeedsReapply && [UIApplication sharedApplication].applicationState == UIApplicationStateActive) PSReapplyAll();
}

static void PSPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ PSRefresh(); });
}

%ctor {
    @autoreleasepool {
        if (![UIWebDocumentView instancesRespondToSelector:@selector(_applyViewportArguments:)]) {
            NSLog(@"[PageScale] -[UIWebDocumentView _applyViewportArguments:] not found; not loading.");
            return;
        }
        gScaledViews = [NSHashTable weakObjectsHashTable];
        PSLoadPreferences();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PSPreferencesChanged,
                                        CFSTR(kPSNotification), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                           queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            PSRefresh();
        }];
        %init;
    }
}
