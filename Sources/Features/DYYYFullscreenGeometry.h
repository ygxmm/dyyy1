#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/// 无 UIKit 状态的几何计算，可在宿主机直接验证。
@interface DYYYFullscreenGeometry : NSObject
+ (CGRect)translateRect:(CGRect)rect fromReference:(CGRect)previous toReference:(CGRect)current;
/// 全屏播放器占满稳定宿主 bounds，忽略播放器复用时的瞬态 frame 建议。
+ (CGRect)stableFullscreenPlayerFrame:(CGRect)proposed inSuperviewBounds:(CGRect)bounds;
+ (CGRect)aspectFit:(CGSize)media inRect:(CGRect)viewport;
+ (CGAffineTransform)aspectFitTransformForBounds:(CGRect)bounds contentRect:(CGRect)content center:(CGPoint)center inRect:(CGRect)viewport;
+ (CGRect)unoccludedViewport:(CGRect)viewport top:(CGFloat)top panel:(CGRect)panel gap:(CGFloat)gap;
@end
