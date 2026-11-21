#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import "vcam_shared.h"
#import "vcam_menu.h"

@interface SBVolumeHardwareButtonActions : NSObject
- (void)volumeIncreasePressDownWithModifiers:(long long)modifiers;
- (void)volumeDecreasePressDownWithModifiers:(long long)modifiers;
@end

static NSInteger sPendingVolumeDirection = 0;
static CFTimeInterval sPendingVolumeTime = 0;
static CFTimeInterval sLastMenuToggleTime = 0;
static const CFTimeInterval VCamChordWindow = 0.16; // Only treat near-simultaneous presses as a chord.
static const CFTimeInterval VCamToggleDebounce = 0.90;
static NSUInteger sVolumeHookAttempts = 0;
static BOOL sVolumeHooksInstalled = NO;

static void VCamRegisterVolumeDirection(NSInteger direction) {
    if (direction != 1 && direction != -1) return;

    CFTimeInterval now = CACurrentMediaTime();
    BOOL shouldToggle = NO;

    @synchronized ([VCamMenuPresenter class]) {
        if (sLastMenuToggleTime > 0.0 && now - sLastMenuToggleTime < VCamToggleDebounce) {
            return;
        }

        if (sPendingVolumeDirection != 0 && now - sPendingVolumeTime > VCamChordWindow) {
            sPendingVolumeDirection = 0;
            sPendingVolumeTime = 0;
        }

        if (sPendingVolumeDirection == 0) {
            // Start a short chord candidate window. A single volume press is
            // never delayed or swallowed; the original SpringBoard action
            // still runs in the hook below.
            sPendingVolumeDirection = direction;
            sPendingVolumeTime = now;
        } else if (direction == sPendingVolumeDirection) {
            // Repeated presses of the same volume key are normal volume
            // adjustments, not the beginning of an Up+Down chord.
            sPendingVolumeDirection = 0;
            sPendingVolumeTime = 0;
        } else {
            // The opposite key arrived within the short simultaneous-press
            // window. Only this deliberate two-key chord toggles the menu.
            shouldToggle = YES;
            sPendingVolumeDirection = 0;
            sPendingVolumeTime = 0;
            sLastMenuToggleTime = now;
        }
    }

    if (shouldToggle) {
        NSLog(@"[VCam] Volume Up + Volume Down detected; opening menu");
        dispatch_async(dispatch_get_main_queue(), ^{
            [VCamMenuPresenter toggleMenu];
        });
    }
}

%group VCamVolumeActionHooks
%hook SBVolumeHardwareButtonActions

- (void)volumeIncreasePressDownWithModifiers:(long long)modifiers {
    VCamRegisterVolumeDirection(1);
    %orig(modifiers);
}

- (void)volumeDecreasePressDownWithModifiers:(long long)modifiers {
    VCamRegisterVolumeDirection(-1);
    %orig(modifiers);
}

%end
%end

static void VCamTryInstallVolumeActionHooks(void) {
    if (sVolumeHooksInstalled) return;
    sVolumeHookAttempts++;

    Class actionsClass = objc_getClass("SBVolumeHardwareButtonActions");
    SEL increaseSelector = sel_registerName("volumeIncreasePressDownWithModifiers:");
    SEL decreaseSelector = sel_registerName("volumeDecreasePressDownWithModifiers:");
    Method increaseMethod = actionsClass ? class_getInstanceMethod(actionsClass, increaseSelector) : NULL;
    Method decreaseMethod = actionsClass ? class_getInstanceMethod(actionsClass, decreaseSelector) : NULL;

    if (actionsClass && increaseMethod && decreaseMethod) {
        %init(VCamVolumeActionHooks);
        sVolumeHooksInstalled = YES;
        NSLog(@"[VCam] Installed volume chord hooks on SBVolumeHardwareButtonActions");
        return;
    }

    if (sVolumeHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 2)),
                       dispatch_get_main_queue(), ^{
            VCamTryInstallVolumeActionHooks();
        });
    } else {
        NSLog(@"[VCam] Could not install volume hooks: SBVolumeHardwareButtonActions methods unavailable");
    }
}

%ctor {
    @autoreleasepool {
        NSLog(@"[VCam] SpringBoard menu tweak loaded");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 2)),
                       dispatch_get_main_queue(), ^{
            NSString *directory = VCamMediaDirectory();
            NSError *probeError = nil;
            BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                                        withIntermediateDirectories:YES
                                                                         attributes:@{ NSFilePosixPermissions: @0755 }
                                                                              error:&probeError];
            NSString *probe = [directory stringByAppendingPathComponent:@".vcam-write-probe"];
            BOOL wrote = created && [@"probe" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:&probeError];
            if (wrote) [[NSFileManager defaultManager] removeItemAtPath:probe error:nil];
            NSLog(@"[VCam] SpringBoard shared media write probe: %@%@", wrote ? @"OK" : @"FAILED",
                  probeError ? [NSString stringWithFormat:@" (%@)", probeError] : @"");
            // notifyd may retain the string length after the previous
            // SpringBoard exits while its chunk tokens are gone. Publish from
            // the persistent plist instead of trusting that transient state.
            NSDictionary *persisted = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/VCam/settings.plist"];
            NSString *sourceMode = persisted[VCamSourceModeKey];
            if ([sourceMode isKindOfClass:NSString.class]) VCamSetSetting(VCamSourceModeKey, sourceMode);
            VCamTryInstallVolumeActionHooks();
            [VCamMenuPresenter installOverlay];
        });
    }
}
