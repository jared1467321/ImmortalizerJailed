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
#import "PrivateHeaders.h"
#import "FloatingButtonWindow.h"

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
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *verboseButton;
@property (nonatomic, strong) UIButton *completionButton;
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
    titleLabel.text = @"Immortalizer";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                forAxis:UILayoutConstraintAxisHorizontal];
    [bar addSubview:titleLabel];

    UIButton *closeButton = [self barButtonWithTitle:@"Close" action:@selector(closeTapped)];
    UIButton *clearButton = [self barButtonWithTitle:@"Clear" action:@selector(clearTapped)];
    UIButton *copyButton  = [self barButtonWithTitle:@"Copy"  action:@selector(copyTapped)];
    UIButton *stallButton = [self barButtonWithTitle:@"Stall" action:@selector(stallTapped)];
    [bar addSubview:closeButton];
    [bar addSubview:clearButton];
    [bar addSubview:copyButton];
    [bar addSubview:stallButton];

    /* --- Status strip ------------------------------------------------------
       Whether the foreground hook actually attached, plus the two runtime
       switches that used to be compile-time. The verbose one matters most: it
       is the diagnostic that shows the raw settings-diff text, which is how
       you tell whether the string matching still fits this version of iOS.
       Having to rebuild and re-inject to see it made it nearly useless. */
    UIView *statusBar = [[UIView alloc] init];
    statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    statusBar.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    [self.view addSubview:statusBar];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    _statusLabel.font = [UIFont systemFontOfSize:12];
    _statusLabel.adjustsFontSizeToFitWidth = YES;
    _statusLabel.minimumScaleFactor = 0.8;
    [statusBar addSubview:_statusLabel];

    _verboseButton    = [self stripButtonWithAction:@selector(verboseTapped)];
    _completionButton = [self stripButtonWithAction:@selector(completionTapped)];
    [statusBar addSubview:_verboseButton];
    [statusBar addSubview:_completionButton];

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
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:stallButton.leadingAnchor constant:-12],

        [closeButton.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-16],
        [closeButton.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],

        [clearButton.trailingAnchor constraintEqualToAnchor:closeButton.leadingAnchor constant:-16],
        [clearButton.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],

        [copyButton.trailingAnchor constraintEqualToAnchor:clearButton.leadingAnchor constant:-16],
        [copyButton.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],

        [stallButton.trailingAnchor constraintEqualToAnchor:copyButton.leadingAnchor constant:-16],
        [stallButton.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],

        [statusBar.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [statusBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [statusBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [statusBar.heightAnchor constraintEqualToConstant:32],

        [_statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_statusLabel.centerYAnchor constraintEqualToAnchor:statusBar.centerYAnchor],
        [_statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_completionButton.leadingAnchor constant:-12],

        [_verboseButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_verboseButton.centerYAnchor constraintEqualToAnchor:statusBar.centerYAnchor],

        [_completionButton.trailingAnchor constraintEqualToAnchor:_verboseButton.leadingAnchor constant:-14],
        [_completionButton.centerYAnchor constraintEqualToAnchor:statusBar.centerYAnchor],

        [_textView.topAnchor constraintEqualToAnchor:statusBar.bottomAnchor],
        [_textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [_textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [_textView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(refresh)
                   name:ImmortalizerLogDidUpdateNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(updateStatusStrip)
                   name:ImmortalizerStatusDidChangeNotification
                 object:nil];

    [self refresh];
    [self updateStatusStrip];
}

- (UIButton *)stripButtonWithAction:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.font = [UIFont systemFontOfSize:12];
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired
                                            forAxis:UILayoutConstraintAxisHorizontal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)updateStatusStrip {
    self.statusLabel.text = [NSString stringWithFormat:@"Immortalize: %@  ·  Hook: %@",
                             ImmortalizerCachedEnabled() ? @"on" : @"off",
                             ImmortalizerHookStatusDescription()];

    /* Same three-state signal the floating button gives: grey when the whole
       thing is off, green only when the hook is attached and holding, red for
       every other on-state — not attached, still attaching, or attached but
       not holding. */
    UIColor *statusColor;
    if (!ImmortalizerCachedEnabled()) {
        statusColor = [UIColor systemGrayColor];
    } else if (ImmortalizerHookStatus() == IMHookStatusInstalled) {
        statusColor = [UIColor systemGreenColor];
    } else {
        statusColor = [UIColor systemRedColor];
    }
    self.statusLabel.textColor = statusColor;

    BOOL verbose = ImmortalizerVerboseLogging();
    [self.verboseButton setTitle:verbose ? @"Verbose: on" : @"Verbose: off"
                        forState:UIControlStateNormal];
    [self.verboseButton setTitleColor:verbose ? [UIColor systemGreenColor] : [UIColor systemBlueColor]
                             forState:UIControlStateNormal];

    BOOL completion = ImmortalizerInvokeSuppressedCompletion();
    [self.completionButton setTitle:completion ? @"Completion: on" : @"Completion: off"
                           forState:UIControlStateNormal];
    [self.completionButton setTitleColor:completion ? [UIColor systemOrangeColor] : [UIColor systemBlueColor]
                                forState:UIControlStateNormal];
}

- (void)verboseTapped {
    ImmortalizerSetVerboseLogging(!ImmortalizerVerboseLogging());
    [self updateStatusStrip];
}

- (void)completionTapped {
    ImmortalizerSetInvokeSuppressedCompletion(!ImmortalizerInvokeSuppressedCompletion());
    [self updateStatusStrip];
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

/* Deliberately stall the keep-alive audio so the watchdog has to notice and
   recover it. The point is to exercise the recovery path on demand rather than
   waiting for iOS to produce an interruption it may never produce. */
- (void)stallTapped {
    [[FloatingButtonWindow sharedInstance] debugStallKeepAlive];
}

@end
