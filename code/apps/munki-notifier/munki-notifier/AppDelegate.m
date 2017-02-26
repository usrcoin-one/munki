//
//  AppDelegate.m
//  munki-notifier
//
//  Created by Greg Neagle on 2/23/17.
//  Copyright © 2017 The Munki Project. All rights reserved.
//  Much code lifted and adapted from https://github.com/julienXX/terminal-notifier
//

#import "AppDelegate.h"
#import <objc/runtime.h>

NSString * const MunkiNotifyBundleID = @"com.googlecode.munki.munki-notify";
NSString * const ManagedSoftwareCenterBundleID = @"com.googlecode.munki.ManagedSoftwareCenter";
NSString * const NotificationCenterUIBundleID = @"com.apple.notificationcenterui";
NSString * const MunkiUpdatesURL = @"munki://updates";


NSString *_fakeBundleIdentifier = nil;

@implementation NSBundle (FakeBundleIdentifier)

// Overriding bundleIdentifier works, but overriding NSUserNotificationAlertStyle does not work.

- (NSString *)__bundleIdentifier;
{
    if (self == [NSBundle mainBundle]) {
        return _fakeBundleIdentifier ? _fakeBundleIdentifier : MunkiNotifyBundleID;
    } else {
        return [self __bundleIdentifier];
    }
}

@end

static BOOL
InstallFakeBundleIdentifierHook()
{
    Class class = objc_getClass("NSBundle");
    if (class) {
        method_exchangeImplementations(
            class_getInstanceMethod(class, @selector(bundleIdentifier)),
            class_getInstanceMethod(class, @selector(__bundleIdentifier)));
        return YES;
    }
    return NO;
}


@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification;
{
    NSUserNotification *userNotification = notification.userInfo[
        NSApplicationLaunchUserNotificationKey];
    if (userNotification) {
        [self userActivatedNotification:userNotification];
        [NSApp terminate: self];
    } else {
        // Do we have a running NotificationCenter?
        NSArray *runningProcesses = [[[NSWorkspace sharedWorkspace] runningApplications]
                                     valueForKey:@"bundleIdentifier"];
        BOOL notificationCenterAvailable = ([runningProcesses indexOfObject:NotificationCenterUIBundleID]
                                            != NSNotFound);
        
        if (notificationCenterAvailable) {
            // Install the fake bundle ID hook so we can fake the sender. This also
            // needs to be done to be able to remove a message.
            @autoreleasepool {
                if (InstallFakeBundleIdentifierHook()) {
                    _fakeBundleIdentifier = ManagedSoftwareCenterBundleID;
                }
            }
        }

        // get count of pending updates, oldest update days and any forced update due date
        // from Munki's preferences
        CFPropertyListRef plistRef = nil;
        NSInteger updateCount = 0;
        NSInteger oldestUpdateDays = 0;
        NSDate *forcedUpdateDueDate = nil;
        
        CFPreferencesAppSynchronize(CFSTR("ManagedInstalls"));
        plistRef = CFPreferencesCopyValue(
            CFSTR("PendingUpdateCount"), CFSTR("ManagedInstalls"), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
        if (plistRef && CFGetTypeID(plistRef) == CFNumberGetTypeID()) {
            updateCount = [(NSNumber *)CFBridgingRelease(plistRef) integerValue];
        }
        plistRef = CFPreferencesCopyValue(
            CFSTR("OldestUpdateDays"), CFSTR("ManagedInstalls"), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
        if (plistRef && CFGetTypeID(plistRef) == CFNumberGetTypeID()) {
            oldestUpdateDays = [(NSNumber *)CFBridgingRelease(plistRef) integerValue];
        }
        plistRef = CFPreferencesCopyValue(
             CFSTR("ForcedUpdateDueDate"), CFSTR("ManagedInstalls"), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
        if (plistRef && CFGetTypeID(plistRef) == CFDateGetTypeID()) {
            forcedUpdateDueDate = (NSDate *)CFBridgingRelease((CFDateRef)plistRef);
        }
        
        if (updateCount == 0) {
            // no available updates
            if (notificationCenterAvailable) {
                // clear any previously posted updates available notifications and exit
                [[NSUserNotificationCenter defaultUserNotificationCenter] removeAllDeliveredNotifications];
            }
            [NSApp terminate: self];
            return;
        }
        
        // updateCount > 0
        if (! notificationCenterAvailable || oldestUpdateDays > 3) {
            // Notification Center is not available or Notification Manager notifications
            // are being ignored or suppressed; launch MSC.app and show updates
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString: MunkiUpdatesURL]];
            [NSApp terminate: self];
            return;
        }
        
        // We have Notification Center, create and post our notification
        // Build a localized update count message
        NSString *updateCountMessage = NSLocalizedString(@"1 pending update", @"One Update message");
        NSString *multipleUpdatesFormatString = NSLocalizedString(
            @"%@ pending updates", @"Multiple Update message");
        if (updateCount > 1) {
            updateCountMessage = [NSString stringWithFormat:multipleUpdatesFormatString,
                                  [@(updateCount) stringValue]];
        }
        
        // Build a localized force install date message
        NSString *deadlineMessage = nil;
        NSString *deadlineMessageFormatString = NSLocalizedString(
              @"One or more items must be installed by %@", @"Forced Install Date summary");
        if (forcedUpdateDueDate) {
            deadlineMessage = [NSString stringWithFormat:deadlineMessageFormatString,
                [self stringFromDate: forcedUpdateDueDate]];
        }
        
        // Assemble all our needed notification info
        NSString *title    = NSLocalizedString(
            @"Software updates available", @"Software updates available message");
        NSString *subtitle = @"";
        NSString *message  = updateCountMessage;
        if (deadlineMessage) {
            subtitle = updateCountMessage;
            message = deadlineMessage;
        }
        NSString *sound = @"default";
        
        // Create options (userInfo) dictionary
        NSMutableDictionary *options = [NSMutableDictionary dictionary];
        options[@"groupID"]  = @"com.googlecode.munki.munki-notifier.update-notification";
        options[@"action"]   = @"open_url";
        options[@"value"]    = MunkiUpdatesURL;
        
        // deliver the notification
        [self deliverNotificationWithTitle:title
                                  subtitle:subtitle
                                   message:message
                                   options:options
                                     sound:sound];
    }
}

- (NSString *)stringFromDate:(NSDate *)date
{
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.formatterBehavior = NSDateFormatterBehavior10_4;
    formatter.dateStyle = NSDateFormatterShortStyle;
    formatter.timeStyle = NSDateFormatterNoStyle;
    formatter.doesRelativeDateFormatting = YES;
    formatter.formattingContext = NSFormattingContextDynamic;
    return [formatter stringFromDate:date];
}


- (void)deliverNotificationWithTitle:(NSString *)title
                            subtitle:(NSString *)subtitle
                             message:(NSString *)message
                             options:(NSDictionary *)options
                               sound:(NSString *)sound;
{
    // First remove earlier notifications from us
    [[NSUserNotificationCenter defaultUserNotificationCenter] removeAllDeliveredNotifications];
    // this other way doesn't seem to work reliably.
    //if (options[@"groupID"]) [self removeNotificationWithGroupID:options[@"groupID"]];
    
    NSUserNotification *userNotification = [NSUserNotification new];
    userNotification.title = title;
    if (! [subtitle isEqualToString:@""]) userNotification.subtitle = subtitle;
    if (! [message isEqualToString:@""]) userNotification.informativeText = message;
    userNotification.userInfo = options;
    
    // Attempt to display as alert style (though user can override at any time)
    [userNotification setValue:@YES forKey:@"_showsButtons"];
    userNotification.hasActionButton = true;
    userNotification.actionButtonTitle = NSLocalizedString(@"Details", @"Details label");
    
    if (sound != nil) {
        userNotification.soundName = [sound isEqualToString: @"default"] ? NSUserNotificationDefaultSoundName : sound;
    }
    
    NSUserNotificationCenter *center = [NSUserNotificationCenter defaultUserNotificationCenter];
    center.delegate = self;
    [center deliverNotification:userNotification];
}

// this function does not appear to reliably remove notifications. To further investigate in the future.
- (void)removeNotificationWithGroupID:(NSString *)groupID;
{
    NSUserNotificationCenter *center = [NSUserNotificationCenter defaultUserNotificationCenter];
    for (NSUserNotification *userNotification in center.deliveredNotifications) {
        if ([@"ALL" isEqualToString:groupID] || [userNotification.userInfo[@"groupID"] isEqualToString:groupID]) {
            [center removeDeliveredNotification:userNotification];
        }
    }
}

// React to user clicking on notification
- (void)userActivatedNotification:(NSUserNotification *)userNotification;
{
    [[NSUserNotificationCenter defaultUserNotificationCenter] removeDeliveredNotification:userNotification];
    
    NSString *action = userNotification.userInfo[@"action"];
    NSString *value  = userNotification.userInfo[@"value"];
    
    if ([action isEqualToString:@"open_url"]){
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:value]];
    } else {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString: MunkiUpdatesURL]];
    }
}

// Return YES to present the notification even if MSC.app is frontmost
- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center
     shouldPresentNotification:(NSUserNotification *)notification;
{
    return YES;
}

// Once the notification is delivered we can exit.
- (void)userNotificationCenter:(NSUserNotificationCenter *)center
        didDeliverNotification:(NSUserNotification *)notification;
{
    [NSApp terminate: self];
}

// handle user clicking on our notification
- (void)userNotificationCenter:(NSUserNotificationCenter *)center
       didActivateNotification:(NSUserNotification *)notification
{
    [self userActivatedNotification:notification];
    [NSApp terminate: self];
}

@end
