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

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>

/* --- Single source of truth for the immortalized flag ---------------------
   The state previously lived in three places (a static in main.m, a property
   on FloatingButtonWindow, and NSUserDefaults) kept in sync by hand. These
   helpers make NSUserDefaults the one authority and keep the Darwin-notify
   name in one spot so main.m and the window can't drift apart. */

#define kImmortalizedDefaultsKey @"immortalized"
#define kImmortalizerVerboseDefaultsKey @"immortalizerVerboseLogging"
#define kImmortalizerCompletionDefaultsKey @"immortalizerInvokeSuppressedCompletion"
#define kImmortalizerPrefsName   "com.sergy.immortalizerjailed.updateprefs"

/* The persisted value. Reads NSUserDefaults, so it's for setup paths — not for
   the scene-update hook, which runs often enough to want the cached read
   below. */
static inline BOOL ImmortalizerIsEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kImmortalizedDefaultsKey];
}

/* --- Cross-file state (defined in main.m) ---------------------------------

   These used to be a `static inline` setter plus a file-static BOOL in main.m,
   synchronised only by a Darwin notification. That round-trips through the
   system even though the writer and the reader are the same process, so there
   was a window where the toggle read ON while the hook still saw OFF. The
   setter now updates the cached flag directly and posts the notification only
   for anything outside this process. */

/* Cheap, thread-safe read of the live flag. This is what the hook uses. */
extern BOOL ImmortalizerCachedEnabled(void);

/* Writes NSUserDefaults, updates the cache synchronously, posts the notify. */
extern void ImmortalizerSetEnabled(BOOL enabled);

/* Verbose raw-diff logging. This was the `IM_LOG_RAW_DIFFS` compile-time
   define — the one diagnostic that tells you whether the settings-diff string
   matching still fits the current iOS. Being compile-time meant a full rebuild
   and re-inject to look at it, so it's a runtime toggle now, persisted in
   NSUserDefaults and switchable from the log viewer. */
extern BOOL ImmortalizerVerboseLogging(void);
extern void ImmortalizerSetVerboseLogging(BOOL enabled);

/* EXPERIMENT, default OFF. When we swallow a scene-settings update we also
   swallow the completion handler the system passed with it. Turning this on
   invokes that handler instead of dropping it. See the long note at the call
   site in main.m before enabling. */
extern BOOL ImmortalizerInvokeSuppressedCompletion(void);
extern void ImmortalizerSetInvokeSuppressedCompletion(BOOL enabled);

/* --- Hook health ----------------------------------------------------------
   The scene hook is the fragile half of this tweak: it matches on the string
   form of a private settings-diff description, so a future iOS can stop it
   working with no other symptom than the log going quiet. Tracking its state
   explicitly lets the button colour and the log viewer show it. */
typedef NS_ENUM(NSInteger, IMHookStatus) {
    IMHookStatusPending = 0,   /* still trying to attach                      */
    IMHookStatusInstalled,     /* attached, no evidence of trouble            */
    IMHookStatusFailed,        /* couldn't attach at all — audio only         */
    IMHookStatusSuspect,       /* attached, but the app backgrounded anyway   */
};

extern IMHookStatus ImmortalizerHookStatus(void);
extern NSString *ImmortalizerHookStatusDescription(void);

/* Posted on the main thread whenever the hook status, the on/off flag, or a
   debug toggle changes, so the button and the log viewer can refresh. */
extern NSString * const ImmortalizerStatusDidChangeNotification;
