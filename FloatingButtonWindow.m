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

@interface FloatingButtonWindow () <AVAudioPlayerDelegate>
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UIView *handleView;
@property (nonatomic, assign) BOOL isImmortalized;
@property (nonatomic, assign) BOOL isDocked;
@property (nonatomic, assign) BOOL logVisible;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSTimer *dockTimer;

/* Keep-alive health-check state (see the Keep-alive section below). */
@property (nonatomic, strong) NSTimer *keepAliveWatchdog;
@property (nonatomic, assign) BOOL keepAliveWanted;
@property (nonatomic, assign) NSInteger audioFailureStreak;
@property (nonatomic, strong) NSDate *nextAudioAttempt;
@end

static void vibrateDevice() {
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
        self.isImmortalized = ImmortalizerIsEnabled();

        /* If scenes aren't connected yet at load (cold launch), re-attach and
           show once a window scene activates. */
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sceneDidActivate:)
                                                     name:UISceneDidActivateNotification
                                                   object:nil];

        [self setupWindow];
        [self updateAndShowToast];
        [self setupButton];
        [self setupHandle];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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

/* Prefer a foreground-active window scene; fall back to any window scene. */
- (void)attachToActiveScene {
    if (self.windowScene) return;

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            self.windowScene = (UIWindowScene *)scene;
            IMLog(@"Button attached to the screen");
            return;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            self.windowScene = (UIWindowScene *)scene;
            IMLog(@"Button attached (waiting for the screen to become active)");
            return;
        }
    }
}

- (void)sceneDidActivate:(NSNotification *)note {
    if (!self.windowScene && [note.object isKindOfClass:[UIWindowScene class]]) {
        self.windowScene = (UIWindowScene *)note.object;
        IMLog(@"Screen active — showing the button");
    }
    if (self.windowScene && !self.hidden) {
        [self makeKeyAndVisible];
    }
}

- (void)setupButton {
    _floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _floatingButton.frame = CGRectMake(UIScreen.mainScreen.bounds.size.width - 50 - 30, 200, 50, 50);
    _floatingButton.backgroundColor = [UIColor colorWithRed:0.125 green:0.125 blue:0.125 alpha:1.0];
    [self updateButtonColor];
    _floatingButton.layer.cornerRadius = 25;
    _floatingButton.layer.masksToBounds = YES;

    UIImage *icon = [UIImage systemImageNamed:@"hourglass.tophalf.fill"];
    [_floatingButton setImage:icon forState:UIControlStateNormal];
    
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
    _handleView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 15, 50)];
    _handleView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.7];
    _handleView.layer.cornerRadius = 6;
    _handleView.layer.masksToBounds = YES;
    _handleView.alpha = 0;
    _handleView.hidden = YES;  

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake((_handleView.frame.size.width - 2)/2, 
                                                          (_handleView.frame.size.height - 30)/2, 
                                                          3, 30)];
    line.backgroundColor = [UIColor whiteColor];
    line.layer.cornerRadius = 1;
    line.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [_handleView addSubview:line];

    UIPanGestureRecognizer *handlePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleHandlePan:)];
    [_handleView addGestureRecognizer:handlePan];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(undockButton)];
    [_handleView addGestureRecognizer:tap];

    [self.rootViewController.view addSubview:_handleView];
}

- (void)makeKeyWindow {
    [super makeKeyWindow];
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication.windows.firstObject makeKeyWindow];
    });
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    [self resetDockTimer];
    
    CGPoint translation = [gesture translationInView:self];
    
    [UIView animateWithDuration:0.2 animations:^{
        gesture.view.center = CGPointMake(gesture.view.center.x + translation.x,
                                        gesture.view.center.y + translation.y);
        [gesture setTranslation:CGPointZero inView:self];
    }];
    
    if (gesture.state == UIGestureRecognizerStateEnded) {
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
        return;
    }
    
    CGPoint newCenter = CGPointMake(gesture.view.center.x + translation.x,
                                   gesture.view.center.y + translation.y);
    self.floatingButton.center = newCenter;
    [gesture setTranslation:CGPointZero inView:self];
    
    if (gesture.state == UIGestureRecognizerStateEnded) {
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

    center.x = MAX(minX, MIN(maxX, center.x));
    center.y = MAX(minY, MIN(maxY, center.y));
    return center;
}

- (void)snapButtonToNearestEdge:(UIButton *)button {
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
    newCenter.y = MAX(minY, MIN(maxY, newCenter.y));
    
    [UIView animateWithDuration:0.3 animations:^{
        button.center = newCenter;
    } completion:^(BOOL finished) {
        [self persistButtonCenter];
    }];
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

- (void)dockButton {
    if (self.isDocked) return;
    
    self.isDocked = YES;
    
    CGRect buttonFrame = self.floatingButton.frame;
    CGRect handleFrame = self.handleView.frame;
    
    BOOL isLeftEdge = self.floatingButton.center.x < self.bounds.size.width / 2;
    CGFloat handleX = isLeftEdge ? 0 : self.bounds.size.width - handleFrame.size.width;
    
    handleFrame.origin = CGPointMake(handleX, buttonFrame.origin.y + (buttonFrame.size.height - handleFrame.size.height)/2);
    self.handleView.frame = handleFrame;
    
    [UIView animateWithDuration:0.3 animations:^{
        self.floatingButton.alpha = 0;
        self.floatingButton.transform = CGAffineTransformMakeScale(0.5, 0.5);
    } completion:^(BOOL finished) {
        self.floatingButton.hidden = YES;
        self.handleView.hidden = NO;
        
        [UIView animateWithDuration:0.2 animations:^{
            self.handleView.alpha = 1;
        }];
    }];
}

- (void)undockButton {
    if (!self.isDocked) return;
    
    self.isDocked = NO;
    self.floatingButton.hidden = NO;
    
    BOOL isLeftEdge = self.handleView.frame.origin.x < self.bounds.size.width / 2;
    CGPoint buttonCenter = self.handleView.center;
    buttonCenter.x = isLeftEdge ? self.handleView.frame.size.width + self.floatingButton.frame.size.width/2 : 
                                 self.bounds.size.width - self.handleView.frame.size.width - self.floatingButton.frame.size.width/2;
    
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
        BOOL enabled = !self.isImmortalized;
        ImmortalizerSetEnabled(enabled);   /* writes defaults + posts the Darwin notify */
        self.isImmortalized = enabled;
        IMLog(@"Immortalizer turned %@", enabled ? @"ON" : @"OFF");
        [self updateButtonColor];
        [self updateAndShowToast];
    }];
}

- (void)updateAndShowToast {
    NSString *subtitle = @"";
    NSString *icon = @"";
    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];

    if (self.isImmortalized) {
        subtitle = @"Immortalized";
        icon = @"hourglass.bottomhalf.fill";
        [self startKeepAlive];
    } else {
        subtitle = @"At Rest";
        icon = @"arrow.uturn.left.circle.fill";
        [self stopKeepAlive];
    }

    CustomToastView *toastView = [[CustomToastView alloc] initWithTitle:appName subtitle:subtitle 
                                    icon:[UIImage systemImageNamed:icon] autoHide:3.0];

    [toastView presentToastInViewController:self.rootViewController];
}

- (void)updateButtonColor {
    if (self.isImmortalized) {
        self.floatingButton.tintColor = [UIColor systemBlueColor];
    } else {
        self.floatingButton.tintColor = [UIColor systemRedColor];
    }
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

   Category stays MixWithOthers and we never deactivate the session, so apps
   playing real audio are undisturbed. All keep-alive state is touched on the
   main thread; notification handlers hop there before doing anything. */

static const NSTimeInterval kKeepAliveWatchdogInterval = 2.0;
static const NSTimeInterval kKeepAliveMaxBackoff       = 30.0;

- (void)startKeepAlive {
    self.keepAliveWanted    = YES;
    self.audioFailureStreak = 0;
    self.nextAudioAttempt   = nil;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    AVAudioSession *session = [AVAudioSession sharedInstance];

    /* Idempotent: re-registering after a toggle-off/on shouldn't stack observers. */
    [center removeObserver:self name:AVAudioSessionInterruptionNotification object:session];
    [center removeObserver:self name:AVAudioSessionRouteChangeNotification   object:session];

    [center addObserver:self
               selector:@selector(handleAudioInterruption:)
                   name:AVAudioSessionInterruptionNotification
                 object:session];
    [center addObserver:self
               selector:@selector(handleRouteChange:)
                   name:AVAudioSessionRouteChangeNotification
                 object:session];

    IMLog(@"Started keeping the app awake");
    [self startKeepAliveWatchdog];
    [self evaluateKeepAlive];
}

- (void)stopKeepAlive {
    self.keepAliveWanted = NO;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [center removeObserver:self name:AVAudioSessionInterruptionNotification object:session];
    [center removeObserver:self name:AVAudioSessionRouteChangeNotification   object:session];

    [self stopKeepAliveWatchdog];
    [self stopPlayingSilentAudio];
    self.audioFailureStreak = 0;
    self.nextAudioAttempt   = nil;
    IMLog(@"Stopped keeping the app awake");
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

- (void)startPlayingSilentAudio {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;

    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:&error];
    if (!error) {
        [session setActive:YES error:&error];
    }

    if (!self.audioPlayer) {
        NSData *audioData = [[NSData alloc] initWithBase64EncodedString:kBase64Audio
                                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
        self.audioPlayer = [[AVAudioPlayer alloc] initWithData:audioData error:&error];
        self.audioPlayer.delegate     = self;
        self.audioPlayer.volume        = 0.0;   /* no audible sound */
        self.audioPlayer.numberOfLoops = -1;    /* loop forever     */
        [self.audioPlayer prepareToPlay];
    }

    BOOL playing = self.audioPlayer.isPlaying;
    if (!playing && !error) {
        playing = [self.audioPlayer play];
        if (!playing) {
            error = [NSError errorWithDomain:@"Immortalizer"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"AVAudioPlayer -play returned NO"}];
        }
    }

    if (playing && !error) {
        [self keepAliveDidSucceed];
    } else {
        [self keepAliveDidFailWithError:error];
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
