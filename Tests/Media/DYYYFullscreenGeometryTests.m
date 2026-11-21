#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#import "DYYYFullscreenGeometry.h"

static int DYYYFullscreenGeometryCheck(BOOL passed, const char *name) {
    printf("%s fullscreen geometry: %s\n", passed ? "PASS" : "FAIL", name);
    return passed ? 0 : 1;
}

int DYYYRunFullscreenGeometryTests(void) {
    int failures = 0;
    CGRect viewport = CGRectMake(0.0, 0.0, 393.0, 852.0);
    CGRect nativeAtOrigin = CGRectMake(0.0, 0.0, 393.0, 852.0);
    CGRect nativeTransientLift = CGRectMake(0.0, -27.95, 393.0, 852.0);
    CGRect resultAtOrigin = [DYYYFullscreenGeometry stableFullscreenPlayerFrame:nativeAtOrigin
                                                               inSuperviewBounds:viewport];
    CGRect resultTransientLift = [DYYYFullscreenGeometry stableFullscreenPlayerFrame:nativeTransientLift
                                                                    inSuperviewBounds:viewport];
    failures += DYYYFullscreenGeometryCheck(CGRectEqualToRect(resultAtOrigin, viewport) &&
                                                CGRectEqualToRect(resultTransientLift, viewport),
                                            "横屏容器忽略 native y 抖动并稳定铺满 852pt 宿主");

    CGRect shiftedBounds = CGRectMake(0.0, 120.0, 393.0, 852.0);
    failures += DYYYFullscreenGeometryCheck(CGRectEqualToRect(
                                                [DYYYFullscreenGeometry stableFullscreenPlayerFrame:nativeTransientLift
                                                                                 inSuperviewBounds:shiftedBounds],
                                                shiftedBounds),
                                            "保留非零 bounds 原点，仍完整占满宿主");

    CGRect emptyBounds = CGRectZero;
    CGRect nullBounds = CGRectNull;
    failures += DYYYFullscreenGeometryCheck(CGRectEqualToRect(
                                                [DYYYFullscreenGeometry stableFullscreenPlayerFrame:nativeTransientLift
                                                                                 inSuperviewBounds:emptyBounds],
                                                nativeTransientLift) &&
                                                CGRectEqualToRect(
                                                [DYYYFullscreenGeometry stableFullscreenPlayerFrame:nativeTransientLift
                                                                                 inSuperviewBounds:nullBounds],
                                                nativeTransientLift),
                                            "宿主 bounds 无效时安全透传原生 frame");
    return failures;
}
