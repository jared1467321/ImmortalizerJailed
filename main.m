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
#import "ImmortalizerLog.h"   /* provides IMLog */

static BOOL isImmortalized;

/* Temporary diagnostic. While 1, the hook logs the raw settings diff for any
   foreground-related update so we can see what iOS is actually sending and
   whether the substring matching still fits this version. Set to 0 once the
   "blocked foreground-exit" line is confirmed. */
#define IM_LOG_RAW_DIFFS 1

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
typedef NS_ENUM(NSInteger, IMSuppressReason) {
    IMSuppressReasonNone = 0,        /* let the update through           */
    IMSuppressReasonForegroundExit,  /* the app was being backgrounded   */
    IMSuppressReasonSnapshotChurn,   /* snapshot / event-deferring noise */
};

static IMSuppressReason suppressReasonForSettingsDiff(id diff) {
    NSString *d = [diff description];
    if (!d) return IMSuppressReasonNone;

    /* App is being moved out of the foreground.

       The description format is version-dependent. On current iOS the flag is
       rendered as:   foreground [flag] = NotSet    (or = No)
       alongside:     foreground [obj]  = 0
       Older builds used the shorter form:  foreground = No / NotSet.
       We match all of them. "= No" is a prefix of "= NotSet", so testing for
       "No" covers both. Critically we must NOT match "= Yes" — that's the app
       returning to the foreground — so we never key off a bare "foreground". */
    if ([d containsString:@"foreground [flag] = No"] ||   /* current: No + NotSet */
        [d containsString:@"foreground [obj] = 0"]   ||   /* current: leaving     */
        [d containsString:@"foreground = No"]        ||   /* legacy               */
        [d containsString:@"foreground = NotSet"]    ||
        [d containsString:@"foreground = BSSettingFlagNo"]) {
        return IMSuppressReasonForegroundExit;
    }

    /* Snapshot / event-deferring churn. */
    if ([d containsString:@"hostContextIdentifierForSnapshotting = 0"] ||
        [d containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
        [d containsString:@"targetOfEventDeferringEnvironments = (empty)"] ||
        [d containsString:@"FBSceneSnapshotAction:"]) {
        return IMSuppressReasonSnapshotChurn;
    }

    return IMSuppressReasonNone;
}

/* thanks to @khanhduytran0 for the original hook. goat */
void new_sceneID_updateWithSettingsDiff_transitionContext_completion(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
#if IM_LOG_RAW_DIFFS
    /* Diagnostic: show any foreground-related diff regardless of what we decide,
       so we can confirm the hook fires, whether it sees immortalize as on, and
       what the description text actually looks like on this iOS version. */
    {
        NSString *desc = [arg2 description];
        if (desc && [desc rangeOfString:@"foreground" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            static NSTimeInterval lastDiag = 0;
            NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
            if (now - lastDiag >= 0.5) {
                lastDiag = now;
                NSString *snippet = desc.length > 240 ? [desc substringToIndex:240] : desc;
                IMLog(@"diag immortalized=%d reason=%ld diff=%@",
                      isImmortalized, (long)suppressReasonForSettingsDiff(arg2), snippet);
            }
        }
    }
#endif

    if (!isImmortalized) {
        return original_sceneID_updateWithSettingsDiff_transitionContext_completion(self, _cmd, arg1, arg2, arg3, arg4);
    }

    /* arg2 is the FBSSceneSettingsDiff. Drop the update entirely if it would
       push the app out of the foreground, so it never processes the transition. */
    IMSuppressReason reason = suppressReasonForSettingsDiff(arg2);
    if (reason != IMSuppressReasonNone) {
        if (reason == IMSuppressReasonForegroundExit) {
            /* The money event: the OS just tried to background the app and we
               swallowed it. Throttle to one line a second so a burst of
               identical diffs can't flood the 500-entry log — that's plenty to
               confirm it's working. Snapshot churn is suppressed silently;
               logging it would bury this line in noise. */
            static NSTimeInterval lastForegroundBlockLog = 0;
            NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
            if (now - lastForegroundBlockLog >= 1.0) {
                lastForegroundBlockLog = now;
                IMLog(@"blocked foreground-exit — app kept immortalized");
            }
        }
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
