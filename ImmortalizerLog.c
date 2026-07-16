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

/* Posted (on the main thread) whenever a new entry is added or the log is
   cleared, so an open viewer can refresh live. */
extern NSString * const ImmortalizerLogDidUpdateNotification;

@interface ImmortalizerLogEntry : NSObject
@property (nonatomic, strong) NSDate *date;
@property (nonatomic, copy) NSString *message;
@end

/* In-memory ring buffer of timestamped events. Also mirrors each entry to
   NSLog so it's visible in Console / idevicesyslog as before. Thread-safe. */
@interface ImmortalizerLog : NSObject
+ (instancetype)shared;
+ (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (NSArray<ImmortalizerLogEntry *> *)entries;   /* snapshot copy */
- (NSString *)formattedLog;                     /* full text, one line per entry */
- (void)clear;
@end

/* Drop-in replacement for the old NSLog-based IMLog: now feeds the viewer too. */
#define IMLog(fmt, ...) [ImmortalizerLog log:(fmt), ##__VA_ARGS__]

/* Full-screen, read-only log viewer. Present it over the floating window's
   root view controller. */
@interface ImmortalizerLogViewController : UIViewController
@property (nonatomic, copy) void (^onDismiss)(void);
@end
