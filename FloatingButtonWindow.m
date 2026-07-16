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

@interface FloatingButtonWindow ()
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UIView *handleView;
@property (nonatomic, assign) BOOL isImmortalized;
@property (nonatomic, assign) BOOL isDocked;
@property (nonatomic, assign) BOOL logVisible;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSTimer *dockTimer;
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
            IMLog(@"attached to foreground window scene");
            return;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            self.windowScene = (UIWindowScene *)scene;
            IMLog(@"attached to window scene (not yet foreground)");
            return;
        }
    }
}

- (void)sceneDidActivate:(NSNotification *)note {
    if (!self.windowScene && [note.object isKindOfClass:[UIWindowScene class]]) {
        self.windowScene = (UIWindowScene *)note.object;
        IMLog(@"scene activated, presenting button");
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
    IMLog(@"log viewer opened");
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
        IMLog(@"immortalize toggled %@", enabled ? @"ON" : @"OFF");
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
   The old approach re-created an AVAudioPlayer and re-activated the session
   every second via an NSTimer, purely to recover if another app's audio
   interrupted our silent playback. That's wasteful. Instead we build the
   player once and observe AVAudioSessionInterruptionNotification, resuming
   only when an interruption actually ends. Category stays MixWithOthers and we
   never deactivate the session, so we don't disturb apps that play real audio. */

- (void)startKeepAlive {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAudioInterruption:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:[AVAudioSession sharedInstance]];
    IMLog(@"keep-alive started");
    [self startPlayingSilentAudio];
}

- (void)stopKeepAlive {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVAudioSessionInterruptionNotification
                                                  object:[AVAudioSession sharedInstance]];
    [self stopPlayingSilentAudio];
    IMLog(@"keep-alive stopped");
}

- (void)handleAudioInterruption:(NSNotification *)note {
    NSInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        IMLog(@"audio interrupted (another app took the session)");
    } else if (type == AVAudioSessionInterruptionTypeEnded) {
        IMLog(@"audio interruption ended, resuming silent playback");
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        [self.audioPlayer play];
    }
}

- (void)startPlayingSilentAudio {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:nil];
    [session setActive:YES error:nil];

    if (!self.audioPlayer) {
        NSData *audioData = [[NSData alloc] initWithBase64EncodedString:kBase64Audio
                                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
        self.audioPlayer = [[AVAudioPlayer alloc] initWithData:audioData error:nil];
        self.audioPlayer.volume = 0.0;          /* no audible sound */
        self.audioPlayer.numberOfLoops = -1;    /* loop forever */
        [self.audioPlayer prepareToPlay];
        IMLog(@"silent audio player created");
    }

    if (!self.audioPlayer.isPlaying) {
        [self.audioPlayer play];
        IMLog(@"silent audio playing");
    }
}

- (void)stopPlayingSilentAudio {
    [self.audioPlayer stop];
}

@end
