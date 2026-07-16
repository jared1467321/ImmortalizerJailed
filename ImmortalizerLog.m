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

#import "ImmortalizerLog.h"

NSString * const ImmortalizerLogDidUpdateNotification = @"ImmortalizerLogDidUpdateNotification";

static const NSUInteger kMaxEntries = 500;

@implementation ImmortalizerLogEntry
@end

@interface ImmortalizerLog ()
@property (nonatomic, strong) NSMutableArray<ImmortalizerLogEntry *> *store;
@end

@implementation ImmortalizerLog

+ (instancetype)shared {
    static ImmortalizerLog *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[ImmortalizerLog alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _store = [NSMutableArray array];
    }
    return self;
}

+ (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [[self shared] appendMessage:message];
}

- (void)appendMessage:(NSString *)message {
    NSLog(@"[ImmortalizerJailed] %@", message);

    ImmortalizerLogEntry *entry = [ImmortalizerLogEntry new];
    entry.date = [NSDate date];
    entry.message = message;

    @synchronized (self) {
        [self.store addObject:entry];
        if (self.store.count > kMaxEntries) {
            [self.store removeObjectsInRange:NSMakeRange(0, self.store.count - kMaxEntries)];
        }
    }
    [self postUpdate];
}

- (NSArray<ImmortalizerLogEntry *> *)entries {
    @synchronized (self) {
        return [self.store copy];
    }
}

- (NSString *)formattedLog {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss.SSS";
    });

    NSMutableString *out = [NSMutableString string];
    for (ImmortalizerLogEntry *entry in [self entries]) {
        [out appendFormat:@"%@  %@\n", [formatter stringFromDate:entry.date], entry.message];
    }
    return out;
}

- (void)clear {
    @synchronized (self) {
        [self.store removeAllObjects];
    }
    [self postUpdate];
}

- (void)postUpdate {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ImmortalizerLogDidUpdateNotification object:nil];
    });
}

@end


#pragma mark - Viewer

@interface ImmortalizerLogViewController ()
@property (nonatomic, strong) UITextView *textView;
@end

@implementation ImmortalizerLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];

    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    [self.view addSubview:bar];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"Immortalizer Log";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [bar addSubview:titleLabel];

    UIButton *closeButton = [self barButtonWithTitle:@"Close" action:@selector(closeTapped)];
    UIButton *clearButton = [self barButtonWithTitle:@"Clear" action:@selector(clearTapped)];
    UIButton *copyButton  = [self barButtonWithTitle:@"Copy"  action:@selector(copyTapped)];
    [bar addSubview:closeButton];
    [bar addSubview:clearButton];
    [bar addSubview:copyButton];

    _textView = [[UITextView alloc] init];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.editable = NO;
    _textView.backgroundColor = [UIColor clearColor];
    _textView.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    _textView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    _textView.alwaysBounceVertical = YES;
    [self.view addSubview:_textView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.heightAnchor constraintEqualToConstant:44],

        [titleLabel.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:16],
        [titleLabel.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],

        [closeButton.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-16],
        [closeButton.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],

        [clearButton.trailingAnchor constraintEqualToAnchor:closeButton.leadingAnchor constant:-16],
        [clearButton.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],

        [copyButton.trailingAnchor constraintEqualToAnchor:clearButton.leadingAnchor constant:-16],
        [copyButton.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],

        [_textView.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [_textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [_textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [_textView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refresh)
                                                 name:ImmortalizerLogDidUpdateNotification
                                               object:nil];
    [self refresh];
}

- (UIButton *)barButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)refresh {
    NSString *text = [[ImmortalizerLog shared] formattedLog];
    self.textView.text = text.length ? text : @"(no events yet)";
    if (text.length > 1) {
        [self.textView scrollRangeToVisible:NSMakeRange(text.length - 1, 1)];
    }
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onDismiss) self.onDismiss();
    }];
}

- (void)clearTapped {
    [[ImmortalizerLog shared] clear];
}

- (void)copyTapped {
    [UIPasteboard generalPasteboard].string = [[ImmortalizerLog shared] formattedLog];
}

@end
