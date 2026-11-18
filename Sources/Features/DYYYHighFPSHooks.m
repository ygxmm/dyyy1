#import "DYYYHighFPSHooks.h"
#import "DYYYConstants.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <math.h>

// One display link owns both the optional system rate request and the optional readout.
// Never modify the host's signed Info.plist or private refresh-rate globals.
@interface DYYYFrameMonitor : NSObject
@property(nonatomic, strong, nullable) CADisplayLink *link;
@property(nonatomic, copy, nullable) DYYYFPSReadout readout;
@property(nonatomic, assign) BOOL active;
@property(nonatomic, assign) NSInteger requestedRate;
@property(nonatomic, assign) CFTimeInterval sampleStart;
@property(nonatomic, assign) NSUInteger samples;
@property(nonatomic, assign) NSInteger displayedFPS;
- (void)dyyy_updateFramePolicy;
- (void)dyyy_resetFrameSample;
@end

@implementation DYYYFrameMonitor

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSOperationQueue *queue = NSOperationQueue.mainQueue;
    __weak DYYYFrameMonitor *weakSelf = self;
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:queue usingBlock:^(__unused NSNotification *note) {
        DYYYFrameMonitor *monitor = weakSelf;
        monitor.active = YES;
        [monitor dyyy_updateFramePolicy];
    }];
    [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:queue usingBlock:^(__unused NSNotification *note) {
        DYYYFrameMonitor *monitor = weakSelf;
        monitor.active = NO;
        [monitor dyyy_updateFramePolicy];
    }];
    [center addObserverForName:NSUserDefaultsDidChangeNotification object:NSUserDefaults.standardUserDefaults queue:nil usingBlock:^(__unused NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf dyyy_updateFramePolicy]; });
    }];
    for (NSNotificationName name in @[ NSProcessInfoThermalStateDidChangeNotification, NSProcessInfoPowerStateDidChangeNotification ]) {
        [center addObserverForName:name object:nil queue:queue usingBlock:^(__unused NSNotification *note) {
            [weakSelf dyyy_updateFramePolicy];
        }];
    }
    return self;
}

- (void)dyyy_resetFrameSample {
    self.sampleStart = 0;
    self.samples = 0;
    self.displayedFPS = -1;
    if (self.readout) self.readout(-1);
}

- (void)dyyy_updateFramePolicy {
    NSInteger request = 0;
    if (self.active && [NSUserDefaults.standardUserDefaults boolForKey:DYYY_ENABLE_HIGH_FPS_KEY]) {
        NSProcessInfo *info = NSProcessInfo.processInfo;
        NSInteger maxRate = UIScreen.mainScreen.maximumFramesPerSecond;
        if (!info.isLowPowerModeEnabled && info.thermalState < NSProcessInfoThermalStateFair && maxRate > 60) {
            request = maxRate;
        }
    }
    BOOL needsLink = self.active && (request > 0 || self.readout != nil);
    if (needsLink == (self.link != nil) && request == self.requestedRate) return;

    [self.link invalidate];
    self.link = nil;
    self.requestedRate = request;
    [self dyyy_resetFrameSample];
    if (!needsLink) return;

    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(dyyy_displayLinkTick:)];
    if (request > 0) {
        if (@available(iOS 15.0, *)) {
            link.preferredFrameRateRange = CAFrameRateRangeMake(60.0f, (float)request, (float)request);
        } else {
            link.preferredFramesPerSecond = request;
        }
    }
    // With the readout alone, leave both scheduling preferences at system defaults.
    self.link = link;
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)dyyy_displayLinkTick:(CADisplayLink *)link {
    if (!self.readout) return;
    CFTimeInterval timestamp = link.timestamp;
    if (self.sampleStart <= 0 || timestamp <= self.sampleStart) {
        self.sampleStart = timestamp;
        self.samples = 0;
        return;
    }
    self.samples++;
    CFTimeInterval elapsed = timestamp - self.sampleStart;
    if (elapsed < 0.6) return;
    NSInteger fps = (NSInteger)lround((double)self.samples / elapsed);
    self.sampleStart = timestamp;
    self.samples = 0;
    if (fps != self.displayedFPS) {
        self.displayedFPS = fps;
        self.readout(fps);
    }
}

@end

static DYYYFrameMonitor *DYYYSharedFrameMonitor(void) {
    static DYYYFrameMonitor *monitor;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ monitor = [DYYYFrameMonitor new]; });
    return monitor;
}

void DYYYStartHighFPSHooks(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [DYYYSharedFrameMonitor() dyyy_updateFramePolicy]; });
}

void DYYYSetFPSReadout(DYYYFPSReadout readout) {
    NSCAssert(NSThread.isMainThread, @"FPS readout is controlled from the main thread");
    DYYYFrameMonitor *monitor = DYYYSharedFrameMonitor();
    monitor.readout = readout;
    [monitor dyyy_resetFrameSample];
    [monitor dyyy_updateFramePolicy];
}
