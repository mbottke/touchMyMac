//
//  TUCTouchInputManager.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import <AppKit/AppKit.h>
#import "TUCTouchInputManager-C.h"
#import "TUCTouchDelegate.h"
#import "TUCTouch.h"

NS_ASSUME_NONNULL_BEGIN



@interface TUCTouchInputManager : NSObject

@property (weak, nonatomic) id<TUCTouchDelegate> delegate;

@property (strong, atomic) NSMutableSet<TUCTouch *> *touchSet;

/**
 Allows to deactiate that the framework processes touches to post them as mouse events.
 The default value is YES.
 */
@property BOOL postMouseEvents;


/**
 The maximal distance in mm that two taps may be apart from each other to count as double click
 */
@property CGFloat doubleClickTolerance;

/**
 How long the user has to hold before a drag gesture turns into holdAndDrag.
 */
@property NSTimeInterval holdDuration;

/**
 If a touch is no longer reported by the screen, wait for this number of incoming reports bevore deleting it from the touch set.
 */
@property NSInteger errorResistance;


/**
 If a touchscreen sometimes sends invalid touch data at location (0,0), activate this option to ignore them
 */
@property BOOL ignoreOriginTouches;

/**
 Enables/disables inertial scrolling after a finger lifts.
 Default value is YES.
 */
@property BOOL scrollInertiaEnabled;

/**
 Controls how quickly inertial scrolling slows down per 60Hz frame.
 Default matches the built-in tuning (0.95).
 */
@property CGFloat scrollInertiaDecelerationPerFrame;

/**
 Multiplies the initial inertial velocity at liftoff (1.0 = unchanged).
 */
@property CGFloat scrollInertiaVelocityMultiplier;


- (void)start;

- (void)stop;



- (CGPoint)convertScreenPointRelativeToAbsolute:(CGPoint)relativePoint;


- (void)triggerSystemAccessibilityAccessAlert;

@end

NS_ASSUME_NONNULL_END
