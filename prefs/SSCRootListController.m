// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#import <UIKit/UIKit.h>

// The few Preferences.framework (private) declarations this pane needs, valid from iOS 6 on.
// Declared here rather than imported so it builds with the iOS 9.3 SDK, which armv7 needs.
@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController {
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface SSCRootListController : PSListController
@end

@implementation SSCRootListController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

// Safari reads the settings from the plist file, so the file is written here, before the change
// notification is posted, rather than whenever the preferences system gets to it.
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *domain = [specifier propertyForKey:@"defaults"], *key = [specifier propertyForKey:@"key"];
    if (!domain.length || !key.length) {
        [super setPreferenceValue:value specifier:specifier];
        return;
    }
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", domain];
    NSMutableDictionary *file = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    if (value) file[key] = value; else [file removeObjectForKey:key];
    [file writeToFile:path atomically:YES];
    NSString *note = [specifier propertyForKey:@"PostNotification"];
    if (note.length) CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)note, NULL, NULL, YES);
}

@end
