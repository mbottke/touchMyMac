//
//  TUCCursorUtilities.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 11.02.23.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface TUCCursorUtilities : NSObject

+ (instancetype)sharedInstance;


@property CGFloat doubleClickTolerance;

/// Enables/disables inertial scrolling after a finger lifts.
@property (nonatomic) BOOL momentumScrollEnabled;

/// Controls how quickly inertial scrolling slows down per 60Hz frame.
/// Default matches the built-in tuning.
@property (nonatomic) CGFloat momentumDecelerationPerFrame;

/// Multiplies the initial inertial velocity at liftoff (1.0 = unchanged).
@property (nonatomic) CGFloat momentumVelocityMultiplier;

/// Minimum finger velocity (px/s) needed to start inertial scrolling on liftoff.
@property (nonatomic) CGFloat momentumStartThreshold;

/// Velocity (px/s) below which inertial scrolling stops.
@property (nonatomic) CGFloat momentumVelocityStopThreshold;

- (CGPoint)currentCursorLocation;

- (void)moveCursorTo:(CGPoint)aLocation;

#pragma mark Touch session cursor handling

/// When YES, the pointer is hidden for the duration of a touch interaction and
/// revealed again when the last finger lifts.
@property (nonatomic) BOOL hidesCursorDuringTouch;

/// When YES, the pointer is warped back to wherever it was before the touch began
/// once the last finger lifts. Note this restores the pointer only, not window focus:
/// focus follows the click and cannot be undone.
@property (nonatomic) BOOL restoresCursorAfterTouch;

/// The display the digitizer is bound to. The pointer is never restored onto it.
@property (nonatomic) CGDirectDisplayID touchDisplayID;

/// Called when the first finger of an interaction lands.
- (void)beginTouchSession;

/// Called when the last finger lifts.
- (void)endTouchSession;

- (void)performClickAt:(CGPoint)aLocation;

- (void)performSecondaryClickAt:(CGPoint)aLocation;

- (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase;
- (void)stopDraggingCursor;

- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase;

- (void)magnifyLocationA:(CGPoint)p1 locationB:(CGPoint)p2 relativeP1:(CGPoint)r1 relP2:(CGPoint)r2;
- (void)stopMagnifying;

- (void)beginHoldingShortcutSpec:(NSString *)shortcutSpec;
- (void)endHeldShortcut;
- (void)performShortcutChordSpec:(NSString *)shortcutSpec;
- (void)performShortcutSequenceSpec:(NSString *)shortcutSequenceSpec;
- (void)performMissionControl;


@end

NS_ASSUME_NONNULL_END
