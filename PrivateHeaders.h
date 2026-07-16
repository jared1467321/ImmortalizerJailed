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
#define kImmortalizerPrefsName   "com.sergy.immortalizerjailed.updateprefs"

static inline BOOL ImmortalizerIsEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kImmortalizedDefaultsKey];
}

static inline void ImmortalizerSetEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kImmortalizedDefaultsKey];
    notify_post(kImmortalizerPrefsName);
}
