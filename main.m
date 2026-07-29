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
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <time.h>
#import "FloatingButtonWindow.h"
#import "PrivateHeaders.h"
#import "ImmortalizerLog.h"   /* provides IMLog */

/* --- Shared state ----------------------------------------------------------

   All four of these are read from the scene hook, which runs on whatever
   thread FrontBoard calls us on, and written from the main thread. They were
   plain file-statics before; atomics cost nothing at this size and remove the
   data race. */

static atomic_bool gImmortalized     = false;
static atomic_int  gHookStatus       = IMHookStatusPending;
static atomic_bool gVerboseLogging   = false;
static atomic_bool gInvokeCompletion = false;
static atomic_uint_fast64_t gLastDiagnosticLogMilliseconds = 0;
static atomic_uint_fast64_t gLastForegroundLogMilliseconds = 0;
static atomic_bool gObservedApplicationInBackground = false;

NSString * const ImmortalizerStatusDidChangeNotification = @"ImmortalizerStatusDidChangeNotification";

static void IMPostStatusChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ImmortalizerStatusDidChangeNotification object:nil];
    });
}

static void IMSetHookStatus(IMHookStatus status) {
    IMHookStatus previous = (IMHookStatus)atomic_exchange(&gHookStatus, (int)status);
    if (previous != status) {
        IMPostStatusChanged();
    }
}

static BOOL IMUpdateImmortalizedCache(BOOL enabled) {
    bool newValue = enabled ? true : false;
    bool previous = atomic_exchange(&gImmortalized, newValue);
    if (previous != newValue) {
        IMPostStatusChanged();
        return YES;
    }
    return NO;
}

static uint_fast64_t IMMonotonicMilliseconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return ((uint_fast64_t)now.tv_sec * 1000ULL) +
           ((uint_fast64_t)now.tv_nsec / 1000000ULL);
}

/* Atomically claim a throttled log slot. The scene callback can arrive on
   multiple FrontBoard threads at once, so a plain static NSTimeInterval is a
   real data race even though the worst visible symptom is duplicate logging. */
static BOOL IMClaimLogInterval(atomic_uint_fast64_t *lastMilliseconds,
                               uint_fast64_t intervalMilliseconds) {
    uint_fast64_t now = IMMonotonicMilliseconds();
    uint_fast64_t previous = atomic_load(lastMilliseconds);

    while (previous == 0 || now - previous >= intervalMilliseconds) {
        if (atomic_compare_exchange_weak(lastMilliseconds, &previous, now)) {
            return YES;
        }
    }
    return NO;
}

IMHookStatus ImmortalizerHookStatus(void) {
    return (IMHookStatus)atomic_load(&gHookStatus);
}

NSString *ImmortalizerHookStatusDescription(void) {
    switch (ImmortalizerHookStatus()) {
        case IMHookStatusInstalled: return @"attached";
        case IMHookStatusFailed:    return @"not attached — silent audio only";
        case IMHookStatusSuspect:   return @"attached but not holding";
        case IMHookStatusPending:
        default:                    return @"attaching…";
    }
}

BOOL ImmortalizerCachedEnabled(void) {
    return atomic_load(&gImmortalized) ? YES : NO;
}

void ImmortalizerSetEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kImmortalizedDefaultsKey];

    /* Update the cache here rather than waiting for our own Darwin
       notification to come back around. The writer and the reader are the same
       process; the round trip only ever bought us a window where the toggle
       said ON and the hook still saw OFF. The post stays for anything outside
       this process that might be listening. */
    IMUpdateImmortalizedCache(enabled);
    notify_post(kImmortalizerPrefsName);
}

BOOL ImmortalizerVerboseLogging(void) {
    return atomic_load(&gVerboseLogging) ? YES : NO;
}

void ImmortalizerSetVerboseLogging(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kImmortalizerVerboseDefaultsKey];
    atomic_store(&gVerboseLogging, enabled ? true : false);
    IMLog(@"Verbose diff logging %@", enabled ? @"ON" : @"OFF");
    IMPostStatusChanged();
}

BOOL ImmortalizerInvokeSuppressedCompletion(void) {
    return atomic_load(&gInvokeCompletion) ? YES : NO;
}

void ImmortalizerSetInvokeSuppressedCompletion(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kImmortalizerCompletionDefaultsKey];
    atomic_store(&gInvokeCompletion, enabled ? true : false);
    IMLog(@"Suppressed-update completion handler will now be %@",
          enabled ? @"invoked (experimental)" : @"dropped (default)");
    IMPostStatusChanged();
}

static void prefsChanged(CFNotificationCenterRef center,
                         void *observer,
                         CFStringRef name,
                         const void *object,
                         CFDictionaryRef userInfo) {
    IMUpdateImmortalizedCache(ImmortalizerIsEnabled());
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

/* --- Did the block actually hold? ------------------------------------------

   Swallowing the foreground-exit diff is supposed to mean the app never leaves
   the foreground. If the string matching has drifted — a future iOS renaming
   the flag, say — we'd swallow nothing, the app would background, and the only
   symptom would be the log going quiet. Nothing else in here would notice.

   So after a block, look again a moment later and see where we actually ended
   up. If we're in the background, the hook isn't doing its job and the silent
   audio is the only thing still carrying us; say so, and let the button colour
   say so too.

   The check itself relies on the app still running to fire — which is the
   point. If we get fully suspended the block runs on the next resume instead,
   by which time we're active again and it correctly reports nothing wrong. The
   case it's built to catch is the one where audio keeps the process alive
   while the foreground hold has quietly stopped working. */
static atomic_bool gVerificationScheduled = false;

static void IMScheduleForegroundVerification(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&gVerificationScheduled, &expected, true)) {
        return;   /* one in flight is enough; diffs arrive in bursts */
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        atomic_store(&gVerificationScheduled, false);

        if (!ImmortalizerCachedEnabled()) return;
        if (ImmortalizerHookStatus() == IMHookStatusFailed) return;

        if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
            if (ImmortalizerHookStatus() != IMHookStatusSuspect) {
                IMLog(@"Blocked a background attempt but the app went to the background anyway — "
                       "the foreground hook may no longer match this version of iOS. Turn on "
                       "Verbose in this log to see the raw diffs.");
            }
            IMSetHookStatus(IMHookStatusSuspect);
        } else if (ImmortalizerHookStatus() == IMHookStatusSuspect) {
            IMLog(@"Foreground hold is working again");
            IMSetHookStatus(IMHookStatusInstalled);
        }
    });
}

/* thanks to @khanhduytran0 for the original hook. goat */
void new_sceneID_updateWithSettingsDiff_transitionContext_completion(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    BOOL immortalized = ImmortalizerCachedEnabled();

    /* Diagnostic: show any foreground-related diff regardless of what we decide,
       so we can confirm the hook fires, whether it sees immortalize as on, and
       what the description text actually looks like on this iOS version.
       Runtime-gated (Verbose in the log viewer) rather than compile-time, so it
       can be turned on from the device without a rebuild. */
    if (ImmortalizerVerboseLogging()) {
        NSString *desc = [arg2 description];
        if (desc && [desc rangeOfString:@"foreground" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            if (IMClaimLogInterval(&gLastDiagnosticLogMilliseconds, 500)) {
                NSString *snippet = desc.length > 240 ? [desc substringToIndex:240] : desc;
                IMLog(@"diag immortalized=%d reason=%ld diff=%@",
                      (int)immortalized, (long)suppressReasonForSettingsDiff(arg2), snippet);
            }
        }
    }

    if (!immortalized) {
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
            if (IMClaimLogInterval(&gLastForegroundLogMilliseconds, 1000)) {
                IMLog(@"App tried to go to the background — kept it awake");
            }

            IMScheduleForegroundVerification();
        }

        /* arg4 is the completion handler that came with this update. Dropping
           the update drops that too, so whatever queued the transition never
           hears back about it. The tweak has always worked this way and does
           not obviously misbehave, which is why this is OFF by default — but it
           is the one place we take something the system handed us and never
           reply.

           Enabling it invokes the handler as a zero-argument block. That
           signature is an assumption: the real one is private and could take a
           BOOL. If the app misbehaves with this on, turn it back off — that's
           the whole reason it's a toggle and not a change. */
        if (ImmortalizerInvokeSuppressedCompletion() &&
            arg4 && [arg4 isKindOfClass:NSClassFromString(@"NSBlock")]) {
            ((void (^)(void))arg4)();
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
static Method IMClassGetOwnInstanceMethod(Class cls, SEL selector) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    Method found = NULL;
    for (unsigned int i = 0; i < methodCount; i++) {
        if (method_getName(methods[i]) == selector) {
            found = methods[i];
            break;
        }
    }
    free(methods);
    return found;
}

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
            return c;
        }
    }

    /* Fallback: scan the runtime. Gated on name hints to keep it cheap. */
    unsigned int count = 0;
    Class *all = objc_copyClassList(&count);
    Class found = NULL;
    BOOL foundOwnsMethod = NO;
    if (all) {
        for (unsigned int i = 0; i < count; i++) {
            const char *name = class_getName(all[i]);
            if (name && (strstr(name, "Scene") || strstr(name, "Workspace"))) {
                Method method = class_getInstanceMethod(all[i], selector);
                if (!method) continue;

                BOOL ownsMethod = IMClassGetOwnInstanceMethod(all[i], selector) != NULL;
                if (!found ||
                    (ownsMethod && !foundOwnsMethod) ||
                    (ownsMethod == foundOwnsMethod &&
                     strcmp(name, class_getName(found)) < 0)) {
                    found = all[i];
                    foundOwnsMethod = ownsMethod;
                }
            }
        }
        free(all);
    }
    return found;
}

/* Resolve the class that actually owns the selected implementation. The prior
   hardening pass tried to add an override to whichever candidate class first
   exposed the selector. On some iOS versions that candidate only inherits the
   method and is not the object receiving these updates. Hooking the real owner
   preserves the behavior of the original working implementation while making
   the inheritance decision explicit and diagnosable. */
static Class IMClassOwningInstanceMethod(Class cls, SEL selector) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if (IMClassGetOwnInstanceMethod(current, selector)) {
            return current;
        }
    }
    return Nil;
}

static Class gHookTargetClass = Nil;
static BOOL gHookDisplacementLogged = NO;

static BOOL IMHookImplementationIsInstalled(SEL selector) {
    return gHookTargetClass &&
           class_getMethodImplementation(gHookTargetClass, selector) ==
               (IMP)new_sceneID_updateWithSettingsDiff_transitionContext_completion;
}

/* Idempotent, main-thread only. Returns YES once the hook is in place. */
static BOOL IMInstallHookIfNeeded(void) {
    SEL selector = @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:);

    /* Once we have installed on a concrete class, verify ownership rather than
       blindly swizzling again. If another injected dylib hooks after us, its
       saved "original" implementation is our hook. Replacing it and then
       calling through that new hook would form a recursion cycle:
       ours -> theirs -> ours. Report the displacement and leave the other hook
       chain intact; reattaching automatically is not safe without cooperation. */
    if (gHookTargetClass) {
        if (IMHookImplementationIsInstalled(selector)) {
            if (gHookDisplacementLogged) {
                IMLog(@"The foreground hook is directly attached again");
            }
            gHookDisplacementLogged = NO;
            if (ImmortalizerHookStatus() == IMHookStatusFailed ||
                ImmortalizerHookStatus() == IMHookStatusPending) {
                IMSetHookStatus(IMHookStatusInstalled);
            }
            return YES;
        }

        if (!gHookDisplacementLogged) {
            IMLog(@"The foreground hook was replaced by another runtime hook — not reattaching automatically to avoid a hook-chain recursion");
            gHookDisplacementLogged = YES;
        }
        IMSetHookStatus(IMHookStatusFailed);
        return NO;
    }

    Class discoveredClass = findScenesClientClass(selector);
    if (!discoveredClass) return NO;

    Class targetClass = IMClassOwningInstanceMethod(discoveredClass, selector);
    if (!targetClass) return NO;

    Method originalMethod = IMClassGetOwnInstanceMethod(targetClass, selector);
    if (!originalMethod) return NO;

    IMP originalImplementation = method_getImplementation(originalMethod);
    if (!originalImplementation ||
        originalImplementation == (IMP)new_sceneID_updateWithSettingsDiff_transitionContext_completion) {
        return NO;
    }

    /* Private Objective-C type encodings have changed across iOS releases even
       when this selector and its calling convention remained usable. Requiring
       one exact encoding caused compatible current releases to be rejected.
       Preserve the original ABI-compatible hook behavior and record the actual
       encoding in the log for future diagnosis instead of treating it as a
       hard gate. */
    const char *typeEncoding = method_getTypeEncoding(originalMethod);

    /* Publish the original before exposing the replacement. FrontBoard may call
       the method from another thread immediately after the runtime mutation. */
    original_sceneID_updateWithSettingsDiff_transitionContext_completion =
        (void (*)(id, SEL, id, id, id, id))originalImplementation;

    method_setImplementation(originalMethod,
        (IMP)new_sceneID_updateWithSettingsDiff_transitionContext_completion);

    gHookTargetClass = targetClass;
    if (!IMHookImplementationIsInstalled(selector)) {
        gHookTargetClass = Nil;
        return NO;
    }

    IMSetHookStatus(IMHookStatusInstalled);
    IMLog(@"Immortalizer is active and watching for background attempts (%s; discovered via %s; encoding %s)",
          class_getName(targetClass),
          class_getName(discoveredClass),
          typeEncoding ? typeEncoding : "unknown");
    return YES;
}

/* The constructor runs early enough that the FrontBoard class we want may not
   be loaded yet, and the old code took exactly one shot at it: miss, log, give
   up for the lifetime of the process. Retry for a few seconds, and let the
   launch notifications below have a go as well. */
static void IMAttemptInstall(NSInteger attemptsRemaining) {
    if (IMInstallHookIfNeeded()) return;

    if (attemptsRemaining <= 0) {
        IMSetHookStatus(IMHookStatusFailed);
        IMLog(@"Immortalizer couldn't attach on this version of iOS — the app won't be held in "
               "the foreground (silent audio keep-alive still applies)");
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IMAttemptInstall(attemptsRemaining - 1);
    });
}

static void setup(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        /* ORDER MATTERS: the first attach attempt has to run before the button
           is constructed. The button paints itself from the hook status the
           moment it exists, and Pending is a red state — so if the button were
           built first, every normal launch would flash red before settling on
           green. Doing the attempt here means the common case is already
           Installed by the time anything paints, and a Pending that survives
           to paint is a hook that genuinely hasn't attached. Don't move
           showButton above this call. */
        IMAttemptInstall(6);   /* ~3s of retries before we call it failed */

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            prefsChanged, CFSTR(kImmortalizerPrefsName), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        /* Second and third chances: whichever of these fires first, the
           runtime is definitely populated by then. Both are no-ops once the
           hook is in. */
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSOperationQueue *main = [NSOperationQueue mainQueue];

        [center addObserverForName:UIApplicationDidFinishLaunchingNotification
                            object:nil queue:main usingBlock:^(NSNotification *note) {
            IMInstallHookIfNeeded();
        }];

        /* Lifecycle reporting is intentionally independent of the private
           scene hook. If a future iOS prevents attachment, the log must still
           tell us whether the process actually entered the background and when
           it returned. These notifications describe the observed UIKit state;
           the hook's own log separately reports a background attempt that was
           intercepted before UIKit entered that state. */
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                            object:nil queue:main usingBlock:^(NSNotification *note) {
            BOOL wasAlreadyBackgrounded = atomic_exchange(&gObservedApplicationInBackground, true);
            if (!wasAlreadyBackgrounded) {
                IMLog(@"App entered the background");
            }

            if (ImmortalizerCachedEnabled() &&
                ImmortalizerHookStatus() == IMHookStatusInstalled) {
                IMLog(@"Foreground hold did not prevent this transition — silent audio keep-alive may still keep the process running");
                IMSetHookStatus(IMHookStatusSuspect);
            }
        }];

        [center addObserverForName:UIApplicationWillEnterForegroundNotification
                            object:nil queue:main usingBlock:^(NSNotification *note) {
            if (atomic_load(&gObservedApplicationInBackground)) {
                IMLog(@"App is returning to the foreground");
            }
        }];

        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil queue:main usingBlock:^(NSNotification *note) {
            BOOL wasBackgrounded = atomic_exchange(&gObservedApplicationInBackground, false);
            BOOL hookInstalled = IMInstallHookIfNeeded();

            if (wasBackgrounded) {
                IMLog(@"App is active in the foreground again");
            }

            if (hookInstalled && ImmortalizerHookStatus() == IMHookStatusSuspect) {
                IMLog(@"Foreground hook health restored");
                IMSetHookStatus(IMHookStatusInstalled);
            }
        }];

        [[FloatingButtonWindow sharedInstance] showButton];
    });
}

__attribute__((constructor)) static void initialize(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    atomic_store(&gVerboseLogging,   [defaults boolForKey:kImmortalizerVerboseDefaultsKey] ? true : false);
    atomic_store(&gInvokeCompletion, [defaults boolForKey:kImmortalizerCompletionDefaultsKey] ? true : false);

    atomic_store(&gImmortalized, ImmortalizerIsEnabled() ? true : false);
    setup();
}
