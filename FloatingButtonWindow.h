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

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import "PrivateHeaders.h"
#import "CustomToastView.h"

@interface FloatingButtonWindow : UIWindow
+ (instancetype)sharedInstance;
- (void)showButton;
- (void)hideButton;

/* Debug: stop the keep-alive audio on purpose so the watchdog has to recover
   it. Driven from the log viewer — see the note at the implementation. */
- (void)debugStallKeepAlive;
@end
