/* 
    Copyright (C) 2025  Serge Alagon

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>. 
*/

#import <objc/runtime.h>
#import <string.h>
#import <stdlib.h>
#import "FloatingButtonWindow.h"
#import "PrivateHeaders.h"

#define IMLog(fmt, ...) NSLog(@"[ImmortalizerJailed] " fmt, ##__VA_ARGS__)

static BOOL isImmortalized;

static void prefsChanged() {
    isImmortalized = ImmortalizerIsEnabled();
}

static void (*original_sceneID_updateWithSettingsDiff_transitionContext_completion)(id, SEL, id, id, id, id);

/* Decide whether this settings diff represents the app leaving the foreground,
   or snapshot / event-deferring churn we want to swallow while immortalized.

   NOTE: this inspects -[diff description], which is NOT public API and can
   change between iOS versions. It's the pragmatic approach the tweak has always
   used; typed parsing of FBSSceneSettingsDiff would be sturdier if you have the
   private headers. Kept isolated here so it's the one place to update if a
   future iOS changes the description format. */
static BOOL shouldSuppressSettingsDiff(id diff) {
    NSString *d = [diff description];
    if (!d) return NO;

    /* App is being moved out of the foreground.
       ("foreground = No" is also a prefix of "foreground = NotSet", so those
       are covered too; the extra checks are just for readability.) */
    if ([d containsString:@"foreground = No"] ||
        [d containsString:@"foreground = NotSet"] ||
        [d containsString:@"foreground = NO"] ||
        [d containsString:@"foreground = BSSettingFlagNo"]) {
        return YES;
    }

    /* Snapshot / event-deferring churn. */
    if ([d containsString:@"hostContextIdentifierForSnapshotting = 0"] ||
        [d containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
        [d containsString:@"targetOfEventDeferringEnvironments = (empty)"] ||
        [d containsString:@"FBSceneSnapshotAction:"]) {
        return YES;
    }

    return NO;
}

/* thanks to @khanhduytran0 for the original hook. goat */
void new_sceneID_updateWithSettingsDiff_transitionContext_completion(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    if (!isImmortalized) {
        return original_sceneID_updateWithSettingsDiff_transitionContext_completion(self, _cmd, arg1, arg2, arg3, arg4);
    }

    /* arg2 is the FBSSceneSettingsDiff. Drop the update entirely if it would
       push the app out of the foreground, so it never processes the transition. */
    if (shouldSuppressSettingsDiff(arg2)) {
        return;
    }

    return original_sceneID_updateWithSettingsDiff_transitionContext_completion(self, _cmd, arg1, arg2, arg3, arg4);
}

/* --- Version resilience ----------------------------------------------------
   The class that owns -sceneID:updateWithSettingsDiff:transitionContext:completion:
   has not always been named the same across iOS versions. Try a list of known
   names first; if none match, scan the runtime for any Scene/Workspace class
   that implements the selector. Returns nil (and the hook no-ops) if nothing
   is found, with a log line so it's diagnosable. */
static Class findScenesClientClass(SEL selector) {
    const char *candidates[] = {
        "FBSWorkspaceScenesClient",
        "FBWorkspaceScenesClient",
        "FBSSceneClient",
        "FBSWorkspaceClient",
        "FBSceneManager",
    };

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        Class c = objc_getClass(candidates[i]);
        if (c && class_getInstanceMethod(c, selector)) {
            IMLog(@"matched scenes client class: %s", candidates[i]);
            return c;
        }
    }

    /* Fallback: scan the runtime. Gated on name hints to keep it cheap. */
    unsigned int count = 0;
    Class *all = objc_copyClassList(&count);
    Class found = NULL;
    if (all) {
        for (unsigned int i = 0; i < count; i++) {
            const char *name = class_getName(all[i]);
            if (name && (strstr(name, "Scene") || strstr(name, "Workspace"))) {
                if (class_getInstanceMethod(all[i], selector)) {
                    found = all[i];
                    IMLog(@"matched scenes client class by scan: %s", name);
                    break;
                }
            }
        }
        free(all);
    }
    return found;
}

static void installHook(void) {
    SEL selector = @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:);
    Class targetClass = findScenesClientClass(selector);
    if (!targetClass) {
        IMLog(@"could not locate a scenes client class; immortalize will no-op on this iOS version");
        return;
    }

    Method originalMethod = class_getInstanceMethod(targetClass, selector);
    if (!originalMethod) {
        IMLog(@"selector missing on %s; hook not installed", class_getName(targetClass));
        return;
    }

    original_sceneID_updateWithSettingsDiff_transitionContext_completion =
        (void (*)(id, SEL, id, id, id, id))method_getImplementation(originalMethod);
    method_setImplementation(originalMethod, (IMP)new_sceneID_updateWithSettingsDiff_transitionContext_completion);
    IMLog(@"hook installed on %s", class_getName(targetClass));
}

static void setup() {
    dispatch_async(dispatch_get_main_queue(), ^{
        installHook();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            (CFNotificationCallback)prefsChanged, CFSTR(kImmortalizerPrefsName), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        [[FloatingButtonWindow sharedInstance] showButton];
    });
}

__attribute__((constructor)) static void initialize() {
    prefsChanged();
    setup();
}
