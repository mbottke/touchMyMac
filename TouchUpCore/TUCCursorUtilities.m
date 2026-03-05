//
//  TUCCursorUtilities.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 11.02.23.
//

#import "TUCCursorUtilities.h"

@interface TUCCursorUtilities ()

@property NSInteger cursorClickCount;
@property NSDate *timeOfLastClick;
@property CGPoint locationOfLastClick;

@property BOOL isLeftMouseDown;

@property CGPoint momentumScrollVelocity;
@property CFTimeInterval momentumLastTickTime;
@property (strong) NSTimer *momentumScrollTimer;

@property CGPoint scrollVelocity;
@property CFTimeInterval scrollLastSampleTime;

@property BOOL isMagnifying;
@property CGFloat lastPinchDistance;

@end

@implementation TUCCursorUtilities

static const NSTimeInterval kMomentumTickInterval = 1.0 / 60.0;
static const CGFloat kMomentumVelocityStopThreshold = 5.0;     // px/s
static const CGFloat kMomentumStartThreshold = 120.0;          // px/s
static const CGFloat kMomentumDecelerationPerFrame = 0.95;     // 60Hz

+ (TUCCursorUtilities *)sharedInstance {
    static TUCCursorUtilities *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!sharedInstance) {
            sharedInstance = [[TUCCursorUtilities alloc] init];
            sharedInstance.isLeftMouseDown = NO;
            sharedInstance.cursorClickCount = 0;
            sharedInstance.timeOfLastClick = [NSDate dateWithTimeIntervalSince1970:0];
            sharedInstance.locationOfLastClick = CGPointZero;
            sharedInstance.scrollLastSampleTime = 0;
            sharedInstance.scrollVelocity = CGPointZero;
            sharedInstance.momentumScrollVelocity = CGPointZero;
            sharedInstance.momentumLastTickTime = 0;
        }
    });
    return sharedInstance;
}





- (CGPoint)currentCursorLocation {
    CGEventRef dummy = CGEventCreate(NULL);
    CGPoint location = CGEventGetLocation(dummy);
    CFRelease(dummy);
    return location;
}



- (void)moveCursorTo:(CGPoint)aLocation {
    [self cancelMomentumScroll];
    [self stopDraggingCursor];
    
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 0);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static inline CGFloat TUCLength(CGPoint v) {
    return (CGFloat)sqrt((double)(v.x * v.x + v.y * v.y));
}

static inline CGPoint TUCPointScale(CGPoint p, CGFloat s) {
    return CGPointMake(p.x * s, p.y * s);
}

static inline CGPoint TUCPointLerp(CGPoint a, CGPoint b, CGFloat t) {
    return CGPointMake(a.x + (b.x - a.x) * t,
                       a.y + (b.y - a.y) * t);
}

static inline CGFloat TUCClamp(CGFloat v, CGFloat minV, CGFloat maxV) {
    return v < minV ? minV : (v > maxV ? maxV : v);
}

static inline CFTimeInterval TUCNowSeconds(void) {
    return CACurrentMediaTime();
}

- (void)postScrollTranslation:(CGPoint)translation {
    CGEventRef event = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 2, translation.y, translation.x, 0);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}



- (void)bringWindowToFrontAt:(CGPoint)aLocation {
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventTimestamp time = CGEventGetTimestamp(event);
    CGEventSetTimestamp(event, time-1);
    
    CGEventPost(kCGHIDEventTap, event);
    CGEventSetType(event, kCGEventLeftMouseDragged);
    CGEventPost(kCGHIDEventTap, event);
    CGEventSetLocation(event, aLocation);
    CGEventSetType(event, kCGEventLeftMouseUp);
    CGEventPost(kCGHIDEventTap, event);
    
    CFRelease(event);
    //    self.isLeftMouseDown = YES;
}

/**
 integrated double click support: needs checks time between clicks and spatial distance
 */
- (void)performClickAt:(CGPoint)aLocation {
    [self updateCursorClickCountWithLocation:aLocation];
    
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
    CGEventPost(kCGHIDEventTap, event);
    CGEventSetType(event, kCGEventLeftMouseUp);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    
    self.timeOfLastClick = [NSDate date];
    self.locationOfLastClick = aLocation;
}


- (void)updateCursorClickCountWithLocation:(CGPoint)aLocation {
    ++self.cursorClickCount;
    
    NSTimeInterval durationSinceLastClick = [[NSDate date] timeIntervalSinceDate:self.timeOfLastClick];
    
    if (durationSinceLastClick > [NSEvent doubleClickInterval] || self.cursorClickCount == 4) {
        self.cursorClickCount = 1;
    }
    
    else if ((aLocation.x - self.locationOfLastClick.x) > self.doubleClickTolerance
             && (aLocation.y - self.locationOfLastClick.y) > self.doubleClickTolerance) {
        // touch is too far away
        self.cursorClickCount = 1;
    }
}


- (void)performSecondaryClickAt:(CGPoint)aLocation {
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventRightMouseDown, aLocation, kCGMouseButtonRight);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventPost(kCGHIDEventTap, event);
    CGEventSetType(event, kCGEventRightMouseUp);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}



- (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase  {
    if (phase == NSTouchPhaseEnded || phase == NSTouchPhaseCancelled) {
        [self stopDraggingCursor];
        return;
    }
    
    
    if (self.isLeftMouseDown) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDragged, aLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
    } else {
        [self moveCursorTo:aLocation];
        [self updateCursorClickCountWithLocation:aLocation];
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
        self.isLeftMouseDown = YES;
    }
}


- (void)stopDraggingCursor {
    if (self.isLeftMouseDown) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, [self currentCursorLocation], kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
        self.isLeftMouseDown = NO;
    }
}



- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase {
    [self stopDraggingCursor];

    CFTimeInterval now = TUCNowSeconds();

    if (phase == NSTouchPhaseBegan || self.scrollLastSampleTime == 0) {
        [self cancelMomentumScroll];
        self.scrollLastSampleTime = now;
        self.scrollVelocity = CGPointZero;
    }

    // Post the actual scroll event for this frame.
    [self postScrollTranslation:translation];

    if (phase == NSTouchPhaseMoved) {
        CFTimeInterval dt = now - self.scrollLastSampleTime;
        self.scrollLastSampleTime = now;
        if (dt > 0.0005) {
            dt = (CFTimeInterval)TUCClamp((CGFloat)dt, 0.0005f, 0.05f);
            CGPoint instVelocity = TUCPointScale(translation, (CGFloat)(1.0 / dt));
            // Low-pass filter to smooth noisy velocity estimates.
            self.scrollVelocity = TUCPointLerp(self.scrollVelocity, instVelocity, 0.25f);
        }
        return;
    }

    if (phase == NSTouchPhaseEnded || phase == NSTouchPhaseCancelled) {
        self.scrollLastSampleTime = 0;

        CGPoint v0 = self.scrollVelocity;
        self.scrollVelocity = CGPointZero;

        if (TUCLength(v0) < kMomentumStartThreshold) {
            [self cancelMomentumScroll];
            return;
        }

        // Start inertial scrolling from the last measured finger velocity.
        [self cancelMomentumScroll];
        self.momentumScrollVelocity = v0;
        self.momentumLastTickTime = now;

        self.momentumScrollTimer = [NSTimer timerWithTimeInterval:kMomentumTickInterval
                                                          target:self
                                                        selector:@selector(updateMomentumScroll)
                                                        userInfo:nil
                                                         repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.momentumScrollTimer forMode:NSRunLoopCommonModes];
        return;
    }
}



- (void)updateMomentumScroll {
    CFTimeInterval now = TUCNowSeconds();
    CFTimeInterval dt = now - self.momentumLastTickTime;
    self.momentumLastTickTime = now;
    if (dt <= 0) {
        return;
    }

    dt = (CFTimeInterval)TUCClamp((CGFloat)dt, 0.001f, 0.05f);

    CGPoint v = self.momentumScrollVelocity;
    if (fabs(v.x) < kMomentumVelocityStopThreshold && fabs(v.y) < kMomentumVelocityStopThreshold) {
        [self cancelMomentumScroll];
        return;
    }

    CGPoint translation = TUCPointScale(v, (CGFloat)dt);
    [self postScrollTranslation:translation];

    // Exponential decay tuned for ~60Hz.
    CGFloat frames = (CGFloat)(dt / kMomentumTickInterval);
    CGFloat decay = (CGFloat)pow(kMomentumDecelerationPerFrame, frames);
    self.momentumScrollVelocity = TUCPointScale(v, decay);
}



- (void)cancelMomentumScroll {
    if (self.momentumScrollTimer != nil) {
        [self.momentumScrollTimer invalidate];
        self.momentumScrollTimer = nil;
    }
    self.momentumScrollVelocity = CGPointZero;
    self.momentumLastTickTime = 0;
    self.scrollVelocity = CGPointZero;
    self.scrollLastSampleTime = 0;
}


- (void)magnify:(CGFloat)magnification phase:(NSTouchPhase)phase {
    [self stopDraggingCursor];
    
    if (phase == NSTouchPhaseMoved && magnification == 0) {
        // no reason to post that
        return;
    }
    
    // start with a valid mouse event, as it has a valid timestamp
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, [self currentCursorLocation], kCGMouseButtonLeft);
    
    CGEventSetType(event, 29); // type gesture
    CGEventSetFlags(event, 0);
    
    CGEventSetDoubleValueField(event, 113, magnification);
    CGEventSetDoubleValueField(event, 114, magnification);
    CGEventSetDoubleValueField(event, 116, magnification);
    CGEventSetDoubleValueField(event, 118, magnification);
    
    // magic
//    CGEventSetIntegerValueField(event, 55, 29); //if more touches on trackapd 30? about concurrent gestures???
    CGEventSetIntegerValueField(event, 50, 248);
    CGEventSetIntegerValueField(event, 101, 4);
    CGEventSetIntegerValueField(event, 110, 8);
    
    
    CGGesturePhase gesturePhase = kCGGesturePhaseEnded;
    if (phase == NSTouchPhaseBegan) {
        gesturePhase = kCGGesturePhaseBegan;
    } else if (phase == NSTouchPhaseMoved || phase == NSTouchPhaseStationary) {
        gesturePhase = kCGGesturePhaseChanged;
    }
    
    CGEventSetIntegerValueField(event, 132, phase);
    
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}


- (void)magnifyLocationA:(CGPoint)p1 locationB:(CGPoint)p2 relativeP1:(CGPoint)r1 relP2:(CGPoint)r2 {
    [self stopDraggingCursor];
    
    NSTouchPhase phase = NSTouchPhaseMoved;
    
    CGFloat dx = r1.x - r2.x;
    CGFloat dy = r1.y - r2.y;
    
    CGFloat distance = sqrt( pow(dx, 2) + pow(dy, 2) );
    CGFloat delta = distance - self.lastPinchDistance;
    
    self.lastPinchDistance = distance;
    
    if (!self.isMagnifying) {
        CGPoint middle = CGPointMake(0.5f * (p1.x + p2.x), 0.5f * (p1.y + p2.y));
        [self moveCursorTo:middle];
        phase = NSTouchPhaseBegan;
        delta = 0;
        self.isMagnifying = YES;
    }
    
    [self magnify:delta * 4 phase:phase];
}


- (void)stopMagnifying {
    if (self.isMagnifying) {
        self.isMagnifying = NO;
        [self magnify:0 phase:NSTouchPhaseEnded];
    }
}

@end
