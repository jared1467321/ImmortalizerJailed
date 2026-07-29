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
#import "FloatingButtonWindow.h"
#import "ImmortalizerLog.h"

static NSString * const kButtonCenterKey = @"buttonCenter";

/* Resting opacity of the docked pill. Kept low so it reads as translucent,
   roughly matching AssistiveTouch's idle button. */
static const CGFloat kHandleRestingAlpha = 0.4;

@interface FloatingButtonWindow () <AVAudioPlayerDelegate>
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UIView *handleView;
@property (nonatomic, strong) UIView *handlePillView;
@property (nonatomic, assign) BOOL isImmortalized;
@property (nonatomic, assign) BOOL isDocked;
@property (nonatomic, assign) BOOL logVisible;
@property (nonatomic, assign) BOOL buttonWantedVisible;
@property (nonatomic, assign) CGSize lastLayoutSize;
@property (nonatomic, weak) UIWindow *previousKeyWindow;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSTimer *dockTimer;

/* Keep-alive health-check state (see the Keep-alive section below). */
@property (nonatomic, strong) NSTimer *keepAliveWatchdog;
@property (nonatomic, assign) BOOL keepAliveWanted;
@property (nonatomic, assign) NSInteger audioFailureStreak;
@property (nonatomic, strong) NSDate *nextAudioAttempt;

/* Snapshot of the host app's process-wide AVAudioSession configuration. */
@property (nonatomic, copy) NSString *previousAudioCategory;
@property (nonatomic, copy) NSString *previousAudioMode;
@property (nonatomic, assign) AVAudioSessionCategoryOptions previousAudioOptions;
@property (nonatomic, assign) BOOL previousAudioActiveKnown;
@property (nonatomic, assign) BOOL previousAudioActive;
@property (nonatomic, assign) BOOL audioSessionSnapshotTaken;
@property (nonatomic, assign) BOOL ownsAudioSessionConfiguration;
@property (nonatomic, copy) NSString *ownedAudioMode;
@property (nonatomic, assign) AVAudioSessionCategoryOptions ownedAudioOptions;
@end

/* --- The keep-alive audio --------------------------------------------------

   This used to be a 62,700-character base64 literal sitting in the header. Two
   problems with that. It lived in a header imported by two translation units,
   and a `static` at file scope means one copy per unit — about 125KB of
   duplicated string data in the dylib. And decoded, it wasn't silence: 47KB of
   8-bit 22.05kHz PCM, two seconds long, and roughly 45,600 of its 47,000
   sample bytes were non-zero. It was real audio, muted by `volume = 0.0`, so
   the only thing standing between the user and two seconds of sound was a
   single float.

   Generating the buffer instead costs a few lines, drops the blob from the
   binary, and makes the silence structural rather than a volume setting. One
   second of 16-bit mono at 8kHz, looped forever, is 16KB of zeroes built at
   first use. */
static NSData *IMSilentPCMData(void) {
    static NSData *silentData = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const uint32_t sampleRate    = 8000;
        const uint16_t channels      = 1;
        const uint16_t bitsPerSample = 16;
        const uint16_t blockAlign    = (uint16_t)(channels * (bitsPerSample / 8));
        const uint32_t dataBytes     = sampleRate * blockAlign;   /* one second */

        NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataBytes];

        /* WAV is little-endian, which is what we're already in. */
        void (^append32)(uint32_t) = ^(uint32_t value) { [wav appendBytes:&value length:4]; };
        void (^append16)(uint16_t) = ^(uint16_t value) { [wav appendBytes:&value length:2]; };

        [wav appendBytes:"RIFF" length:4];
        append32(36 + dataBytes);
        [wav appendBytes:"WAVE" length:4];

        [wav appendBytes:"fmt " length:4];
        append32(16);                                  /* PCM fmt chunk size    */
        append16(1);                                   /* format: PCM           */
        append16(channels);
        append32(sampleRate);
        append32(sampleRate * blockAlign);             /* byte rate             */
        append16(blockAlign);
        append16(bitsPerSample);

        [wav appendBytes:"data" length:4];
        append32(dataBytes);
        [wav increaseLengthBy:dataBytes];              /* zero-filled = silence */

        silentData = [wav copy];
    });
    return silentData;
}

/* AVAudioSession does not expose active state in its public API. Some iOS
   builds provide an -isActive accessor at runtime; use it only when present so
   we can restore deactivation accurately without depending on it. */
static BOOL IMGetAudioSessionActiveState(AVAudioSession *session, BOOL *active) {
    SEL selector = NSSelectorFromString(@"isActive");
    if (![session respondsToSelector:selector]) return NO;

    BOOL (*implementation)(id, SEL) =
        (BOOL (*)(id, SEL))[session methodForSelector:selector];
    if (!implementation) return NO;

    if (active) *active = implementation(session, selector);
    return YES;
}

static void vibrateDevice(void) {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    [feedback prepare];
    [feedback impactOccurred];
}

@implementation FloatingButtonWindow

+ (instancetype)sharedInstance {
    static FloatingButtonWindow *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[FloatingButtonWindow alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super initWithFrame:UIScreen.mainScreen.bounds];
    if (self) {
        self.isImmortalized = ImmortalizerCachedEnabled();
        self.lastLayoutSize = CGSizeZero;

        /* If scenes aren't connected yet at load (cold launch), re-attach and
           show once a window scene activates. */
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sceneDidActivate:)
                                                     name:UISceneDidActivateNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sceneDidDisconnect:)
                                                     name:UISceneDidDisconnectNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(immortalizerStatusChanged)
                                                     name:ImmortalizerStatusDidChangeNotification
                                                   object:nil];

        [self setupWindow];
        [self setupButton];
        [self setupHandle];

        /* Apply the persisted on/off state (keep-alive + button colour) but do
           NOT pop a toast on launch. */
        [self refreshImmortalizedState];

        /* Start in the docked (pill) state so launch skips the circle appearing
           and auto-docking. Tapping the pill expands it to the circle. */
        [self dockButtonImmediately];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.dockTimer invalidate];
    [self.keepAliveWatchdog invalidate];
}

- (void)setupWindow {
    [self attachToActiveScene];
    self.windowLevel = UIWindowLevelAlert + 1;
    self.userInteractionEnabled = YES;
    self.backgroundColor = [UIColor clearColor];
    self.rootViewController = [[UIViewController alloc] init];
    self.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.hidden = YES;
}

/* Prefer a foreground-active window scene, then an inactive one, then any
   connected scene. A UIWindow can only belong to one scene, so this singleton
   follows the active scene when multi-window apps move focus. */
- (UIWindowScene *)bestAvailableWindowScene {
    UIWindowScene *inactive = nil;
    UIWindowScene *fallback = nil;

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;

        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (!fallback) fallback = windowScene;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
        if (!inactive && scene.activationState == UISceneActivationStateForegroundInactive) {
            inactive = windowScene;
        }
    }
    return inactive ?: fallback;
}

- (BOOL)isSceneStillConnected:(UIWindowScene *)scene {
    return scene && [UIApplication.sharedApplication.connectedScenes containsObject:scene];
}

- (void)attachToScene:(UIWindowScene *)scene {
    if (!scene || self.windowScene == scene) return;

    BOOL wasVisible = !self.hidden;
    if (wasVisible) self.hidden = YES;
    self.windowScene = scene;
    self.frame = scene.coordinateSpace.bounds;
    self.lastLayoutSize = CGSizeZero;
    [self setNeedsLayout];
    [self layoutIfNeeded];
    if (wasVisible && self.buttonWantedVisible) self.hidden = NO;
    IMLog(@"Button attached to %@ screen", scene.activationState == UISceneActivationStateForegroundActive ? @"the active" : @"an available");
}

- (void)attachToActiveScene {
    UIWindowScene *current = self.windowScene;
    if ([self isSceneStillConnected:current] &&
        current.activationState == UISceneActivationStateForegroundActive) {
        return;
    }

    [self attachToScene:[self bestAvailableWindowScene]];
}

- (void)sceneDidActivate:(NSNotification *)note {
    if ([note.object isKindOfClass:[UIWindowScene class]]) {
        UIWindowScene *activated = (UIWindowScene *)note.object;
        if (self.windowScene != activated) {
            [self attachToScene:activated];
            IMLog(@"Screen active — showing the button");
        }
    }

    if (self.windowScene && self.buttonWantedVisible) {
        self.hidden = NO;
        [self makeKeyAndVisible];
    }
}

- (void)sceneDidDisconnect:(NSNotification *)note {
    if (note.object != self.windowScene) return;

    self.hidden = YES;
    self.windowScene = nil;
    [self attachToActiveScene];
    if (self.windowScene && self.buttonWantedVisible) {
        self.hidden = NO;
        [self makeKeyAndVisible];
    }
}

- (void)setupButton {
    _floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _floatingButton.frame = CGRectMake(self.bounds.size.width - 50 - 30, 200, 50, 50);
    _floatingButton.backgroundColor = [UIColor colorWithRed:0.125 green:0.125 blue:0.125 alpha:1.0];
    [self updateButtonColor];
    _floatingButton.layer.cornerRadius = 25;
    _floatingButton.layer.masksToBounds = YES;

    UIImage *icon = [UIImage systemImageNamed:@"hourglass.tophalf.fill"];
    [_floatingButton setImage:icon forState:UIControlStateNormal];
    _floatingButton.accessibilityLabel = @"Immortalizer";
    _floatingButton.accessibilityHint = @"Toggles foreground keep-alive. Long press to open diagnostics.";
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [_floatingButton addGestureRecognizer:pan];

    /* Long-press the button to open the event log. */
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.6;
    [_floatingButton addGestureRecognizer:longPress];
    
    [_floatingButton addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
    
    [self.rootViewController.view addSubview:_floatingButton];

    /* Restore last position if we have one; otherwise snap to the default edge. */
    NSString *savedCenter = [[NSUserDefaults standardUserDefaults] stringForKey:kButtonCenterKey];
    if (savedCenter) {
        _floatingButton.center = [self clampedCenter:CGPointFromString(savedCenter) forView:_floatingButton];
    } else {
        [self snapButtonToNearestEdge:_floatingButton];
    }
}

- (void)setupHandle {
    /* Keep the visible pill narrow, but give it a normal 44-point hit target. */
    _handleView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 50)];
    _handleView.backgroundColor = [UIColor clearColor];
    _handleView.alpha = 0;
    _handleView.hidden = YES;
    _handleView.isAccessibilityElement = YES;
    _handleView.accessibilityLabel = @"Immortalizer handle";
    _handleView.accessibilityHint = @"Double tap to expand the Immortalizer button.";
    _handleView.accessibilityTraits = UIAccessibilityTraitButton;

    _handlePillView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 15, 50)];
    _handlePillView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    _handlePillView.layer.cornerRadius = 6;
    _handlePillView.layer.masksToBounds = YES;
    _handlePillView.userInteractionEnabled = NO;
    [_handleView addSubview:_handlePillView];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake((_handlePillView.frame.size.width - 3)/2,
                                                          (_handlePillView.frame.size.height - 30)/2,
                                                          3, 30)];
    line.backgroundColor = [UIColor whiteColor];
    line.layer.cornerRadius = 1;
    line.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [_handlePillView addSubview:line];

    UIPanGestureRecognizer *handlePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleHandlePan:)];
    [_handleView addGestureRecognizer:handlePan];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(undockButton)];
    [_handleView addGestureRecognizer:tap];

    [self.rootViewController.view addSubview:_handleView];
}

- (UIWindow *)hostWindowToRestore {
    NSArray<UIWindow *> *windows = self.windowScene.windows;
    for (UIWindow *window in windows) {
        if (window != self && window.isKeyWindow) return window;
    }

    if (self.previousKeyWindow && self.previousKeyWindow.windowScene == self.windowScene &&
        !self.previousKeyWindow.hidden) {
        return self.previousKeyWindow;
    }

    for (UIWindow *window in windows) {
        if (window != self && !window.hidden && window.alpha > 0 && window.rootViewController &&
            window.windowLevel <= UIWindowLevelNormal) {
            return window;
        }
    }
    return nil;
}

- (void)makeKeyWindow {
    UIWindow *hostWindow = [self hostWindowToRestore];
    if (hostWindow) self.previousKeyWindow = hostWindow;

    [super makeKeyWindow];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = self.previousKeyWindow;
        if (window && window != self && window.windowScene == self.windowScene &&
            !window.hidden && window.alpha > 0) {
            [window makeKeyWindow];
        }
    });
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    [self resetDockTimer];
    
    CGPoint translation = [gesture translationInView:self];
    
    CGPoint proposed = CGPointMake(gesture.view.center.x + translation.x,
                                   gesture.view.center.y + translation.y);
    gesture.view.center = [self clampedCenter:proposed forView:gesture.view];
    [gesture setTranslation:CGPointZero inView:self];
    
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {
        [self snapButtonToNearestEdge:(UIButton *)gesture.view];
        [self startDockTimer];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        vibrateDevice();
        [self showLog];
    }
}

- (void)handleHandlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self undockButton];
        [gesture setTranslation:CGPointZero inView:self];
        return;
    }
    
    CGPoint newCenter = CGPointMake(self.floatingButton.center.x + translation.x,
                                    self.floatingButton.center.y + translation.y);
    self.floatingButton.center = [self clampedCenter:newCenter forView:self.floatingButton];
    [gesture setTranslation:CGPointZero inView:self];
    
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {
        [self snapButtonToNearestEdge:self.floatingButton];
        [self startDockTimer];
    }
}

/* Clamp a proposed center inside the safe area so the button can't hide behind
   the Dynamic Island / notch or the home indicator. */
- (CGPoint)clampedCenter:(CGPoint)center forView:(UIView *)view {
    UIEdgeInsets insets = self.safeAreaInsets;
    CGFloat halfW = view.bounds.size.width / 2.0;
    CGFloat halfH = view.bounds.size.height / 2.0;

    CGFloat minX = insets.left + halfW;
    CGFloat maxX = self.bounds.size.width - insets.right - halfW;
    CGFloat minY = insets.top + halfH;
    CGFloat maxY = self.bounds.size.height - insets.bottom - halfH;

    if (maxX < minX) center.x = CGRectGetMidX(self.bounds);
    else center.x = MAX(minX, MIN(maxX, center.x));

    if (maxY < minY) center.y = CGRectGetMidY(self.bounds);
    else center.y = MAX(minY, MIN(maxY, center.y));
    return center;
}

- (CGPoint)snappedCenterForButton:(UIButton *)button {
    UIEdgeInsets insets = self.safeAreaInsets;
    CGRect buttonFrame = button.frame;
    CGPoint newCenter = button.center;
    CGFloat screenWidth = self.bounds.size.width;
    CGFloat buttonWidth = buttonFrame.size.width;
    
    if (newCenter.x < screenWidth / 2) {
        newCenter.x = insets.left + buttonWidth / 2;
    } else {
        newCenter.x = screenWidth - insets.right - buttonWidth / 2;
    }
    
    CGFloat minY = insets.top + buttonFrame.size.height / 2;
    CGFloat maxY = self.bounds.size.height - insets.bottom - buttonFrame.size.height / 2;
    if (maxY < minY) newCenter.y = CGRectGetMidY(self.bounds);
    else newCenter.y = MAX(minY, MIN(maxY, newCenter.y));
    return newCenter;
}

- (void)placeButtonAtNearestEdge:(UIButton *)button animated:(BOOL)animated persist:(BOOL)persist {
    CGPoint newCenter = [self snappedCenterForButton:button];
    void (^changes)(void) = ^{ button.center = newCenter; };
    void (^completion)(BOOL) = ^(BOOL finished) {
        if (persist) [self persistButtonCenter];
    };

    if (animated) {
        [UIView animateWithDuration:0.3 animations:changes completion:completion];
    } else {
        changes();
        completion(YES);
    }
}

- (void)snapButtonToNearestEdge:(UIButton *)button {
    [self placeButtonAtNearestEdge:button animated:YES persist:YES];
}

- (void)persistButtonCenter {
    [[NSUserDefaults standardUserDefaults] setObject:NSStringFromCGPoint(self.floatingButton.center)
                                              forKey:kButtonCenterKey];
}

- (void)startDockTimer {
    [self.dockTimer invalidate];
    self.dockTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                    target:self
                                                  selector:@selector(dockButton)
                                                  userInfo:nil
                                                   repeats:NO];
}

- (void)resetDockTimer {
    if (self.isDocked) return;
    [self.dockTimer invalidate];
    [self startDockTimer];
}

/* Park the pill against whichever edge the button is nearest, vertically
   centred on the button. Shared by the animated dock and the launch-time
   immediate dock. */
- (void)layoutHandleAtButtonEdge {
    CGRect buttonFrame = self.floatingButton.frame;
    CGRect handleFrame = self.handleView.frame;

    BOOL isLeftEdge = self.floatingButton.center.x < self.bounds.size.width / 2;
    CGFloat handleX = isLeftEdge ? 0 : self.bounds.size.width - handleFrame.size.width;

    handleFrame.origin = CGPointMake(handleX, buttonFrame.origin.y + (buttonFrame.size.height - handleFrame.size.height)/2);
    self.handleView.frame = handleFrame;
    CGFloat pillX = isLeftEdge ? 0 : handleFrame.size.width - self.handlePillView.bounds.size.width;
    self.handlePillView.frame = CGRectMake(pillX, 0,
                                           self.handlePillView.bounds.size.width,
                                           handleFrame.size.height);
}

- (void)reconcileLayoutForCurrentGeometry {
    if (!self.floatingButton || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;

    self.floatingButton.center = [self clampedCenter:self.floatingButton.center
                                             forView:self.floatingButton];
    [self placeButtonAtNearestEdge:self.floatingButton animated:NO persist:YES];
    if (self.isDocked) [self layoutHandleAtButtonEdge];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!CGSizeEqualToSize(self.lastLayoutSize, self.bounds.size)) {
        self.lastLayoutSize = self.bounds.size;
        [self reconcileLayoutForCurrentGeometry];
    }
}

- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self reconcileLayoutForCurrentGeometry];
}

- (void)dockButton {
    if (self.isDocked) return;

    self.isDocked = YES;
    [self layoutHandleAtButtonEdge];

    [UIView animateWithDuration:0.3 animations:^{
        self.floatingButton.alpha = 0;
        self.floatingButton.transform = CGAffineTransformMakeScale(0.5, 0.5);
    } completion:^(BOOL finished) {
        self.floatingButton.hidden = YES;
        self.handleView.hidden = NO;

        [UIView animateWithDuration:0.2 animations:^{
            self.handleView.alpha = kHandleRestingAlpha;
        }];
    }];
}

/* Same end state as dockButton but with no animation and no toast — used on
   launch so the pill is simply already there. */
- (void)dockButtonImmediately {
    self.isDocked = YES;
    [self layoutHandleAtButtonEdge];

    self.floatingButton.alpha = 0;
    self.floatingButton.transform = CGAffineTransformMakeScale(0.5, 0.5);
    self.floatingButton.hidden = YES;

    self.handleView.hidden = NO;
    self.handleView.alpha = kHandleRestingAlpha;
}

- (void)undockButton {
    if (!self.isDocked) return;
    
    self.isDocked = NO;
    self.floatingButton.hidden = NO;
    
    BOOL isLeftEdge = self.handleView.frame.origin.x < self.bounds.size.width / 2;
    CGPoint buttonCenter = self.handleView.center;
    UIEdgeInsets insets = self.safeAreaInsets;
    CGFloat halfButton = self.floatingButton.bounds.size.width / 2.0;
    buttonCenter.x = isLeftEdge ? insets.left + halfButton
                                : self.bounds.size.width - insets.right - halfButton;
    buttonCenter = [self clampedCenter:buttonCenter forView:self.floatingButton];
    
    self.floatingButton.center = buttonCenter;
    
    [UIView animateWithDuration:0.3 animations:^{
        self.handleView.alpha = 0;
        self.floatingButton.alpha = 1;
        self.floatingButton.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        self.handleView.hidden = YES;
        [self startDockTimer];
    }];
}

- (void)showButton {
    self.buttonWantedVisible = YES;
    [self attachToActiveScene];
    self.hidden = NO;
    if (self.windowScene) {
        [self makeKeyAndVisible];
    }
    /* If there's no scene yet, sceneDidActivate: will present us once one appears. */
    if (!self.isDocked) {
        [self startDockTimer];
    }
}

- (void)hideButton {
    self.buttonWantedVisible = NO;
    self.hidden = YES;
    [self.dockTimer invalidate];
}

/* --- Log viewer ------------------------------------------------------------
   Long-pressing the button presents a full-screen, read-only log over our
   root view controller. While it's up, hitTest must pass touches through to
   the whole window (see below) so the viewer is interactive. */
- (void)showLog {
    if (self.logVisible) return;

    [self attachToActiveScene];
    self.hidden = NO;
    if (self.windowScene) {
        [self makeKeyAndVisible];
    }

    /* Undock so the button isn't left in a weird state behind the log. */
    if (self.isDocked) [self undockButton];
    [self.dockTimer invalidate];

    ImmortalizerLogViewController *logVC = [[ImmortalizerLogViewController alloc] init];
    logVC.modalPresentationStyle = UIModalPresentationFullScreen;

    __weak typeof(self) weakSelf = self;
    logVC.onDismiss = ^{
        weakSelf.logVisible = NO;
        if (!weakSelf.isDocked) [weakSelf startDockTimer];
    };

    self.logVisible = YES;
    IMLog(@"Opened the log");
    [self.rootViewController presentViewController:logVC animated:YES completion:nil];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    /* While the log is presented, let the whole window take touches so the
       viewer (buttons, scrolling) works. */
    if (self.logVisible) {
        return [super hitTest:point withEvent:event];
    }

    CGPoint buttonPoint = [self convertPoint:point toView:self.floatingButton];
    if (!self.floatingButton.hidden && [self.floatingButton pointInside:buttonPoint withEvent:event]) {
        return [super hitTest:point withEvent:event];
    }
    
    CGPoint handlePoint = [self convertPoint:point toView:self.handleView];
    if (!self.handleView.hidden && [self.handleView pointInside:handlePoint withEvent:event]) {
        return [super hitTest:point withEvent:event];
    }
    
    return nil;
}

- (void)buttonTapped {
    [UIView animateWithDuration:0.1 animations:^{
        self.floatingButton.transform = CGAffineTransformMakeScale(1.2, 1.2);
        vibrateDevice();
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.1 animations:^{
            self.floatingButton.transform = CGAffineTransformIdentity;
        }];
        BOOL enabled = !ImmortalizerCachedEnabled();
        ImmortalizerSetEnabled(enabled);   /* writes defaults + posts the Darwin notify */
        IMLog(@"Immortalizer turned %@", enabled ? @"ON" : @"OFF");
        [self synchronizeImmortalizedState];
        [self showStatusToast];
    }];
}

/* The atomic cache in main.m is authoritative. Status notifications also fire
   for hook-health and diagnostic-toggle changes, so only transition the audio
   keep-alive when the actual on/off value changed. */
- (void)synchronizeImmortalizedState {
    BOOL enabled = ImmortalizerCachedEnabled();
    if (self.isImmortalized != enabled) {
        self.isImmortalized = enabled;
        [self refreshImmortalizedState];
    } else {
        [self updateButtonColor];
    }
}

/* Reflect the current on/off state without showing a toast: drive keep-alive
   and the button colour. Safe to call on launch. */
- (void)refreshImmortalizedState {
    if (self.isImmortalized) {
        [self startKeepAlive];
    } else {
        [self stopKeepAlive];
    }
    [self updateButtonColor];
}

/* The transient status toast, shown only in response to an explicit toggle. */
- (void)showStatusToast {
    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    NSString *subtitle = self.isImmortalized ? @"Immortalized" : @"At Rest";
    NSString *icon     = self.isImmortalized ? @"hourglass.bottomhalf.fill"
                                             : @"arrow.uturn.left.circle.fill";

    CustomToastView *toastView = [[CustomToastView alloc] initWithTitle:appName subtitle:subtitle
                                    icon:[UIImage systemImageNamed:icon] autoHide:3.0];

    [toastView presentToastInViewController:self.rootViewController];
}

/* Grey is off — the toggle is off and nothing is being held. Green is working:
   toggle on and the foreground hook attached and holding. Red is the toggle
   being ON while the hook isn't holding, for any reason: never attached, still
   trying to attach, or it blocked a background attempt and the app went to the
   background anyway. Silent audio may still be running in the red case; the
   foreground hold specifically is not, and that's what the colour reports.

   Pending sits in the red group deliberately. It doesn't cause a red flash at
   launch, because `setup()` in main.m runs its first attach attempt before the
   button is ever constructed — see the note there. If Pending is still the
   status by the time anything paints, the hook genuinely hasn't attached yet,
   which is red. */
- (void)updateButtonColor {
    if (!self.isImmortalized) {
        self.floatingButton.tintColor = [UIColor systemGrayColor];
        return;
    }

    switch (ImmortalizerHookStatus()) {
        case IMHookStatusInstalled:
            self.floatingButton.tintColor = [UIColor systemGreenColor];
            break;
        case IMHookStatusPending:
        case IMHookStatusFailed:
        case IMHookStatusSuspect:
        default:
            self.floatingButton.tintColor = [UIColor systemRedColor];
            break;
    }
}

/* The hook status is decided over in main.m, on its own schedule — attach
   retries at launch, verification a second and a half after a block. */
- (void)immortalizerStatusChanged {
    [self synchronizeImmortalizedState];
}

/* --- Keep-alive ------------------------------------------------------------
   Silent looping audio holds the app in the foreground state while Immortalizer
   is on. The player alone can't be trusted to stay up: iOS stops it on an audio
   interruption (a call, an alarm, another app taking the session), stops it on a
   route change (headphones unplugged, Bluetooth dropped), and setActive: /
   -play can simply fail. If any of those happens and we don't react, the app
   quietly stops being immortalized — invisible until you notice it got
   suspended.

   An earlier pass here tried to be lean by dropping the recovery timer and only
   resuming when an interruption *ended*. That was the regression: the "ended"
   notification isn't guaranteed, route changes send no interruption at all, and
   a failed re-activation had nothing to retry it. So recovery is now a real
   health check, mirroring the Ksign fork:

     1. Event-driven — we observe interruption AND route-change notifications and
        re-evaluate the moment either fires. These also wake the app when it's
        backgrounded, which is exactly when we need to recover.
     2. Polled — a lightweight watchdog re-checks every couple of seconds that
        the player is actually playing and restarts it if not, no matter *why*
        it stopped (covers silent failures that send no notification).
     3. Backed-off — a failed (re)start doesn't hot-loop: retries space out
        1s, 2s, 4s ... capped at 30s, and reset the instant a start succeeds or
        an interruption ends.

   Category stays MixWithOthers while active. Before changing the process-wide
   session we snapshot the host app's category/mode/options; when Immortalizer
   turns off, we restore that snapshot only if the session still matches the
   configuration we installed. That ownership check prevents us from clobbering
   a newer recording, voice-chat, Bluetooth, or media configuration selected by
   the host app. All keep-alive state is touched on the main thread;
   notification handlers hop there before doing anything. */

static const NSTimeInterval kKeepAliveWatchdogInterval = 2.0;
static const NSTimeInterval kKeepAliveMaxBackoff       = 30.0;

- (void)startKeepAlive {
    if (self.keepAliveWanted) {
        [self evaluateKeepAlive];
        return;
    }

    self.keepAliveWanted    = YES;
    self.audioFailureStreak = 0;
    self.nextAudioAttempt   = nil;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    /* Idempotent: re-registering after a toggle-off/on shouldn't stack observers.

       Registered with `object:nil` rather than the session. Filtering on the
       session object assumes AVFoundation always posts these with the session
       as the notification's object — if it ever posts with nil, a filtered
       observer silently never fires and the recovery paths below are dead code
       you'd have no way to notice. The Ksign side has always used nil; matching
       it costs nothing and removes the assumption. */
    [center removeObserver:self name:AVAudioSessionInterruptionNotification object:nil];
    [center removeObserver:self name:AVAudioSessionRouteChangeNotification   object:nil];

    [center addObserver:self
               selector:@selector(handleAudioInterruption:)
                   name:AVAudioSessionInterruptionNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleRouteChange:)
                   name:AVAudioSessionRouteChangeNotification
                 object:nil];

    IMLog(@"Started keeping the app awake (other audio playing: %@)",
          [AVAudioSession sharedInstance].isOtherAudioPlaying ? @"yes" : @"no");
    [self startKeepAliveWatchdog];
    [self evaluateKeepAlive];
}

- (void)stopKeepAlive {
    if (!self.keepAliveWanted) return;

    self.keepAliveWanted = NO;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self name:AVAudioSessionInterruptionNotification object:nil];
    [center removeObserver:self name:AVAudioSessionRouteChangeNotification   object:nil];

    [self stopKeepAliveWatchdog];
    [self stopPlayingSilentAudio];
    [self restoreHostAudioSessionIfOwned];
    self.audioFailureStreak = 0;
    self.nextAudioAttempt   = nil;
    IMLog(@"Stopped keeping the app awake (other audio playing: %@)",
          [AVAudioSession sharedInstance].isOtherAudioPlaying ? @"yes" : @"no");
}

/* --- Stall test ------------------------------------------------------------

   Provoking a real interruption turned out to be hard: neither an incoming
   call nor a Voice Memos recording displaces a silent mixWithOthers stream, so
   the recovery code never ran and there was no way to tell whether it worked.

   This stops the player deliberately. Nothing else changes — no notification is
   faked, no state is reset — so the only thing that can bring it back is the
   watchdog noticing on its next tick and calling through `evaluateKeepAlive`
   into `startPlayingSilentAudio`, which is the identical path a real
   interruption recovery takes. Within about two seconds you should see the
   normal restart line. If you don't, the health check is broken, and no amount
   of phone calls would have told you that. */
- (void)debugStallKeepAlive {
    if (!self.keepAliveWanted) {
        IMLog(@"Stall test skipped — the keep-alive isn't running. Toggle Immortalizer on first.");
        return;
    }

    if (!self.audioPlayer.isPlaying) {
        IMLog(@"Stall test skipped — the player wasn't playing to begin with");
        return;
    }

    [self.audioPlayer stop];
    IMLog(@"Stall test: stopped the silent audio on purpose — the watchdog should bring it back within ~2s");
}

/* The health check. Cheap and safe to call from anywhere on the main thread — a
   timer tick, a notification, or the toggle. It only (re)starts when the player
   isn't already playing and we're outside any active backoff window. */
- (void)evaluateKeepAlive {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self evaluateKeepAlive]; });
        return;
    }
    if (!self.keepAliveWanted)      return;   /* immortalize is off */
    if (self.audioPlayer.isPlaying) return;   /* already healthy    */
    if (self.nextAudioAttempt && [self.nextAudioAttempt timeIntervalSinceNow] > 0) {
        return;                               /* backing off        */
    }
    [self startPlayingSilentAudio];
}

- (void)startKeepAliveWatchdog {
    if (self.keepAliveWatchdog) return;
    self.keepAliveWatchdog =
        [NSTimer scheduledTimerWithTimeInterval:kKeepAliveWatchdogInterval
                                         target:self
                                       selector:@selector(keepAliveWatchdogFired:)
                                       userInfo:nil
                                        repeats:YES];
    /* Common modes so it keeps firing during scroll/tracking too. */
    [[NSRunLoop mainRunLoop] addTimer:self.keepAliveWatchdog forMode:NSRunLoopCommonModes];
}

- (void)stopKeepAliveWatchdog {
    [self.keepAliveWatchdog invalidate];
    self.keepAliveWatchdog = nil;
}

- (void)keepAliveWatchdogFired:(NSTimer *)timer {
    [self evaluateKeepAlive];
}

- (void)handleAudioInterruption:(NSNotification *)note {
    NSInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (type == AVAudioSessionInterruptionTypeBegan) {
            /* iOS has already stopped our player; nothing to do until it ends. */
            IMLog(@"Another app interrupted the audio (call, alarm, etc.) — paused");
        } else {
            /* Interruption over — best moment to recover, so clear any backoff. */
            IMLog(@"Interruption ended — bringing the audio back");
            self.audioFailureStreak = 0;
            self.nextAudioAttempt   = nil;
            [self evaluateKeepAlive];
        }
    });
}

- (void)handleRouteChange:(NSNotification *)note {
    /* Headphone unplug, Bluetooth drop, etc. can stop playback with no
       interruption notification. Re-check regardless of the reason. */
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.keepAliveWanted && !self.audioPlayer.isPlaying) {
            IMLog(@"Audio route changed (headphones/Bluetooth) — bringing the audio back");
        }
        [self evaluateKeepAlive];
    });
}

- (void)captureHostAudioSessionIfNeeded:(AVAudioSession *)session {
    if (self.audioSessionSnapshotTaken) {
        /* If the host deliberately replaced our configuration and playback
           later needs rebuilding, preserve that newer host state as the new
           restoration target before we apply our category again. */
        if (!self.ownsAudioSessionConfiguration ||
            [self audioSessionStillMatchesOwnedConfiguration:session]) {
            return;
        }
        IMLog(@"Host app updated its audio session — preserving the newer configuration before restarting keep-alive");
    }

    self.previousAudioCategory = session.category;
    self.previousAudioMode = session.mode;
    self.previousAudioOptions = session.categoryOptions;
    self.previousAudioActiveKnown = IMGetAudioSessionActiveState(session, &_previousAudioActive);
    self.audioSessionSnapshotTaken = YES;
}

- (BOOL)audioSessionStillMatchesOwnedConfiguration:(AVAudioSession *)session {
    return self.ownsAudioSessionConfiguration &&
           [session.category isEqualToString:AVAudioSessionCategoryPlayback] &&
           [session.mode isEqualToString:self.ownedAudioMode ?: AVAudioSessionModeDefault] &&
           session.categoryOptions == self.ownedAudioOptions;
}

- (void)clearAudioSessionOwnership {
    self.previousAudioCategory = nil;
    self.previousAudioMode = nil;
    self.previousAudioOptions = 0;
    self.previousAudioActiveKnown = NO;
    self.previousAudioActive = NO;
    self.audioSessionSnapshotTaken = NO;
    self.ownsAudioSessionConfiguration = NO;
    self.ownedAudioMode = nil;
    self.ownedAudioOptions = 0;
}

- (void)restoreHostAudioSessionIfOwned {
    if (!self.audioSessionSnapshotTaken) return;

    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![self audioSessionStillMatchesOwnedConfiguration:session]) {
        if (self.ownsAudioSessionConfiguration) {
            IMLog(@"Host app changed the audio session while Immortalizer was running — leaving its newer configuration untouched");
        }
        [self clearAudioSessionOwnership];
        return;
    }

    NSError *restoreError = nil;
    NSString *category = self.previousAudioCategory ?: AVAudioSessionCategoryAmbient;
    NSString *mode = self.previousAudioMode ?: AVAudioSessionModeDefault;
    BOOL restored = [session setCategory:category
                                    mode:mode
                                 options:self.previousAudioOptions
                                   error:&restoreError];

    if (!restored) {
        IMLog(@"Couldn't restore the host app's audio session (%@)",
              restoreError.localizedDescription ?: @"unknown error");
        [self clearAudioSessionOwnership];
        return;
    }

    /* Only deactivate when we positively know the host session was inactive.
       When the runtime offers no active-state accessor, leaving the restored
       category active is safer than deactivating an app-owned session. */
    if (self.previousAudioActiveKnown && !self.previousAudioActive) {
        NSError *deactivationError = nil;
        if (![session setActive:NO
                    withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                          error:&deactivationError]) {
            IMLog(@"Restored the host audio category but couldn't deactivate the session (%@)",
                  deactivationError.localizedDescription ?: @"unknown error");
            [self clearAudioSessionOwnership];
            return;
        }
    }

    IMLog(@"Restored the host app's audio session");
    [self clearAudioSessionOwnership];
}

- (void)startPlayingSilentAudio {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [self captureHostAudioSessionIfNeeded:session];

    NSError *categoryError = nil;
    AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionMixWithOthers;
    BOOL categoryConfigured = [session setCategory:AVAudioSessionCategoryPlayback
                                               mode:AVAudioSessionModeDefault
                                            options:options
                                              error:&categoryError];
    if (!categoryConfigured) {
        [self keepAliveDidFailWithError:categoryError];
        return;
    }

    self.ownsAudioSessionConfiguration = YES;
    self.ownedAudioMode = AVAudioSessionModeDefault;
    self.ownedAudioOptions = options;

    NSError *activationError = nil;
    if (![session setActive:YES error:&activationError]) {
        [self keepAliveDidFailWithError:activationError];
        return;
    }

    if (!self.audioPlayer) {
        NSError *playerError = nil;
        self.audioPlayer = [[AVAudioPlayer alloc] initWithData:IMSilentPCMData() error:&playerError];
        if (!self.audioPlayer) {
            [self keepAliveDidFailWithError:playerError];
            return;
        }
        self.audioPlayer.delegate     = self;
        self.audioPlayer.volume        = 0.0;   /* no audible sound */
        self.audioPlayer.numberOfLoops = -1;    /* loop forever     */
        if (![self.audioPlayer prepareToPlay]) {
            NSError *prepareError = [NSError errorWithDomain:@"Immortalizer"
                                                        code:2
                                                    userInfo:@{NSLocalizedDescriptionKey: @"AVAudioPlayer -prepareToPlay returned NO"}];
            self.audioPlayer = nil;
            [self keepAliveDidFailWithError:prepareError];
            return;
        }
    }

    BOOL playing = self.audioPlayer.isPlaying;
    NSError *playError = nil;
    if (!playing) {
        playing = [self.audioPlayer play];
        if (!playing) {
            playError = [NSError errorWithDomain:@"Immortalizer"
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"AVAudioPlayer -play returned NO"}];
        }
    }

    if (playing) {
        [self keepAliveDidSucceed];
    } else {
        [self keepAliveDidFailWithError:playError];
    }
}

- (void)keepAliveDidSucceed {
    if (self.audioFailureStreak > 0) {
        IMLog(@"Audio recovered after %ld failed attempt(s) — app still awake", (long)self.audioFailureStreak);
    } else {
        IMLog(@"Silent audio is playing — app is being kept awake");
    }
    self.audioFailureStreak = 0;
    self.nextAudioAttempt   = nil;
}

- (void)keepAliveDidFailWithError:(NSError *)error {
    self.audioFailureStreak += 1;
    /* 1, 2, 4, 8, 16, 32 -> capped at 30s. Shift instead of pow(): no math.h. */
    NSInteger shift = MIN(self.audioFailureStreak - 1, (NSInteger)5);
    NSTimeInterval delay = MIN((NSTimeInterval)(1 << shift), kKeepAliveMaxBackoff);
    self.nextAudioAttempt = [NSDate dateWithTimeIntervalSinceNow:delay];

    /* Once per streak — a ten-minute call shouldn't spam a line every 2s. */
    if (self.audioFailureStreak == 1) {
        IMLog(@"Couldn't start the silent audio (%@) — will keep trying",
              error.localizedDescription ?: @"unknown error");
    }
    /* The watchdog picks it back up once the backoff window passes. */
}

- (void)stopPlayingSilentAudio {
    [self.audioPlayer stop];
}

#pragma mark - AVAudioPlayerDelegate

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    /* With numberOfLoops = -1 this shouldn't fire, but if it ever does the
       player has stopped — treat it like any other death and bring it back. */
    IMLog(@"Silent audio stopped unexpectedly — restarting");
    [self evaluateKeepAlive];
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    IMLog(@"Silent audio hit an error (%@) — rebuilding and restarting", error.localizedDescription);
    /* Drop the player so evaluate rebuilds it from scratch. */
    [self.audioPlayer stop];
    self.audioPlayer = nil;
    [self keepAliveDidFailWithError:error];
    [self evaluateKeepAlive];
}

@end
